; Unison Windows 安装包脚本（Inno Setup 6）
; 免管理员：装到 %LOCALAPPDATA%\Programs（PrivilegesRequired=lowest），
; 同一 AppId 覆盖安装即升级，桌面/开始菜单快捷方式，自带卸载程序。

#define AppVersion "0.0.0"  ; CI 用 tag 号替换

[Setup]
AppId={{7E9C2B1A-4F6D-4E2A-9B3C-1D5A8F0E2C44}
AppName=Unison
AppVersion={#AppVersion}
AppVerName=Unison {#AppVersion}
AppPublisher=Eli Hong
DefaultDirName={autopf}\Unison
DefaultGroupName=Unison
OutputDir=.
OutputBaseFilename=unison-windows-setup
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
WizardStyle=modern
UninstallDisplayIcon={app}\unison.exe

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; \
  Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Unison"; Filename: "{app}\unison.exe"
Name: "{autodesktop}\Unison"; Filename: "{app}\unison.exe"
