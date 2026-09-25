# Windows 原生迁移 0.4.25 · 验证状态

日期：2026-09-25。对齐基准：macOS Recall 0.4.25（33）。

**这是已实现、通过 C# 编译的 Windows 原生迁移代码，不是已完成 Windows 真机验收的发行包。** 当前工作主机为 Apple Silicon macOS，没有可运行的 Windows 11 环境；仓库没有远程地址，未触发远程 CI。不能用这里的源码编译结果证明玻璃材质、悬停拦截或录音已在 Windows 上通过。

## 实现范围

| 模块 | 实现 |
|---|---|
| 原生界面 | WinUI 3 / Windows App SDK 2.5.1；C# 构造原生控件，无 WebView；旧 WPF 项目只保留作历史参考 |
| 桌面窗口 | Win32 无边框置顶覆盖当前鼠标所在显示器；完整命中区域；可自定义全局快捷键、托盘、任务栏图标与登录启动 |
| 材质与时间线 | Windows HostBackdrop + Composition 渐变蒙版；首页只模糊底部与搜索控件；连续独立应用时段、图标取色、紧凑图标/时间弹层、日期定位、1 分钟至 24 小时缩放 |
| 搜索与回看 | 前缀、大小写、重音符号、中文片段、多词；应用/日期/收藏/回收站筛选；分页、OCR 命中描边、缩小历史截图、跨行拖选和复制 |
| 视频与音频 | 720 最长边、1 fps、100 kbps CBR 直接录制；新视频无内嵌音频，独立系统/麦克风音轨同步播放；照片与播放器圆角 |
| OCR | 与 Mac 同一份 PP-OCRv6 Small 权重和前后处理逻辑；单独进程执行、30 秒超时，20 秒 Tesseract LSTM 备用；原始 PNG 先识别、再归档；失败保留原图，可重试 |
| 存储 | 384 像素共享图块、PNG/质量 0.5 JPEG 自适应；完全相同静止画面复用持续区间；共享 OCR、外部内容 FTS；真实分类占用、图像/视频优化、范围清理与收藏/录制保护 |
| 转写 | 自动后台队列；空白结果过滤；跨音轨完全重复句消重；匿名音轨单侧显示、可复制和定位；当前图片/录制的状态胶囊 |
| 模型与 Ask | 内置 Qwen3/Whisper 下载、进度、暂停、SHA 校验；已有本地和 HTTPS 在线接口；DPAPI 密钥；基于真实检索结果流式问答、取消、来源跳转，无示例问题 |
| 使用时间 | 独立应用时段清单、每日合计、周/小时图、排行、搜索和月历；跨午夜/夏令时计算 |
| 品牌与引导 | 与 Mac 共用 Recall、Halo、虹彩纹理、7.2 秒无敲击音效；暗场玻璃/光环/名称/白场图标序列按动画完成推进；五步原生引导、静音、跳过、减少动画 |
| 其他 | 图片导入、媒体/JSON 导出、收藏、可恢复删除、保留期限、应用排除；会议副画面保存当前屏幕中实际可见的会议区域，不采集被遮挡内容 |

Windows 采用 Segoe UI / Segoe Fluent Icons 与 Windows 键位。玻璃渲染用 Windows Composition 实现，需要在 Windows 上与 Mac 并排校准，不能声称与 Apple 的私有 Liquid Glass 像素相同。

## 已执行

- 核心检查 **57 项通过**：`dotnet run --project Windows/Rewind.Tests/Rewind.Tests.csproj`。
- 原生界面/服务/OCR 源码编译 **0 错误、0 警告**：`dotnet build Windows/Recall.WinUI/Recall.WinUI.csproj -p:Platform=x64 -p:RecallSourceCheck=true`。此模式明确跳过 Windows 专用的 manifest/PRI 生成，输出不能作为安装包发布。
- 覆盖搜索 `paper → papers`、中文、重音、多词、SQL 字符转义；共享 OCR；持续区间与转写定位；录制状态竞争；独立应用区间/夏令时；图块格式验证、清理共享引用、删除与识别并发。
- Mac 应用源代码、已公证 App、DMG、ZIP 未修改。

## 源码交付

`release/Recall-Windows-source.zip` 包含原生界面、共享服务、OCR 进程、测试、品牌素材和 Windows 构建脚本；每个文件的校验值记录在包内 `MANIFEST.sha256`。不包含用户数据、旧 Demo 或 Mac 发布文件。解压后从根目录执行构建脚本。此文件为源码包，并非已生成的安装器。

## Windows 上的下一步

安装 .NET 10 SDK、Python 3、Visual C++ x64 Runtime；可选 Inno Setup 6。运行：

```powershell
./scripts/build-windows.ps1
```

脚本核验并准备模型/推理引擎、执行核心检查、生成完整自包含应用，再执行原生 smoke 测试。测试使用隔离临时库，生成公开文字图，检查 OCR / 前缀搜索 / 图块，打开五个页面保存截图，并进行约 3.5 秒屏幕录制；不录麦克风或系统音频。结果在 `release/windows-smoke`。默认任一检查失败即阻止打包；`-SkipSmoke` 只用于诊断构建，不表示验收通过。

通过后输出 `release/Recall-Windows-x64.zip`；检测到 Inno Setup 时同时输出 `release/Recall-Windows-x64-Setup.exe`。新的构建使用 `release/recall-windows-x64`，不会覆盖旧 WPF 包或 Mac 包。Windows 安装包目前未签名。

仍须人工验证：

- 100% / 150% / 200% DPI、多显示器及全屏应用中唤起。
- 时间线与任务栏反复移入/移出，点击、悬停均无穿透；关闭后焦点恢复。
- 明暗桌面上的玻璃透明度、圆角、渐变边界、弹出动效与 Mac 并排对齐。
- 麦克风权限拒绝/允许、真实分轨音频与视频同步、静音段转写。
- 连续使用、锁屏/睡眠恢复、大库滚动和真实 CPU/磁盘占用。
- 内置模型真实下载与离线回答、用户提供的在线模型接口。

上述 Windows 原生测试脚本及 CI 已写好，但尚未执行；没有把测试准备工作计为通过。
