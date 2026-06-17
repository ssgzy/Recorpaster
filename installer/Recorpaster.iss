; Inno Setup 脚本：把 PyInstaller onedir 产物打成单文件安装器（可选，CI 里 continue-on-error）。
; 本地：先 pyinstaller Recorpaster-win.spec，再用 Inno Setup 编译本文件。
[Setup]
AppName=Recorpaster
AppVersion=1.0.0
AppPublisher=Recorpaster
DefaultDirName={autopf}\Recorpaster
DefaultGroupName=Recorpaster
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=Recorpaster-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
WizardStyle=modern

[Languages]
Name: "chs"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "eng"; MessagesFile: "compiler:Default.isl"

[Files]
; onedir 产物整目录拷入（相对本 .iss 所在 installer/ 目录，dist 在仓库根）
Source: "..\dist\Recorpaster\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Recorpaster"; Filename: "{app}\Recorpaster.exe"
Name: "{userdesktop}\Recorpaster"; Filename: "{app}\Recorpaster.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"

[Run]
; 若带了 WebView2 引导器（CI 会下载进产物），静默确保运行时已装（已装则秒退）。
Filename: "{app}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "正在确保 WebView2 运行时已安装…"; Flags: waituntilterminated; Check: FileExists(ExpandConstant('{app}\MicrosoftEdgeWebview2Setup.exe'))
Filename: "{app}\Recorpaster.exe"; Description: "立即启动 Recorpaster"; Flags: nowait postinstall skipifsilent
