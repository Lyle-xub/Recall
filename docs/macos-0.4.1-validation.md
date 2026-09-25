# Recall 0.4.1 时间线与全屏唤起修复

日期：2026-09-25。macOS 原生版本；Windows 未修改。

## 最终实现

- 时间线应用图标使用统一基线。密集片段合并为带数量标记的入口，可展开到每条记录，不再按序号上下错排。
- 零时长的孤立截图画为圆点，轨道使用轻量时间刻度连接视觉方向。没有录制的间隔仍保持空档，不伪造连续记录。
- 底部独立原生 NSPanel 覆盖屏幕底部 220 点，使用真实桌面的 NSVisualEffectView；输入区域接收点击、拖动和滚轮。
- 渐变遮罩在第一次绘制之前安装，移除异步截图背景和矩形占位层，避免启动闪出整块模糊。
- 按用户最新决定，打开 Recall 界面时使用 AppKit 的 `hideDock` 隐藏并禁用 Dock 唤出，关闭、隐藏、失去激活或退出时恢复原来的应用 presentation options。没有修改持久的 Dock 设置。
- 删除所有鼠标事件过滤、重建和重新投递代码；鼠标继续由系统原生分发。此功能不再需要辅助功能权限，已有授权不作更改。
- Recall 使用 accessory 应用模式。主界面和时间线均为 nonactivating NSPanel，使用 `canJoinAllSpaces`、`canJoinAllApplications` 和 `fullScreenAuxiliary`，以覆盖当前应用的全屏 Space。

## 自动检查

- `swift test --package-path macOS`：31 项，30 项通过，1 项需显式开启的真实模型测试跳过。
- 覆盖密集片段中的应用保留、44 点点击区域防碰撞、缩放和裁切、首次布局前遮罩准备、重复打开/关闭时 Dock 选项准确恢复、全屏窗口策略，以及既有录制/OCR/搜索检查。
- Release 构建通过；Developer ID 深度签名校验通过。应用标识与签名团队不变。
- 发行包：`release/Recall-macOS.zip`；SHA-256：`release/checksums.json`。0.4 原包：`release/previous/Recall-macOS-0.4.0.zip`。
- Windows ZIP 校验值保持 `56b2576fc9d5779e85734a1498b094249a68055fc57c09045045d7cef6adde1f`。

## 实机验收

- 安装到 `/Applications/Recall.app`，未使用 Demo，未重置权限、历史数据或模型。
- 07:52:59 普通启动：系统 presentation 状态确认 `dockHidden=true; currentSpace=true`。
- 将 Finder 切换到真正的全屏 Space，再使用 ⌘⇧Space 唤起 Recall；主界面及时间线正常出现，日志同样确认隐藏 Dock 和位于当前 Space。Esc 返回后 Finder 仍是原来的全屏窗口。
- 在该全屏 Space 中退出 Recall，再从 Finder 冷启动 Recall，07:54:44 再次确认 `dockHidden=true; currentSpace=true`。随后退出界面并将 Finder 恢复到原先的非全屏窗口模式。
- 07:55:20 恢复真实屏幕录制：ScreenCaptureKit 流运行，3024×1964 索引帧持续保存，OCR 完成。
- 此轮没有用程序模拟硬件悬停；之前事件过滤方案已因用户报告穿透/指针异常而移除。当前验收依据为系统实际隐藏 Dock 的状态、全屏唤起操作和原生事件路径，并非将点击拦截当作悬停测试。
