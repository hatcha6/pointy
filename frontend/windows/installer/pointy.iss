; Inno Setup script for the Pointy Windows POS app.
;
; Produces a single setup.exe that installs the Flutter build (the app, its DLLs,
; the bundled Visual C++ runtime, and the data/ folder), creates Start Menu and
; optional desktop shortcuts, and registers an uninstaller in Add/Remove
; Programs. The release workflow invokes it as:
;
;   ISCC.exe /DAppVersion=1.2.3 /DSourceDir=<Release folder> /DOutputDir=<dist> pointy.iss
;
; SourceDir must point at the built Release folder AFTER the VC++ runtime DLLs
; have been copied in, so they ship inside the installer too.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\..\dist"
#endif

#define AppName "Pointy"
#define AppPublisher "Pointy"
#define AppExeName "pointy_frontend.exe"

[Setup]
; Stable AppId — keep this constant across releases so upgrades and uninstall work.
AppId={{38AF6CF1-834E-4C16-8EE2-513B5E0B1557}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
OutputDir={#OutputDir}
OutputBaseFilename=pointy-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; x64 only (Flutter Windows is 64-bit). x64compatible also covers ARM64 Windows
; running the x64 build under emulation, widening device support.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Per-machine install so every cashier user on the till sees the app.
PrivilegesRequired=admin
; Flutter Windows requires Windows 10+; show a clean message instead of crashing.
MinVersion=10.0
; Best-effort close a running instance during an upgrade.
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; Clean up the launch-at-startup entry that the app's "run on startup" toggle
; (autostart_channel.cpp) writes. ValueType: none means the installer never
; creates it — the app owns that, opt-in — we only delete it on uninstall.
; Covers the installing user's hive; a stale Run value left in another user's
; hive is harmless, as Windows ignores Run entries whose target is missing.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Pointy"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
