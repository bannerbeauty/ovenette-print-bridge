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
3. Installs Inno Setup and compiles the installer, substituting the real
   `AZURE_STORAGE_CONNECTION_STRING_BUILD` secret and the Ovenette API
   base URL in as build-time placeholders (never committed).
4. Publishes a GitHub Release for that tag with two identical assets:
   `ovenette-printer-setup-<version>.exe` and
   `ovenette-printer-setup-latest.exe`. The second, version-agnostic
   name is what Ovenette's admin UI links to
   (`/releases/latest/download/ovenette-printer-setup-latest.exe`), so
   that link never needs to change across releases.

You can also trigger the workflow manually (Actions tab ->
Release -> Run workflow) to test a build without cutting a real
release -- that path uploads the installer as a workflow artifact
instead of publishing a GitHub Release.

## What the installer does

1. Standard welcome / license / install-location screens.
2. Asks for a printer label (free text, for your own reference) and the
   printer's API key (from Ovenette's admin: Settings > Labels >
   Printers > Add Printer).
3. Shows a dropdown of this machine's actually-installed Windows
   printers (queried live via PowerShell's `Get-Printer`, not
   free-typed) -- pick the one labels should print to.
4. Writes a `.env` into the install directory and installs the bridge
   as a Windows service (`OvenettePrintBridge`) via NSSM, set to
   auto-start, then starts it immediately.

Uninstalling stops and removes the service before deleting files.

## Required secret

`AZURE_STORAGE_CONNECTION_STRING_BUILD` -- a GitHub Actions repository
secret, the same Azure Storage connection string the main Ovenette app
uses. Substituted into the installer at build time; never committed.
