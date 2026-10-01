# ovenette-print-bridge

Standalone Windows installer for Ovenette's DYMO label print bridge service.

A customer downloads and runs `ovenette-printer-setup-latest.exe` (no
prerequisites -- Node.js and the service manager are bundled) to connect
their physical DYMO printer to Ovenette. It installs a background
Windows service that polls Ovenette's Azure Storage Queue for print
jobs and sends the rendered label PDF to the printer.

One printer per install -- no multi-instance configuration. Based on
(and a deliberate simplification of) C-Flow's bridge-service, which had
to support several printers per facility; Ovenette doesn't need that.

The compiled installer has nothing secret baked into it -- it's a single
public download, identical for every customer. Every real credential
(the printer's API key, and a pair of Azure SAS URLs scoped to only that
printer's own queue and read-only access to its label files -- never the
storage account's full connection string) is generated per-printer in
Ovenette's own admin UI and typed/pasted in by the wizard at install
time. See `bridge/poll-and-print.js`'s header comment and
`azure-sas.ts` in the main `ovenette` repo for why.

## Repo layout

- `bridge/` -- the Node.js script (`poll-and-print.js`) and its
  dependencies. Can be run directly (`npm install && node
  poll-and-print.js`, with a real `.env` -- see `.env.example`) for
  local testing without building the installer at all.
- `installer/` -- the Inno Setup project (`ovenette-print-bridge.iss`),
  vendored `nssm.exe` (see `installer/vendor/README.txt`), and
  `installer/node-runtime/` (gitignored -- staged by CI before
  compiling, see below).
- `.github/workflows/release.yml` -- builds and publishes the installer.

## Releasing

Push a version tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow (`windows-latest`) then:
1. Installs the bridge's dependencies for real on Windows (`npm ci`).
2. Downloads the current Node.js LTS Windows runtime and stages it at
   `installer/node-runtime/node.exe`.
3. Installs Inno Setup and compiles the installer (no secrets involved
   -- the only build-time value is the non-sensitive Ovenette API URL).
4. Publishes a GitHub Release for that tag with two identical assets:
   `ovenette-printer-setup-<version>.exe` and
   `ovenette-printer-setup-latest.exe`. The second, version-agnostic
   name is what Ovenette's admin UI links to
   (`/releases/latest/download/ovenette-printer-setup-latest.exe`), so
   that link never needs to change across releases. This only resolves
   publicly because the repo itself is public -- GitHub does not serve
   release assets from a private repo via a plain link.

You can also trigger the workflow manually (Actions tab ->
Release -> Run workflow) to test a build without cutting a real
release -- that path uploads the installer as a workflow artifact
instead of publishing a GitHub Release.

## What the installer does

1. Standard welcome / license / install-location screens.
2. Asks for a printer label (free text, for your own reference) and the
   printer's API key (from Ovenette's admin: Settings > Labels >
   Printers > Add Printer).
3. Asks for the printer's "setup code" -- a two-line block
   (`QUEUE_SAS_URL=...` / `CONTAINER_SAS_URL=...`) copied from the same
   place in the admin UI. Pasted as one block into a multi-line field;
   the installer's Pascal script does a plain-text line scan for those
   two prefixes (deliberately not JSON/base64 -- Inno Setup has no
   built-in parser for either, and this installer can't be locally
   compiled/tested outside CI, so simpler was safer).
4. Shows a dropdown of this machine's actually-installed Windows
   printers (queried live via PowerShell's `Get-Printer`, not
   free-typed) -- pick the one labels should print to.
5. Writes a `.env` into the install directory and installs the bridge
   as a Windows service (`OvenettePrintBridge`) via NSSM, set to
   auto-start, then starts it immediately.

Uninstalling stops and removes the service before deleting files.
