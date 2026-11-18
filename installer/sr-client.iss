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

[Registry]
; srclient://game?action=host-comp&... tournament host links (src/client/host_link.odin),
; for this user only, like the install itself. Removed on uninstall.
Root: HKCU; Subkey: "Software\Classes\srclient"; ValueType: string; ValueName: ""; ValueData: "URL:SR Client"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\srclient"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\srclient\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\sr_client.exe"",0"
Root: HKCU; Subkey: "Software\Classes\srclient\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\sr_client.exe"" ""%1"""

[Run]
Filename: "{app}\sr_client.exe"; WorkingDir: "{app}"; Description: "Start SR Client"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"
