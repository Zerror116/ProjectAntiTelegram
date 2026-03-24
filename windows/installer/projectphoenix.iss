#define MyAppName "ProjectPhoenix"
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif
#ifndef MySourceDir
  #define MySourceDir "..\\..\\build\\windows\\x64\\runner\\Release"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\\..\\dist"
#endif
#ifndef MyBaseName
  #define MyBaseName "projectphoenix-setup"
#endif
#ifndef MyAppExeName
  #define MyAppExeName "projectphoenix.exe"
#endif

[Setup]
AppId={{8A6ED958-E4D0-4E7B-A16A-50893B0E2BE3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\ProjectPhoenix
DisableProgramGroupPage=yes
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyBaseName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#MySourceDir}\\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\\ProjectPhoenix"; Filename: "{app}\\{#MyAppExeName}"
Name: "{autodesktop}\\ProjectPhoenix"; Filename: "{app}\\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\\{#MyAppExeName}"; Description: "{cm:LaunchProgram,ProjectPhoenix}"; Flags: nowait postinstall skipifsilent
