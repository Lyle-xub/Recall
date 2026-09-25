# Recall 玻璃档案界面

分支：`feat/rhine-glass-replica`。基线：`5391af1`（原项目首次快照）。本次修改针对 macOS 原生界面。

## 画面与交互

根据用户提供的参考图迭代相机、卡片倾角、前排高度、玻璃厚度、反光和景深。最终使用 SceneKit 的真实三维卡片，SwiftUI 保留品牌、工具栏、搜索和记录操作。截图内容与品牌保留 Recall，不使用参考图中的音乐封面或水印。

- 首页最多展示最近 96 张不同路径的真实截图，读取时排除 Demo；每张截图仅生成一个卡片节点，侧排同样由不同的真实记录组成。记录不足时不生成填充卡片。完整记录仍通过记忆库与时间线浏览。
- 滚轮与触控板纵向移动阵列；横向滑动或按住拖动浏览两侧，支持系统的触控板惯性事件和边界限制。
- 点击记录沿三维曲线滑出队列并转正；收起、点击空白或 Esc 沿曲线归位。中途反向操作从当前显示的变换继续，不跳回起点。
- 展开时显示保持原始比例的完整截图；收起状态使用保持比例的裁切缩略图与玻璃雾化。收藏、复制识别文字、回到此刻接入原有记录操作。
- 保持搜索返回后的阵列状态；响应系统减少动态效果设置；无障碍卡片名称附真实记录时间。

## 验证

2026-09-25：原生编译通过；选定范围 18 项检查通过，随后补充的实际卡片数量／无重复填充检查通过。

运行原生编译及 ArchiveVisualTests、OverlayRefinementTests、ResponsivenessTests、SearchAndUsageTests、MemoryTests 范围的验证。视觉测试需要显式提供真实记录库，默认跳过，不会生成或导入 Demo。

```sh
swift build --package-path macOS
RECALL_ARCHIVE_SOURCE_ROOT="$HOME/Library/Application Support/RewindReplica" \
RECALL_ARCHIVE_RENDER_DIR="$PWD/.test-data/rhine-real-final" \
swift test --package-path macOS --filter 'ArchiveVisualTests|OverlayRefinementTests|ResponsivenessTests|SearchAndUsageTests|MemoryTests'
```

视觉测试以只读方式读取原库，保留记录 ID、时间与内容，将实际截图的预览副本写入独立测试目录。不会修改原始截图或原库。测试截图包含私人记录，因此保存在被 Git 忽略的 `.test-data` 中，不随源码提交。

检查尺寸包含 2000×876（与参考图内容区一致）、1440×900 和 800×600，并检查暖昼、深夜与展开状态。SceneKit 的 Metal 层由其原生 snapshot API 获取，再纳入完整界面截图，避免 AppKit 截图遗漏 Metal 内容。

已通过桌面交互检查：真实卡片展开、Esc 收起、滚轮推动阵列、滚动后的卡片鼠标命中。没有声称经过持续帧率测量；Windows 界面未在此分支迁移。
