# Recall 0.4.25 (33) 验证

2026-09-25，macOS 本机，安装位置 `/Applications/Recall.app`。

## 交付

- 图标：珍珠白底座，放大 35% 并淡化 15% 的虹彩玻璃；中央倾斜光环，右下粗亮边、左上柔光。原生分层图标和兼容 ICNS 同步更新。
- 菜单栏：单色光环随系统明暗切换，实际录制时显示红点；菜单包含打开、录制、使用时间、设置、重播引导和退出。
- 首次启动：全屏玻璃展开、光环浮现、品牌文字、白色收尾，最终图标停留后淡入引导。静音和跳过控件始终位于屏幕内。
- 音效：原创合成的空灵泛音，移除敲击、拨弦与金属铃声；慢渐入、立体声扩散混响、余音渐出，无外部采样。7.2 秒，PCM16 / 44.1 kHz / stereo，文件峰值 -9 dBFS，应用播放音量 0.5。
- 已有用户升级不强制播放。菜单 `Welcome to Recall…` 可重播；减少动态效果时静态展示且静音。

## 提前切页修复

旧流程用固定的 sleep 推进和结束，结束时并未等待 SwiftUI 渲染的动画完成。现改为每段 `withAnimation` 的 `.removed` 完成回调推进，收尾完成后再保留 1 秒。消失中的开场保持上层，避免新引导页直接遮挡收尾。每次重播分配新 identity，隐藏应用不再被当作播放完成，重新显示时重新完整播放。

实际安装包日志记录到完整顺序：

```text
12:11:35Z Launch film: started
12:11:36Z Launch film: glass settled
12:11:38Z Launch film: halo settled
12:11:39Z Launch film: name settled
12:11:41Z Launch film: reveal settled
12:11:42Z Launch film: completed
```

## 验证范围

- Release 编译通过（最终构建 33）。
- 4 项 OnboardingTests 通过：首次启动、已有库迁移、已播放状态持久化、保留录制和模型设置。
- 本机 UI 验证全屏控件位置、光环渲染、静音切换、跳过到引导；最终构建日志确认各段完成后才结束。
- WAV 验证时长 7.200 秒、左右声道首尾为零、无削波；RMS -21.14 dBFS。未将自动化数值检查视为听感评价。
- DMG 使用简洁背景与应用拖入 Applications 布局。已安装应用、release 应用、挂载 DMG 与 ZIP 的二进制、图标、玻璃、光环、音效一致；Developer ID 严格签名验证、DMG 校验、ZIP CRC 均通过。
- Windows ZIP 的 SHA-256 保持 `56b2576fc9d5779e85734a1498b094249a68055fc57c09045045d7cef6adde1f`。
- 未清除用户数据、模型或系统授权。后续已完成应用和 DMG 的 Apple 公证、票据附加及 Gatekeeper 检查，详见 [公证记录](macos-0.4.25-notarization.md)。

图像材质的内置生成模式、实际提示词与保存路径见 [branding-glass-material.md](branding-glass-material.md)。音效源代码为 `scripts/artwork/make-opening-sound.py`。
