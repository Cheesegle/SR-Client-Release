; SR Client installer (Inno Setup 6). Built by .github/workflows/build.yml.
; Per-user install like glorp: no admin prompt, and the game can write logs/
; and settings next to itself.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef StageDir
  #define StageDir "..\stage"
#endif

[Setup]
AppId={{6E1B4C2A-5D3F-4F8E-9A71-3C2B8E0D5A17}
AppName=SR Client
AppVersion={#AppVersion}
AppPublisher=SR Client
DefaultDirName={localappdata}\SR-Client\app
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=SR-Client-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=SR Client
CloseApplications=yes
SetupIconFile=sr-client.ico
UninstallDisplayIcon={app}\sr_client.exe

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: checkedonce

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\SR Client"; Filename: "{app}\sr_client.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\SR Client"; Filename: "{app}\sr_client.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\sr_client.exe"; WorkingDir: "{app}"; Description: "Start SR Client"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
