; Ovenette Print Bridge -- Inno Setup installer.
;
; Builds a self-contained Windows installer: no prerequisites, the
; customer just downloads and runs this .exe. Bundles a portable Node.js
; runtime and the already-`npm install`ed local print agent (see
; ../bridge/), plus NSSM (vendored at ../installer/vendor/nssm.exe) to
; install it as a background Windows service.
;
; Nothing secret is baked in here or collected by the wizard -- this
; installer is a single public download every customer uses, identical
; for all of them. The agent never talks to Ovenette's server at all
; (see local-agent.js's own header comment for the full architecture);
; all this installer needs to know is which Windows printer to use and
; which local port to listen on, both written to a local .env file.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0-dev"
#endif
; Must match local-agent.js's own PORT default exactly -- see that
; file's comment for why 17631.
#ifndef MyAgentPort
  #define MyAgentPort "17631"
#endif

#define MyAppName "Ovenette Print Agent"
#define MyServiceName "OvenettePrintBridge"

[Setup]
AppId={{B6E2B6C9-6C9E-4C0C-9B8E-3F6B0F0C6A9D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=Ovenette Bake House
DefaultDirName={autopf}\OvenettePrintBridge
DefaultGroupName=Ovenette Print Bridge
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE.txt
OutputDir=Output
OutputBaseFilename=ovenette-printer-setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
WizardStyle=modern
; This is a background-service installer with no user-facing app to
; launch afterward, so the usual "Launch program" finish-page checkbox
; doesn't apply -- the [Run]/[UninstallRun] sections below handle the
; service lifecycle instead, and CurPageChanged's health check (below)
; reports success/failure on the finished page itself.
DisableWelcomePage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; The agent script + its already-installed node_modules (installed by
; the release workflow on a Windows runner before compiling, so native/
; platform-specific bits -- pdf-to-printer bundles a Windows SumatraPDF
; binary -- are correct for this target). .env is deliberately excluded:
; it's written fresh by this installer for each customer, never copied
; from a build-time file.
Source: "..\bridge\*"; DestDir: "{app}\bridge"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: ".env,.env.example,.env.smoketest,*.log"
; Portable Node.js runtime, downloaded by the release workflow and
; staged into installer\node-runtime\ before compiling (see
; .github/workflows/release.yml) -- placed directly alongside
; local-agent.js so the NSSM service's Application path and AppDirectory
; can both point at the same {app}\bridge folder.
Source: "node-runtime\node.exe"; DestDir: "{app}\bridge"; Flags: ignoreversion
; NSSM itself, vendored directly in this repo (small, free,
; redistributable -- see vendor\README.txt).
Source: "vendor\nssm.exe"; DestDir: "{app}\tools"; Flags: ignoreversion

[Code]
var
  PrinterSelectPage: TWizardPage;
  PrinterCombo: TNewComboBox;
  PrintersDetected: Boolean;
  HealthCheckDone: Boolean;
  // Captured explicitly in NextButtonClick, at the moment the user
  // confirms the printer-select page -- see that procedure's own
  // comment for why this isn't just read from PrinterCombo.Text later.
  SelectedPrinterName: String;
  EnvWriteFailed: Boolean;

const
  NoPrintersFoundLabel = '(No printers found -- install your DYMO driver first)';

procedure InitializeWizard;
begin
  PrinterSelectPage := CreateCustomPage(wpSelectDir,
    'Select Printer',
    'Choose the Windows printer this agent should send labels to');

  PrinterCombo := TNewComboBox.Create(PrinterSelectPage);
  PrinterCombo.Parent := PrinterSelectPage.Surface;
  PrinterCombo.Left := 0;
  PrinterCombo.Top := ScaleY(8);
  PrinterCombo.Width := PrinterSelectPage.SurfaceWidth;
  PrinterCombo.Style := csDropDownList;

  PrintersDetected := False;
  HealthCheckDone := False;
  SelectedPrinterName := '';
  EnvWriteFailed := False;
end;

// Queries this machine's actually-installed Windows printers live, via
// PowerShell's Get-Printer -- deliberately NOT free-typed by the user,
// so the exact string written into .env as PRINTER_NAME always matches
// a real printer (pdf-to-printer sends print jobs by this exact name).
procedure DetectPrinters;
var
  ResultCode: Integer;
  TempFile: String;
  Lines: TStringList;
  i: Integer;
  Name: String;
begin
  PrinterCombo.Items.Clear;
  PrinterCombo.Items.Add('Detecting printers...');
  PrinterCombo.ItemIndex := 0;

  TempFile := ExpandConstant('{tmp}\ovenette-printers.txt');
  if FileExists(TempFile) then
    DeleteFile(TempFile);

  Exec(ExpandConstant('{cmd}'),
    '/C powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Printer | Select-Object -ExpandProperty Name" > "' + TempFile + '" 2>&1',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  PrinterCombo.Items.Clear;

  if FileExists(TempFile) then
  begin
    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(TempFile);
      for i := 0 to Lines.Count - 1 do
      begin
        Name := Trim(Lines[i]);
        if Name <> '' then
          PrinterCombo.Items.Add(Name);
      end;
    finally
      Lines.Free;
    end;
    DeleteFile(TempFile);
  end;

  if PrinterCombo.Items.Count = 0 then
  begin
    PrinterCombo.Items.Add(NoPrintersFoundLabel);
    PrintersDetected := False;
  end
  else
    PrintersDetected := True;

  PrinterCombo.ItemIndex := 0;
end;

// Calls GET /health on the just-started agent and reports success or
// failure right on the finished page -- a real, immediate confirmation
// the service actually came up, rather than hoping. Runs from
// CurPageChanged(wpFinished), since by the time Inno Setup shows that
// page, the [Run] section's nssm commands (install/configure/start)
// have already executed -- CurStepChanged(ssPostInstall) fires too
// early for this, before the service exists to check.
procedure RunHealthCheck;
var
  ResultCode: Integer;
  TempFile: String;
  Lines: TStringList;
  StatusText: String;
begin
  TempFile := ExpandConstant('{tmp}\ovenette-health.txt');
  if FileExists(TempFile) then
    DeleteFile(TempFile);

  Exec(ExpandConstant('{cmd}'),
    '/C powershell -NoProfile -Command "try { (Invoke-WebRequest -Uri ''http://127.0.0.1:{#MyAgentPort}/health'' -UseBasicParsing -TimeoutSec 5).StatusCode } catch { ''FAILED'' }" > "' + TempFile + '" 2>&1',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

  StatusText := '';
  if FileExists(TempFile) then
  begin
    Lines := TStringList.Create;
    try
      Lines.LoadFromFile(TempFile);
      if Lines.Count > 0 then
        StatusText := Trim(Lines[0]);
    finally
      Lines.Free;
    end;
    DeleteFile(TempFile);
  end;

  if StatusText = '200' then
    MsgBox('The Ovenette Print Agent started successfully and is responding on port {#MyAgentPort}.', mbInformation, MB_OK)
  else
    MsgBox('The print agent may not have started correctly (health check result: ' + StatusText + '). Check the log at ' + ExpandConstant('{app}') + '\bridge\log.txt, or try restarting the "' + '{#MyServiceName}' + '" service from Windows Services.', mbError, MB_OK);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = PrinterSelectPage.ID) and (PrinterCombo.Items.Count = 0) then
    DetectPrinters;

  if (CurPageID = wpFinished) and not HealthCheckDone then
  begin
    HealthCheckDone := True;
    // Skip the redundant generic health-check failure if we already
    // showed a specific diagnostic for the same root cause in
    // CurStepChanged.
    if not EnvWriteFailed then
      RunHealthCheck;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  if CurPageID = PrinterSelectPage.ID then
  begin
    if not PrintersDetected then
    begin
      MsgBox('No Windows printer was detected on this machine. Install your DYMO printer driver first, then re-run this installer.', mbError, MB_OK);
      Result := False;
    end
    else
      // A real bug, found the hard way: PrinterCombo.Text did not
      // reliably reflect a programmatically-set ItemIndex when there was
      // only one detected printer -- with nothing to actually choose
      // between, the user never clicks into the dropdown, and this
      // TNewComboBox's .Text apparently depends on that interaction to
      // sync, even though .ItemIndex and .Items were both already
      // correct. Reading Items[ItemIndex] directly sidesteps whatever
      // internal sync .Text depends on, and capturing it here -- right
      // when the user confirms this page -- rather than re-reading the
      // control much later in WriteEnvFile is extra insurance against
      // the same class of staleness.
      SelectedPrinterName := PrinterCombo.Items[PrinterCombo.ItemIndex];
  end;
end;

// Writes the real per-customer config: the exact OS printer name the
// wizard collected, plus the fixed port both this installer and
// local-agent.js agree on. dotenv.config() in local-agent.js reads this
// with no path argument, resolving relative to its own working
// directory -- which NSSM's AppDirectory (set in the [Run] section
// below) points here, at {app}\bridge. That combination is a
// specifically hard-won fix (see local-agent.js's own header comment,
// inherited from this project's earlier C-Flow-derived design) for
// config not reaching the process reliably under NSSM.
procedure WriteEnvFile;
var
  EnvPath: String;
  Lines: TStringList;
begin
  EnvPath := ExpandConstant('{app}\bridge\.env');
  Lines := TStringList.Create;
  try
    Lines.Add('PRINTER_NAME=' + SelectedPrinterName);
    Lines.Add('PORT=' + '{#MyAgentPort}');
    Lines.SaveToFile(EnvPath);
  finally
    Lines.Free;
  end;
end;

// Reads the just-written .env back and confirms PRINTER_NAME actually
// landed with a real value -- a direct, specific check, rather than
// relying solely on the much later GET /health failure to notice
// something went wrong (that still works as a backstop, but by then the
// only symptom is a generic "health check failed," with no indication
// *why*). Deliberately re-parses the file from disk rather than just
// checking SelectedPrinterName in memory, since the thing actually worth
// verifying is what WriteEnvFile really wrote, not what we intended to.
function VerifyEnvFile(): Boolean;
var
  EnvPath: String;
  Lines: TStringList;
  i: Integer;
  Prefix: String;
  Value: String;
begin
  Result := False;
  EnvPath := ExpandConstant('{app}\bridge\.env');
  if not FileExists(EnvPath) then
    Exit;

  Prefix := 'PRINTER_NAME=';
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(EnvPath);
    for i := 0 to Lines.Count - 1 do
    begin
      if Pos(Prefix, Lines[i]) = 1 then
      begin
        Value := Trim(Copy(Lines[i], Length(Prefix) + 1, MaxInt));
        Result := Value <> '';
        Exit;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  // Runs after [Files] are copied but before the [Run] section's nssm
  // commands execute (ssPostInstall fires in that order) -- the service
  // must never start before .env exists, or NSSM's own restart throttle
  // kicks in against a process that immediately exits via requireEnv().
  if CurStep = ssPostInstall then
  begin
    WriteEnvFile;
    if not VerifyEnvFile then
    begin
      EnvWriteFailed := True;
      MsgBox(
        'The selected printer name was not written to the agent''s configuration file (' +
        ExpandConstant('{app}') + '\bridge\.env). PRINTER_NAME ended up empty -- the printer ' +
        'service will not be able to start. Please reinstall and confirm a printer is selected ' +
        'on the "Select Printer" page before continuing.',
        mbError, MB_OK);
    end;
  end;
end;

[Run]
; Sequential, declarative nssm calls -- install the service pointing
; node.exe at local-agent.js, set its working directory (the
; AppDirectory fix), route its output to a log file, enable auto-start,
; then start it immediately. Each waits for the previous to finish
; (default behavior) since each step depends on the last. The health
; check (CurPageChanged above, on the Finished page) runs after all of
; these have completed.
Filename: "{app}\tools\nssm.exe"; Parameters: "install {#MyServiceName} ""{app}\bridge\node.exe"" ""local-agent.js"""; Flags: runhidden waituntilterminated
Filename: "{app}\tools\nssm.exe"; Parameters: "set {#MyServiceName} AppDirectory ""{app}\bridge"""; Flags: runhidden waituntilterminated
Filename: "{app}\tools\nssm.exe"; Parameters: "set {#MyServiceName} AppStdout ""{app}\bridge\log.txt"""; Flags: runhidden waituntilterminated
Filename: "{app}\tools\nssm.exe"; Parameters: "set {#MyServiceName} AppStderr ""{app}\bridge\log.txt"""; Flags: runhidden waituntilterminated
Filename: "{app}\tools\nssm.exe"; Parameters: "set {#MyServiceName} AppRotateFiles 1"; Flags: runhidden waituntilterminated
Filename: "{app}\tools\nssm.exe"; Parameters: "set {#MyServiceName} Start SERVICE_AUTO_START"; Flags: runhidden waituntilterminated
Filename: "{app}\tools\nssm.exe"; Parameters: "start {#MyServiceName}"; Flags: runhidden waituntilterminated

[UninstallRun]
; Stop and remove the service BEFORE [UninstallDelete]/the standard
; uninstall process removes {app}'s files -- a leftover orphaned service
; pointing at deleted files is a real mess to debug later. RunOnceId is
; required by Inno Setup for every [UninstallRun] entry.
Filename: "{app}\tools\nssm.exe"; Parameters: "stop {#MyServiceName}"; Flags: runhidden waituntilterminated; RunOnceId: "StopService"
Filename: "{app}\tools\nssm.exe"; Parameters: "remove {#MyServiceName} confirm"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveService"
