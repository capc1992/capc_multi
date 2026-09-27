#ifndef MyAppVersion
  #error MyAppVersion must be provided by build-windows-installer.ps1
#endif
#ifndef MyAppBuildVersion
  #error MyAppBuildVersion must be provided by build-windows-installer.ps1
#endif
#ifndef ReleaseDir
  #error ReleaseDir must be provided by build-windows-installer.ps1
#endif
#ifndef ProjectDir
  #error ProjectDir must be provided by build-windows-installer.ps1
#endif

#define MyAppName "CAPC MULTISERVICIO"
#define MyAppExeName "capc_multi.exe"

[Setup]
AppId={{9A6B92F7-CB1F-49B3-9D91-7358AE30A3A8}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher=CAPC MULTISERVICIO
VersionInfoVersion={#MyAppBuildVersion}
VersionInfoCompany=CAPC MULTISERVICIO
VersionInfoDescription=Instalador de CAPC MULTISERVICIO
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppBuildVersion}
DefaultDirName={localappdata}\Programs\CAPC MULTISERVICIO
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#ProjectDir}\dist
OutputBaseFilename=CAPC-MULTISERVICIO-Setup-{#MyAppVersion}
SetupIconFile={#ProjectDir}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
UsePreviousAppDir=yes
UsePreviousTasks=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Accesos directos:"; Flags: checkedonce

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#ProjectDir}\docs\ABRIR-Y-RESPALDAR.md"; DestDir: "{app}"; DestName: "LEEME.md"; Flags: ignoreversion
Source: "{#ProjectDir}\docs\GUIA-OPERACION.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectDir}\docs\RECUPERAR-ACCESO.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ProjectDir}\docs\EXCEL.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Abrir {#MyAppName}"; Flags: nowait postinstall skipifsilent
