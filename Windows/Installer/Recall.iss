#define AppVersion "0.4.25"
[Setup]
AppId={{6A7E030D-CB62-4823-A7BC-DC93DA8E9B18}
AppName=Recall
AppVersion={#AppVersion}
AppPublisher=Recall
DefaultDirName={localappdata}\Programs\Recall
DefaultGroupName=Recall
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22621
OutputDir=..\..\release
OutputBaseFilename=Recall-Windows-x64-Setup
SetupIconFile=..\Recall.WinUI\Assets\Recall.ico
UninstallDisplayIcon={app}\Recall.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
WizardSizePercent=110
CloseApplications=yes
RestartApplications=no
[Files]
Source: "..\..\release\recall-windows-x64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Recall"; Filename: "{app}\Recall.exe"
[Run]
Filename: "{app}\Recall.exe"; Description: "Open Recall"; Flags: nowait postinstall skipifsilent
[UninstallDelete]
Type: files; Name: "{userstartup}\Recall.lnk"
