# ovenette-print-bridge

Standalone Windows installer for Ovenette's local DYMO label print agent.

A customer downloads and runs `ovenette-printer-setup-latest.exe` (no
prerequisites -- Node.js and the service manager are bundled) to connect
their physical DYMO printer to Ovenette. It installs a small background
Windows service -- the **print agent** -- that listens on
`http://127.0.0.1:17631` for the one machine it's running on.

## Architecture

The printer is USB-corded to the same machine the admin uses when they
click "Print," not a remote one -- so there's no cloud relay here at
all:

1. Ovenette's server renders the label PDF (unchanged) and serves it to
   the admin's browser over an authenticated route, same as any other
   admin page.
2. The browser POSTs those PDF bytes directly to the local agent, at
   `http://127.0.0.1:<port>/print`.
3. The agent prints them immediately via `pdf-to-printer`. No queue, no
   polling, no cloud SDK, no stored credentials anywhere in this flow.

An earlier version of this repo used an Azure Storage Queue/Blob design
(see git history) built on the assumption that the printer might be on
a different machine than the browser -- it wasn't, so that whole design
was replaced with this simpler one.

### Access control

There's no good way to do a shared-secret API key check here (Ovenette
only ever stores a hash of a credential, never anything reversible it
could hand to the browser to attach to a localhost request). Instead,
like other local-agent tools solving the same problem (QZ Tray, Zebra
Browser Print), this relies on:

1. Binding to `127.0.0.1` only, never `0.0.0.0`.
2. A strict server-side check of the browser's `Origin` header on every
   `/print` request -- browsers set this themselves; page JS can't forge
   it.
3. Chrome's Private Network Access preflight
   (`Access-Control-Allow-Private-Network: true`), required on top of
   normal CORS for any public-origin page to reach `127.0.0.1` at all.

See `bridge/local-agent.js`'s own header comment for the full
reasoning, and a real, confirmed caveat: current Chrome also gates this
behind a **user-facing "Local Network Access" permission** (beyond just
the PNA header) -- the first real print attempt in a given browser may
show a one-time permission prompt near the address bar that has to be
approved.

## Repo layout

- `bridge/` -- `local-agent.js` and its dependencies (just `express`,
  `pdf-to-printer`, `dotenv` -- no cloud SDKs at all). Can be run
  directly (`npm install && node local-agent.js`, with a real `.env` --
  see `.env.example`) for local testing without building the installer.
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
1. Installs the agent's dependencies for real on Windows (`npm ci`).
2. Downloads the current Node.js LTS Windows runtime and stages it at
   `installer/node-runtime/node.exe`.
3. Installs Inno Setup and compiles the installer. Nothing secret is
   involved -- the only build-time value is the fixed local port
   (17631), which must match `local-agent.js`'s own default.
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
2. Shows a dropdown of this machine's actually-installed Windows
   printers (queried live via PowerShell's `Get-Printer`, never
   free-typed) -- pick the one labels should print to.
3. Writes a `.env` into the install directory (just the selected printer
   name and the port) and installs the agent as a Windows service
   (`OvenettePrintBridge`) via NSSM, set to auto-start, then starts it
   immediately.
4. Calls `GET http://127.0.0.1:17631/health` and shows a real
   success/failure message before finishing -- a genuine confirmation
   the service came up, not just hope.

Uninstalling stops and removes the service before deleting files.
