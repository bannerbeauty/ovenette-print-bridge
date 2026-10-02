// Local HTTP print agent -- runs on the SAME machine as the browser
// printing a label. Ovenette's server renders the label PDF (unchanged)
// and serves it to the admin's browser over an authenticated route; the
// browser then POSTs those bytes straight here, and this agent's only
// job is to send them to the physical printer via pdf-to-printer.
//
// This replaces an earlier Azure Storage Queue/Blob design (polling a
// cloud queue, downloading from Blob Storage, SAS-scoped credentials --
// see this repo's git history) that turned out to solve a problem that
// doesn't exist here: the printer is USB-corded to the same machine the
// admin is using when they click "Print," not a remote one. No queue,
// no polling, no Azure SDK, no credentials of any kind -- this process
// never talks to Ovenette's server at all.
//
// Access control is the one genuinely hard part of this design, so read
// this before changing anything here. There's no good way to do a
// shared-secret API key check: Ovenette's server only ever stores a
// HASH of a credential (correct, deliberate, same discipline as every
// session/magic-link token in that app), so it has nothing reversible
// to hand the browser to attach to a localhost request, and round-
// tripping a raw secret back through the server just to attach it
// client-side would mean storing it in reversible form somewhere --
// worse, not better. Instead, like QZ Tray, Zebra Browser Print, and
// other tools that solve exactly this problem, this relies on two
// things together:
//   1. Binding to 127.0.0.1 only, never 0.0.0.0 -- nothing outside this
//      machine can reach this server at all, at the network level.
//   2. A STRICT check of the browser's Origin request header on every
//      /print request (see checkOrigin below), rejecting anything that
//      doesn't exactly match Ovenette's real origin(s). This is not a
//      permissive CORS response header -- it actively validates the
//      incoming Origin and rejects before doing anything else. A
//      browser sets this header itself; page JS cannot forge it. That's
//      what stops an arbitrary malicious website -- loaded in the same
//      browser, on the same machine -- from silently triggering a
//      print even though this server has no per-request secret to
//      check.
// On top of that: a request from a public HTTPS origin to 127.0.0.1
// triggers Chrome's Private Network Access preflight, which must get an
// Access-Control-Allow-Private-Network: true response header on top of
// the normal CORS headers, or the browser silently blocks the real
// request. This has reportedly bitten every local-agent tool that's
// tried this pattern -- don't skip it, and verify it in a real browser,
// not just curl (curl doesn't enforce PNA at all, so it can't catch a
// missing header here).
require("dotenv").config();
const fs = require("fs");
const os = require("os");
const path = require("path");
const express = require("express");
const { print } = require("pdf-to-printer");

function nowIso() {
  return new Date().toISOString();
}

function log(message) {
  console.log(`[${nowIso()}] [print-agent] ${message}`);
}

function logError(message, err) {
  if (err === undefined) {
    console.error(`[${nowIso()}] [print-agent] ${message}`);
  } else {
    console.error(`[${nowIso()}] [print-agent] ${message}`, err);
  }
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value || value.includes("changeme")) {
    console.error(`[${nowIso()}] FATAL: ${name} must be set in .env. Exiting.`);
    process.exit(1);
  }
  return value;
}

const PRINTER_NAME = requireEnv("PRINTER_NAME");
// Fixed default, not meant to vary per install -- chosen to avoid
// common local dev server ports (3000, 5173, 8080, ...). Still read
// from .env (falling back to the default) rather than hardcoded,
// purely so a port conflict on one specific machine can be worked
// around by hand without a rebuild; the installer itself always writes
// this same default.
const PORT = Number(process.env.PORT || 17631);

// Hardcoded, NOT read from .env -- this is the entire access-control
// list for this server (see the module comment above), so it belongs
// in source, not a local config file an install could be edited to
// widen. http://localhost:3000 is for local development against this
// same bridge; it's harmless to ship in every build since it only ever
// matches a request that was already running on the same machine as
// this agent.
const ALLOWED_ORIGINS = new Set(["https://ovenettebakehouse.com", "http://localhost:3000"]);

const app = express();
app.disable("x-powered-by");
app.use(express.raw({ type: "application/pdf", limit: "10mb" }));

app.get("/health", (req, res) => {
  res.json({ status: "ok", printerName: PRINTER_NAME });
});

// The Private Network Access preflight for POST /print. Chrome sends
// this as a separate OPTIONS request before the real POST, specifically
// because the target (127.0.0.1) is a more-private address than the
// calling page's own origin; it must see
// Access-Control-Allow-Private-Network: true here or it blocks the
// following POST without ever sending it (silently, in the "look at
// the Network tab" sense -- no error surfaces to page JS beyond a
// generic failed fetch).
app.options("/print", (req, res) => {
  const origin = req.headers.origin;
  if (!origin || !ALLOWED_ORIGINS.has(origin)) {
    res.status(403).end();
    return;
  }
  res.setHeader("Access-Control-Allow-Origin", origin);
  res.setHeader("Vary", "Origin");
  res.setHeader("Access-Control-Allow-Methods", "POST");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  res.setHeader("Access-Control-Allow-Private-Network", "true");
  res.status(204).end();
});

app.post("/print", async (req, res) => {
  const origin = req.headers.origin;
  if (!origin || !ALLOWED_ORIGINS.has(origin)) {
    logError(`Rejected /print request with Origin="${origin}"`);
    res.status(403).json({ error: "Origin not allowed" });
    return;
  }
  res.setHeader("Access-Control-Allow-Origin", origin);
  res.setHeader("Vary", "Origin");

  const pdfBytes = req.body;
  if (!Buffer.isBuffer(pdfBytes) || pdfBytes.length === 0) {
    res.status(400).json({
      error: "Expected raw PDF bytes in the request body (Content-Type: application/pdf).",
    });
    return;
  }

  const tempFilePath = path.join(os.tmpdir(), `ovenette-print-${Date.now()}.pdf`);
  try {
    fs.writeFileSync(tempFilePath, pdfBytes);
    // scale: "noscale" -- without it, the print driver may rescale this
    // precisely-sized label PDF (matching the real DYMO label stock
    // dimensions) to fit some default page format, defeating the whole
    // point of rendering at the correct physical size (pdf-to-printer's
    // own README documents this).
    await print(tempFilePath, { printer: PRINTER_NAME, scale: "noscale" });
    log(`Printed ${pdfBytes.length} bytes to "${PRINTER_NAME}"`);
    res.json({ printed: true });
  } catch (err) {
    logError("Print failed", err);
    res.status(500).json({ error: err instanceof Error ? err.message : "Print failed." });
  } finally {
    fs.unlink(tempFilePath, () => {});
  }
});

// Bound explicitly to 127.0.0.1 -- never 0.0.0.0 -- see the module
// comment above for why this (together with the Origin check) is the
// whole access-control model.
app.listen(PORT, "127.0.0.1", () => {
  log(`Print agent listening on http://127.0.0.1:${PORT} (printer: "${PRINTER_NAME}")`);
});
