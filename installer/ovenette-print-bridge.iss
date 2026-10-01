; Ovenette Print Bridge -- Inno Setup installer.
;
; Builds a self-contained Windows installer: no prerequisites, the
; customer just downloads and runs this .exe. Bundles a portable Node.js
; runtime and the already-`npm install`ed bridge script (see
; ../bridge/), plus NSSM (vendored at ../installer/vendor/nssm.exe) to
; install the bridge as a background Windows service.
;
; Deliberately NOTHING secret is baked in here -- this installer is a
; single public download every customer uses, so it's identical for all
; of them. The one build-time placeholder (MyApiBaseUrl) is the
; Ovenette app's URL, which isn't sensitive. Every real credential (the
; printer's API key, and a pair of scoped Azure SAS URLs -- never the
; account's full connection string) is typed/pasted in by the admin
; during install, from values generated per-printer in Ovenette's own
; admin UI (/admin/settings/labels). See bridge/poll-and-print.js's own
; header comment for why the SAS pair is scoped the way it is.
#ifndef MyApiBaseUrl
  #define MyApiBaseUrl "https://ovenettebakehouse.com"
#endif
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0-dev"
#endif

#define MyAppName "Ovenette Print Bridge"
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
; service lifecycle instead.
DisableWelcomePage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; The bridge script + its already-installed node_modules (installed by
; the release workflow on a Windows runner before compiling, so native/
; platform-specific bits -- pdf-to-printer bundles a Windows SumatraPDF
; binary -- are correct for this target). .env is deliberately excluded:
; it's written fresh by this installer for each customer, never copied
; from a build-time file.
Source: "..\bridge\*"; DestDir: "{app}\bridge"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: ".env,.env.example,.env.smoketest,*.log"
; Portable Node.js runtime, downloaded by the release workflow and
; staged into installer\node-runtime\ before compiling (see
; .github/workflows/release.yml) -- placed directly alongside
; poll-and-print.js so the NSSM service's Application path and
; AppDirectory can both point at the same {app}\bridge folder.
Source: "node-runtime\node.exe"; DestDir: "{app}\bridge"; Flags: ignoreversion
; NSSM itself, vendored directly in this repo (small, free,
; redistributable -- see vendor\README.txt).
Source: "vendor\nssm.exe"; DestDir: "{app}\tools"; Flags: ignoreversion

[Code]
var
  PrinterInfoPage: TInputQueryWizardPage;
  SetupCodePage: TWizardPage;
  SetupCodeMemo: TNewMemo;
  PrinterSelectPage: TWizardPage;
  PrinterCombo: TNewComboBox;
  PrintersDetected: Boolean;

const
  NoPrintersFoundLabel = '(No printers found -- install your DYMO driver first)';

procedure InitializeWizard;
begin
  PrinterInfoPage := CreateInputQueryPage(wpSelectDir,
    'Printer Information',
    'Enter a name and API key for this printer',
    'Both come from your Ovenette admin account, under Settings > Labels > Printers > Add Printer (or Regenerate API key). The API key is only ever shown there once, so generate or copy it before continuing.');
  PrinterInfoPage.Add('Printer label (for your own reference):', False);
  PrinterInfoPage.Add('API key:', True);

  SetupCodePage := CreateCustomPage(PrinterInfoPage.ID,
    'Setup Code',
    'Paste the setup code for this printer');

  SetupCodeMemo := TNewMemo.Create(SetupCodePage);
  SetupCodeMemo.Parent := SetupCodePage.Surface;
  SetupCodeMemo.Left := 0;
  SetupCodeMemo.Top := ScaleY(8);
  SetupCodeMemo.Width := SetupCodePage.SurfaceWidth;
  SetupCodeMemo.Height := ScaleY(80);
  SetupCodeMemo.ScrollBars := ssVertical;
  SetupCodeMemo.WantReturns := True;

  PrinterSelectPage := CreateCustomPage(SetupCodePage.ID,
    'Select Printer',
    'Choose the Windows printer this bridge should send labels to');

  PrinterCombo := TNewComboBox.Create(PrinterSelectPage);
  PrinterCombo.Parent := PrinterSelectPage.Surface;
  PrinterCombo.Left := 0;
  PrinterCombo.Top := ScaleY(8);
  PrinterCombo.Width := PrinterSelectPage.SurfaceWidth;
  PrinterCombo.Style := csDropDownList;

  PrintersDetected := False;
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

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = PrinterSelectPage.ID) and (PrinterCombo.Items.Count = 0) then
    DetectPrinters;
end;

// Scans the pasted Setup Code block for a "PREFIXvalue" line -- the
// format Ovenette's admin UI hands out is literally these two lines
// (see formatSetupCode in admin/settings/labels/actions.ts), so this is
// a trivial prefix scan, not a general parser. Deliberately not
// JSON/base64: Inno Setup's Pascal Script has no built-in JSON parser or
// base64 decoder, and hand-rolling either for an installer that can't be
// locally compiled/tested outside CI was a worse risk than a plain-text,
// human-readable format.
function ExtractSetupValue(const Prefix: String): String;
var
  i: Integer;
  Line: String;
begin
  Result := '';
  for i := 0 to SetupCodeMemo.Lines.Count - 1 do
  begin
    Line := Trim(SetupCodeMemo.Lines[i]);
    if Pos(Prefix, Line) = 1 then
    begin
      Result := Copy(Line, Length(Prefix) + 1, MaxInt);
      Exit;
    end;
  end;
end;

function GetQueueSasUrl(): String;
begin
  Result := ExtractSetupValue('QUEUE_SAS_URL=');
end;

function GetContainerSasUrl(): String;
begin
  Result := ExtractSetupValue('CONTAINER_SAS_URL=');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  if CurPageID = PrinterInfoPage.ID then
  begin
    if Trim(PrinterInfoPage.Values[0]) = '' then
    begin
      MsgBox('Please enter a printer label.', mbError, MB_OK);
      Result := False;
    end
    else if Trim(PrinterInfoPage.Values[1]) = '' then
    begin
      MsgBox('Please enter the API key.', mbError, MB_OK);
      Result := False;
    end;
  end;

  if CurPageID = SetupCodePage.ID then
  begin
    if (Pos('https://', GetQueueSasUrl()) <> 1) or (Pos('https://', GetContainerSasUrl()) <> 1) then
    begin
      MsgBox('That doesn''t look like a valid setup code. Copy the whole block from Ovenette''s admin -- it should have one QUEUE_SAS_URL= line and one CONTAINER_SAS_URL= line.', mbError, MB_OK);
      Result := False;
    end;
  end;

  if (CurPageID = PrinterSelectPage.ID) and not PrintersDetected then
  begin
    MsgBox('No Windows printer was detected on this machine. Install your DYMO printer driver first, then re-run this installer.', mbError, MB_OK);
    Result := False;
  end;
end;

// Writes the real per-customer config: the printer's API key, its two
// scoped Azure SAS URLs, and the exact OS printer name the wizard
// collected, plus the one build-time value (the Ovenette API URL --
// not secret) substituted by the release workflow. dotenv.config() in
// poll-and-print.js reads this with no path argument, resolving
// relative to its own working directory -- which NSSM's AppDirectory
// (set in the [Run] section below) points here, at {app}\bridge. That
// combination is the specific, previously hard-won fix (see
// poll-and-print.js's own header comment) for config not reaching the
// process reliably under NSSM.
procedure WriteEnvFile;
var
  EnvPath: String;
  Lines: TStringList;
begin
  EnvPath := ExpandConstant('{app}\bridge\.env');
  Lines := TStringList.Create;
  try
    Lines.Add('QUEUE_SAS_URL=' + GetQueueSasUrl());
    Lines.Add('CONTAINER_SAS_URL=' + GetContainerSasUrl());
    Lines.Add('OVENETTE_API_BASE_URL=' + '{#MyApiBaseUrl}');
    Lines.Add('PRINTER_API_KEY=' + PrinterInfoPage.Values[1]);
    Lines.Add('PRINTER_NAME=' + PrinterCombo.Text);
    Lines.SaveToFile(EnvPath);
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
    WriteEnvFile;
end;

[Run]
; Sequential, declarative nssm calls -- install the service pointing
; node.exe at poll-and-print.js, set its working directory (the
; AppDirectory fix), route its output to a log file, enable auto-start,
; then start it immediately. Each waits for the previous to finish
; (default behavior) since each step depends on the last.
Filename: "{app}\tools\nssm.exe"; Parameters: "install {#MyServiceName} ""{app}\bridge\node.exe"" ""poll-and-print.js"""; Flags: runhidden waituntilterminated
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
