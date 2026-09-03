[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppVerName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

[Code]
function IsAppRunning: Boolean;
var
  Output: AnsiString;
  ResultCode: Integer;
begin
  Exec('cmd.exe', '/C tasklist /FI "IMAGENAME eq {{EXECUTABLE_NAME}}" 2>nul | findstr "{{EXECUTABLE_NAME}}"',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
end;

function InitializeSetup(): Boolean;
var ResultCode: Integer;
begin
  if IsAppRunning then begin
    if MsgBox('检测到 {{DISPLAY_NAME}} 正在运行，需要关闭后才能继续安装。'#13#10#13#10'点击"是"关闭程序并继续安装，点击"否"取消安装。',
             mbConfirmation, MB_YESNO) = IDYES then
    begin
      Exec('taskkill', '/F /IM {{EXECUTABLE_NAME}}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Result := True;
    end else
      Result := False;
  end else
    Result := True;
end;

function InitializeUninstall(): Boolean;
begin
  if IsAppRunning then begin
    MsgBox('请先关闭 {{DISPLAY_NAME}} 再进行卸载。', mbError, MB_OK);
    Result := False;
  end else
    Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppDataPath: String;
  ResultCode: Integer;
begin
  if CurUninstallStep = usPostUninstall then begin
    if MsgBox('是否同时删除 {{DISPLAY_NAME}} 的应用数据？'#13#10#13#10'（包括下载缓存、日志、设置等）',
             mbConfirmation, MB_YESNO) = IDYES then
    begin
      AppDataPath := ExpandConstant('{localappdata}\senarepo');
      Exec('cmd.exe', '/C rmdir /S /Q "' + AppDataPath + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      AppDataPath := ExpandConstant('{userappdata}\senarepo');
      Exec('cmd.exe', '/C rmdir /S /Q "' + AppDataPath + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;
  end;
end;

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "startmenu"; Description: "创建开始菜单快捷方式"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "launchAtStartup"; Description: "{cm:AutoStartProgram,{{DISPLAY_NAME}}}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{{SOURCE_DIR}}\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; NOTE: Don't use "Flags: ignoreversion" on any shared system files

[Icons]
Name: "{autoprograms}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: startmenu
Name: "{autodesktop}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; Tasks: desktopicon
Name: "{userstartup}\\{{DISPLAY_NAME}}"; Filename: "{app}\\{{EXECUTABLE_NAME}}"; WorkingDir: "{app}"; Tasks: launchAtStartup

[Run]
Filename: "{app}\\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: runascurrentuser nowait postinstall skipifsilent
