// On-site bridge: polls Ovenette's Azure Storage Queue for print jobs and
// sends the already-rendered label PDF to the physical DYMO printer
// connected to this machine. Ported and simplified from C-Flow's
// bridge-service (see ~/cflow/bridge-service/poll-and-print.js and
// printer-scheme.md in the ovenette repo for the full history) -- the
// multi-instance-per-machine complexity that codebase needed (several
// printers sharing one facility, each requiring its own env file/NSSM
// service) is deliberately dropped here: Ovenette is one printer per
// company, so this script only ever runs as a single instance.
//
// Two of C-Flow's fixes were hard-won from real production incidents
// there and are carried over unconditionally, not re-litigated:
//   - Plain dotenv.config() reading a .env from the process's own working
//     directory, no path argument. This is what makes NSSM's AppDirectory
//     setting work reliably -- a command-line arg or an
//     AppEnvironmentExtra-set env var both failed unpredictably under
//     NSSM/Local System's process context on C-Flow's real on-site
//     machines, even though both worked fine run manually.
//   - Real ISO-8601 timestamps on every log line, not just message order
//     -- without them, a delayed/failed print on C-Flow was once
//     impossible to diagnose after the fact.
//
// One real architectural difference from C-Flow: C-Flow's queue messages
// carry the full job payload (printerId, blob key, ...) directly. Ovenette's
// enqueuePrintJob (src/lib/queue.ts) only sends { printJobId } -- the
// bridge fetches everything else (blob path, owning printer) from the
// Ovenette API, authenticated with this printer's own API key. That API
// key also doesn't reveal this printer's id (needed to know which
// "print-jobs-<printerId>" queue to poll -- Ovenette uses the same
// one-queue-per-printer design C-Flow settled on after its shared-queue
// contention incident), so this script resolves its own printerId from
// the API key once at startup via GET /api/print-jobs/bridge/identify
// before it can even start polling.
const path = require("path");
require("dotenv").config();
const fs = require("fs");
const os = require("os");
const { QueueClient } = require("@azure/storage-queue");
const { ContainerClient } = require("@azure/storage-blob");
const { print } = require("pdf-to-printer");

// Scoped SAS URLs, NOT the account's full connection string -- this
// installer is a public download any customer can run, so each install
// only ever holds a credential limited to its own printer's queue
// (read + process, no add/update) and read-only access to the
// print-job-files container (see src/lib/azure-sas.ts in the main
// ovenette repo, which generates these). Verified directly, not just
// assumed: a real cross-queue/cross-container/write attempt with these
// credentials gets a real 403 from Azure.
const QUEUE_SAS_URL = requireEnv("QUEUE_SAS_URL");
const CONTAINER_SAS_URL = requireEnv("CONTAINER_SAS_URL");
const API_BASE_URL = requireEnv("OVENETTE_API_BASE_URL").replace(/\/+$/, "");
const PRINTER_API_KEY = requireEnv("PRINTER_API_KEY");
const PRINTER_NAME = requireEnv("PRINTER_NAME");
const POLL_INTERVAL_MS = Number(process.env.POLL_INTERVAL_MS || 5000);
// Generous relative to a single poll cycle's real work (one HTTP job-detail
// fetch, one blob download, one print spool) -- unlike C-Flow, this queue
// is never shared with another consumer, so there's no contention to tune
// around, just enough headroom that a slow cycle doesn't make Azure
// re-deliver the same message to this same (only) consumer mid-handling.
const VISIBILITY_TIMEOUT_SECONDS = 30;
const MAX_MESSAGES_PER_POLL = 10;

let LOG_PREFIX = "[bridge]";

function nowIso() {
  return new Date().toISOString();
}

function log(message) {
  console.log(`[${nowIso()}] ${LOG_PREFIX} ${message}`);
}

function logError(message, err) {
  if (err === undefined) {
    console.error(`[${nowIso()}] ${LOG_PREFIX} ${message}`);
  } else {
    console.error(`[${nowIso()}] ${LOG_PREFIX} ${message}`, err);
  }
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value || value.includes("changeme")) {
    console.error(
      `[${nowIso()}] FATAL: ${name} must be set to a real value in .env (see .env.example). Exiting.`,
    );
    process.exit(1);
  }
  return value;
}

async function apiRequest(method, urlPath) {
  const response = await fetch(`${API_BASE_URL}${urlPath}`, {
    method,
    headers: { Authorization: `Bearer ${PRINTER_API_KEY}` },
  });
  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new Error(`${method} ${urlPath} returned ${response.status}: ${body}`);
  }
  return response.json();
}

// Resolves this printer's own id (and confirms the API key is valid)
// before anything else can happen -- the queue name itself depends on
// it. Retries with backoff rather than crashing, the same shape as
// C-Flow's own "wait for the queue to become reachable" startup loop --
// this machine may come up before the network/DNS is fully ready after a
// reboot, and an unreachable API on first boot shouldn't require a
// manual service restart to recover from.
async function identify() {
  let attempt = 0;
  for (;;) {
    try {
      const data = await apiRequest("GET", "/api/print-jobs/bridge/identify");
      if (!data.printerId) {
        throw new Error("identify response missing printerId");
      }
      return data;
    } catch (err) {
      attempt += 1;
      const delayMs = Math.min(5000 * attempt, 60000);
      logError(`Could not identify this printer yet (attempt ${attempt}) -- retrying in ${delayMs}ms`, err);
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}

async function streamToBuffer(readable) {
  const chunks = [];
  for await (const chunk of readable) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }
  return Buffer.concat(chunks);
}

// Best-effort, never allowed to affect retry behavior -- called AFTER the
// physical print and the queue delete already succeeded, and never
// throws. A failed callback here (network blip) must not make this
// message look like a failed print and get retried, which would cause a
// real duplicate physical print.
async function markPrinted(printJobId) {
  try {
    await apiRequest("POST", `/api/print-jobs/${printJobId}/mark-printed`);
  } catch (err) {
    logError(
      `mark-printed callback for printJobId=${printJobId} failed -- the real print itself already succeeded, only this status report failed`,
      err,
    );
  }
}

function createClients() {
  // Both constructed directly from their SAS URL -- no shared-key
  // credential object, no account-level client. Each can only ever act
  // within the single queue/container its own SAS was signed for.
  const containerClient = new ContainerClient(CONTAINER_SAS_URL);
  const queueClient = new QueueClient(QUEUE_SAS_URL);
  return { containerClient, queueClient };
}

async function handleMessage(message, context) {
  const { containerClient, printerId } = context;

  let payload;
  try {
    payload = JSON.parse(Buffer.from(message.messageText, "base64").toString("utf-8"));
  } catch (err) {
    logError(`Message ${message.messageId} is not valid base64 JSON -- leaving it (dequeueCount=${message.dequeueCount})`, err);
    return;
  }

  const { printJobId } = payload;
  if (!printJobId) {
    logError(`Message ${message.messageId} has no printJobId -- leaving it (dequeueCount=${message.dequeueCount})`);
    return;
  }

  log(`Handling printJobId=${printJobId}`);
  let tempFilePath;
  try {
    const job = await apiRequest("GET", `/api/print-jobs/${printJobId}`);
    if (job.printerId !== printerId) {
      // Defense-in-depth only -- this printer's own queue should never
      // contain another printer's job. Left untouched (no delete) rather
      // than assuming that invariant always holds.
      logError(`printJobId=${printJobId} belongs to printerId=${job.printerId}, not this printer (${printerId}) -- leaving it`);
      return;
    }
    if (!job.blobPath) {
      throw new Error("job response missing blobPath");
    }

    const blobClient = containerClient.getBlockBlobClient(job.blobPath);
    const downloadResponse = await blobClient.download();
    const pdfBytes = await streamToBuffer(downloadResponse.readableStreamBody);

    tempFilePath = path.join(os.tmpdir(), `ovenette-label-${printJobId}.pdf`);
    fs.writeFileSync(tempFilePath, pdfBytes);

    // scale: "noscale" -- without it, the print driver may rescale this
    // precisely-sized label PDF (matching the real DYMO label stock
    // dimensions) to fit some default page format, defeating the whole
    // point of rendering at the correct physical size (same real
    // requirement C-Flow's bridge documented from pdf-to-printer's own
    // README).
    await print(tempFilePath, { printer: PRINTER_NAME, scale: "noscale" });
    log(`Printed printJobId=${printJobId} to "${PRINTER_NAME}"`);

    await context.queueClient.deleteMessage(message.messageId, message.popReceipt);
    await markPrinted(printJobId);
  } catch (err) {
    logError(`FAILED printJobId=${printJobId} (dequeueCount=${message.dequeueCount}) -- will retry automatically once visibility expires`, err);
  } finally {
    if (tempFilePath) {
      fs.unlink(tempFilePath, () => {});
    }
  }
}

async function pollOnce(context) {
  const response = await context.queueClient.receiveMessages({
    numberOfMessages: MAX_MESSAGES_PER_POLL,
    visibilityTimeout: VISIBILITY_TIMEOUT_SECONDS,
  });
  for (const message of response.receivedMessageItems) {
    await handleMessage(message, context);
  }
}

async function main() {
  log(`Starting -- printerName="${PRINTER_NAME}", apiBaseUrl="${API_BASE_URL}", pollIntervalMs=${POLL_INTERVAL_MS}`);

  const { printerId, printerName: resolvedName } = await identify();
  LOG_PREFIX = `[bridge:${resolvedName || PRINTER_NAME}]`;
  log(`Identified as printerId=${printerId}`);

  // Unlike the old connection-string version, this script can't create
  // its own queue -- the queue SAS is scoped to a specific, already-named
  // queue, not the account-level create permission. The Ovenette server
  // guarantees the queue exists before ever handing out a setup code
  // (see ensureQueueForPrinter, called from both createPrinter and
  // regeneratePrinterSetupCode), so there's nothing to create here.
  const { containerClient, queueClient } = createClients();
  const context = { containerClient, queueClient, printerId };

  log("Polling...");
  for (;;) {
    try {
      await pollOnce(context);
    } catch (err) {
      logError("Poll cycle failed (network/Azure issue?) -- will retry next cycle", err);
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }
}

// Logs clearly, then exits intentionally so NSSM's restart is a
// deliberate, visible log event, not a silent implicit crash (same
// defense-in-depth C-Flow's bridge added after a hard-to-diagnose
// production incident there).
main().catch((err) => {
  logError("FATAL -- main() crashed unexpectedly, exiting for NSSM to restart", err);
  process.exit(1);
});
