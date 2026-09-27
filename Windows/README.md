# Recall for Windows · 原生迁移代码

以 macOS Recall 0.4.25 为基准，采用 WinUI 3、Windows App SDK、Win32 窗口和 Composition。图标、虹彩玻璃纹理、Halo 与开场音效直接使用同一份品牌素材；界面采用 Windows 原生控件。

Windows 0.4.26 将 Mac 的统一归档思路接入 Windows 原生采集与共享 CLI：卡片引用同源录屏的准确帧，旧图块按内容去重后打包，OCR 坐标无损压缩。旧图库继续兼容；实现和验收范围见 [统一归档记录](../docs/windows-unified-archive.md)。

## 在 Windows 构建

需要 Windows 11 22H2 或更新版本、x64、.NET 10 SDK、Python 3.12+、Microsoft Visual C++ x64 Runtime。可选安装 Inno Setup 6 以生成安装器。在仓库根目录打开 PowerShell：

```powershell
./scripts/build-windows.ps1
```

构建时需要联网下载 NuGet 依赖、经过 SHA-256 校验的原生推理引擎与 OCR 权重。内置聊天、语音模型由用户在应用内下载。运行已打包的应用无需 Python 或 .NET SDK。

脚本默认依次执行核心检查、自包含发布和原生 smoke 测试，全部成功后生成：

- `release/recall-windows-x64/Recall.exe`：完整应用目录，不可仅复制 exe。
- `release/Recall-Windows-x64.zip`：便携包。
- `release/Recall-Windows-x64-Setup.exe`：安装器，仅安装了 Inno Setup 时生成。
- `release/windows-smoke/`：测试报告与五个页面的截图。

Windows 安装器尚未配置代码签名证书。`-SkipSmoke` 仅供诊断，不能据此认定可发布。

## 使用

默认 `Ctrl + Shift + Space` 唤起，`Ctrl + Alt + Space` 为备用；托盘菜单也可打开。快捷键、登录启动、任务栏图标、麦克风与系统音频都可在设置中更改。

打开任何 Recall 界面会暂停采集，关闭界面后仅恢复原有录制意愿。已保存媒体的 OCR 与转写继续处理。默认数据目录为 `%LOCALAPPDATA%\Recall`，数据库、媒体、设置和内置模型统一存放于此。测试使用单独的临时库。

旧版默认目录 `%LOCALAPPDATA%\RewindReplica` 会在未被占用、且新目录不存在时整体迁移到 `Recall`。升级前退出旧版应用和 CLI；如果两个目录都存在，会提示冲突并保留两者。通过 `--data-dir` 或 `RECALL_DATA_DIR` 指定的自定义目录不自动迁移。

已使用 `%LOCALAPPDATA%\Recall\Data` 的 Windows 版本会由同一个 Core 解析器识别：仅有该数据库时，桌面和 CLI 原地复用它；如果它与 `Recall\memory.sqlite` 同时存在，则报告冲突，不创建空库或混合数据。

新录制保留屏幕原始尺寸，优先可用的硬件 HEVC，兼容回退到 H.264。卡片和录屏使用同一原始画面及准确视频时间戳；原始 PNG 留存到 OCR、视频落盘和精确解码验证都成功。已有 JPEG/PNG 图块无需重编码即可合并进有界 SQLite 包，优化不会重压作为卡片唯一来源的视频。

CLI 0.5.2 的 `recall recording start` 可自动启动安装在 `%LOCALAPPDATA%\Programs\Recall\Recall.exe` 的新版原生引擎。便携版可设置 `RECALL_WINDOWS_APP` 为桌面 exe 的绝对路径。CLI 启动的后台实例可用 `recall service stop` 完整退出；手动打开的应用仍由托盘退出。

## 工程

- `Windows/Recall.WinUI`：界面、窗口、设置、回看、Usage、引导与应用协调。
- `Core`：桌面和 CLI 共用的数据库、目录解析、搜索、使用时段、录制协调与模型服务。
- `Windows/Rewind`：由新项目链接的 Windows 采集、图片解码和凭据服务，以及旧 WPF 入口。
- `Windows/Recall.Ocr`：隔离进程中的 PP-OCRv6 / Tesseract 识别。
- `Windows/Rewind.Tests`：可在 macOS 执行的核心回归检查。
- `Windows/Rewind.ImageTests`：在 Windows 执行的原生图片拼接与缩放回归检查。
- `Windows/Installer`：Windows 安装器。

macOS 上可运行下面的源码检查；它会跳过 Windows manifest/PRI 工具，输出**不能用于发布**：

```sh
dotnet run --project Windows/Rewind.Tests/Rewind.Tests.csproj
dotnet build Windows/Recall.WinUI/Recall.WinUI.csproj -p:Platform=x64 -p:RecallSourceCheck=true
```

`scripts/package-windows-source.py` 可重建精简源码包；其中不包含用户数据、旧 Demo、SDK 缓存或 Mac 发布文件。
