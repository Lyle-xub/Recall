#define AppVersion "0.4.26"
#ifndef SourceDir
  #define SourceDir "..\..\release\recall-windows-x64"
#endif
#ifndef InstallerOutputDir
  #define InstallerOutputDir "..\..\release"
#endif
#ifndef InstallerFilename
  #define InstallerFilename "Recall-Windows-x64-Setup"
#endif
#ifndef InstallerAppId
  #define InstallerAppId "{{6A7E030D-CB62-4823-A7BC-DC93DA8E9B18}"
#endif
#ifndef InstallerGroup
  #define InstallerGroup "Recall"
#endif
[Setup]
AppId={#InstallerAppId}
AppName=Recall
AppVersion={#AppVersion}
AppPublisher=Recall
DefaultDirName={localappdata}\Programs\Recall
DefaultGroupName={#InstallerGroup}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22621
OutputDir={#InstallerOutputDir}
OutputBaseFilename={#InstallerFilename}
SetupIconFile=..\Recall.WinUI\Assets\Recall.ico
UninstallDisplayIcon={app}\Recall.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
WizardSizePercent=110
CloseApplications=yes
RestartApplications=no
[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Recall"; Filename: "{app}\Recall.exe"
Name: "{autodesktop}\Recall"; Filename: "{app}\Recall.exe"; Tasks: desktopicon
[Run]
Filename: "{app}\Recall.exe"; Description: "Open Recall"; Flags: nowait postinstall skipifsilent
[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  RunCommand: String;
begin
  if CurUninstallStep = usPostUninstall then
    if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Recall', RunCommand) then
      if CompareText(RunCommand, '"' + ExpandConstant('{app}\Recall.exe') + '" --background') = 0 then
        RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Recall');
end;
