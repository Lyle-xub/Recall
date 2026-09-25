# Recall 玻璃档案界面

分支：`feat/rhine-glass-replica`。基线：`5391af1`（原项目首次快照）。本次修改针对 macOS 原生界面。

## 画面与交互

根据用户提供的参考图迭代相机、卡片倾角、前排高度、玻璃厚度、反光和景深。最终使用 SceneKit 的真实三维卡片，SwiftUI 保留品牌、工具栏、搜索和记录操作。截图内容与品牌保留 Recall，不使用参考图中的音乐封面或水印。

- 首页最多展示最近 96 张不同路径的真实截图，读取时排除 Demo；每张截图仅生成一个卡片节点，侧排同样由不同的真实记录组成。记录不足时不生成填充卡片。完整记录仍通过记忆库与时间线浏览。
- 滚轮与触控板纵向移动阵列；横向滑动或按住拖动浏览两侧，支持系统的触控板惯性事件和边界限制。
- 中央尖峰与两侧宽缓山肩构成连续高度场；鼠标位置和滚动推动波峰，各排通过保留速度的阻尼弹簧依次起伏，停止输入后自然收稳。
- 点击记录先滑出队列，再转向镜头；收起、点击空白或 Esc 沿同一路径归位。中途反向操作保留当前位置和速度，不跳回起点。
- 截图、信息和操作按钮始终附着在同一个 SceneKit 卡片节点。取出／收回不更换封面、不使用淡入淡出，也不另建详情卡片；收藏或加载图片保留移动节点。
- 全程使用保持原始比例的完整真实截图和固定玻璃雾化纹理。景深连续变化，展开终点保证截图与操作文字清晰。收藏、复制识别文字、回到此刻接入原有记录操作。
- 保持搜索返回后的阵列状态；响应系统减少动态效果设置；无障碍卡片名称附真实记录时间。

## 验证

2026-09-25 最新山脊修订：原生编译通过；21 项检查全部通过。包含高度场连续性、波峰移动、弹簧中途反向、抽出路径连续性，以及真实记录的节点身份、不透明度和归位终点检查。

运行原生编译及 ArchiveRidgeMotionTests、ArchiveVisualTests、OverlayRefinementTests、ResponsivenessTests、SearchAndUsageTests、MemoryTests 范围的验证。视觉测试需要显式提供真实记录库，默认跳过，不会生成或导入 Demo。

```sh
swift build --package-path macOS
RECALL_ARCHIVE_SOURCE_ROOT="$HOME/Library/Application Support/RewindReplica" \
RECALL_ARCHIVE_RENDER_DIR="$PWD/.test-data/rhine-ridge-verified" \
swift test --package-path macOS --filter 'ArchiveRidgeMotionTests|ArchiveVisualTests|OverlayRefinementTests|ResponsivenessTests|SearchAndUsageTests|MemoryTests'
```

视觉测试以只读方式读取原库，保留记录 ID、时间与内容，将实际截图的预览副本写入独立测试目录。不会修改原始截图或原库。测试截图包含私人记录，因此保存在被 Git 忽略的 `.test-data` 中，不随源码提交。

检查尺寸包含 2000×876（与参考图内容区一致）、1440×900 和 800×600，并检查暖昼、深夜与展开状态。SceneKit 的 Metal 层由其原生 snapshot API 获取，再纳入完整界面截图，避免 AppKit 截图遗漏 Metal 内容。

已通过桌面交互检查：真实卡片展开、Esc 收起、滚轮推动阵列、滚动后的卡片鼠标命中。没有声称经过持续帧率测量；Windows 界面未在此分支迁移。

本轮以同一批真实记录输出 16 张原生验证图，包含左右波峰、取出四个时点、归位四个时点及多尺寸界面。在原图同尺寸内容区反复对照后，降低右侧山肩、调整抽出路径避免顶部越界，并修正展开时过度虚化。`.test-data/rhine-ridge-verified/comparison.html` 提供参考图覆盖比较与动作关键帧滑块。桌面预览中复核了真实记录展开和 Esc 收回。
