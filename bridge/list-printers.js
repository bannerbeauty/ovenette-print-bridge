// Diagnostic -- confirms the DYMO printer is actually installed as a
// normal Windows-registered printer (the assumption the whole bridge
// depends on) and shows its exact name. The installer's wizard queries
// the same underlying printer list itself (via PowerShell, to populate
// its dropdown), so you shouldn't need to run this during normal setup
// -- it's here for troubleshooting after the fact.
//
// Usage: node list-printers.js
const { getPrinters } = require("pdf-to-printer");

getPrinters()
  .then((printers) => {
    console.log(`Found ${printers.length} installed Windows printer(s):\n`);
    for (const p of printers) {
      console.log(`  "${p.name}"${p.deviceId ? ` (deviceId: ${p.deviceId})` : ""}`);
    }
    if (printers.length === 0) {
      console.log("  (none) -- the DYMO printer needs to be installed via its own driver first.");
    }
  })
  .catch((err) => {
    console.error("Failed to list printers:", err);
    process.exit(1);
  });
