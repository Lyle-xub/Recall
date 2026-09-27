# CLI 0.5.1 可读性验收

日期：2026-09-27。代码提交：`d9dfe4b988cebbf2641ae909c8a2a6a1318a1d8c`。
GPT-6-Sol（xhigh）负责实现；协调代理负责规划、代码审阅、独立黑盒验收、
打包及本机安装。范围为 CLI 呈现、参数、帮助和终端兼容性。

## 搜索输出

使用独立的 105 条合成记录，覆盖长 OCR、正文后段命中、中文、组合字符、
emoji、包含空格和引号的筛选值，以及带 ANSI/OSC/bidi 控制字符的标题。

| 同一查询的默认输出 | 0.5.0 | 0.5.1 |
| --- | ---: | ---: |
| 显示记录 | 100 | 10 |
| 输出行数 | 2,302 | 67 |
| 字符数 | 3,064,517 | 2,409 |

新版展示完整记录 ID、时间、应用、标题和最多两行命中附近的 OCR 摘要。
正文没有精确命中时，说明匹配可能来自标题、元数据或转录。
分页命令保留有效资料库绝对路径、查询、日期、应用、排序和页大小；
已在包含空格、中文、单引号的参数上实际执行并核对下一页记录。
末页和空结果有明确提示，不把本页数量当成总匹配数量。

同一合成库的 `--json` 与 0.5.0 保存的原始 100 条结果逐项深比较一致，
包括长正文和原始控制字符。导出默认仍为 100 条，详情保留完整正文。
索引默认范围由隔离 owner 测试确认仍为 100 条；没有因浏览分页而缩小。

## 验证结果

- 源码 CLI 回归：246 项断言通过，包含原生 Mac 桥接、隔离后台服务、
  任务恢复、JSON 协议以及各命令输出形状。
- 自包含 Mac 安装包：265 项断言通过，包含真实 OCR 图片、原生桥接和
  打包后二进制进程测试。
- 独立合成库黑盒：70 项检查通过，覆盖默认数量、分页、完整 ID、长正文、
  空结果、控制字符清理、帮助、语言、错误码和导出范围。
- 真实 POSIX PTY：28 项检查通过，覆盖 60/80/120 列、自动颜色、
  `NO_COLOR`、`TERM=dumb`、ASCII、标准错误单独接入终端，以及 JSON
  成功/失败输出。SIGINT 实测退出码为 130，且 OCR 子进程已回收。
- Windows、Linux、macOS 三平台 CI 全部通过；Linux 还完成隔离桌面中的
  真实采集、OCR、维护及导出，Mac/Linux 完成真实 PTY 回归。

本轮实测发现 .NET Console 的 POSIX 输出可能在首次写入时发送终端模式
控制序列，污染纯 JSON。CLI 现使用不改变终端模式的 UTF-8 输出流、只读
宽度查询和原生取消信号注册。真实 PTY 回归已接入 Mac/Linux CI，防止只用
StringWriter 测试而遗漏实际运行库行为。

本地证据保存在 `.test-data/cli-output-acceptance/`，包括
`packaged-tests.log`、`packaged-terminal.json`、`packaged-blackbox.json`、
`after-human-search.txt` 和 `installed-verification.json`。
完整流水线：[Shared library CLI #36302937387](https://github.com/Lyle-xub/Recall/actions/runs/36302937387)。

## Mac 安装与使用

已安装 `0.5.1-d9dfe4b`，命令仍为 `~/.local/bin/recall`。
214 个安装文件的 SHA-256 清单全部验证通过；保留
`~/.local/share/recall-cli/versions/0.5.0-6c57b11` 用于回退。
新的登录 shell 已确认解析到新版本，安装后的启动器已通过中文搜索与颜色
PTY 检查。

安装后只读检查确认原生 macOS 资料库、桌面 owner、正在进行的录制和现有
对话/语音模型连接正常。测试写入均使用隔离库；未更换桌面 app，已安装 app
二进制 SHA-256 与本轮开始时一致。安装凭据记录在
`~/.local/share/recall-cli/installation.json`。

```sh
recall help --lang zh
recall help search --lang zh
recall search "会议" --lang zh
recall records get MEMORY_ID --lang zh
recall search "会议" --json
recall doctor --lang zh --ascii --color never
```

## 验收边界

电脑操作工具明确禁止控制 macOS Terminal 窗口，未绕过该限制，因此没有
窗口截图或人工视觉验收结论。上述终端验证是在本机真实 PTY 上执行，
包括实际终端宽度查询、颜色字节、Unicode 完整性和取消行为。
ID 和可复制命令保持完整，在很窄的终端中允许自然换行。
偏移分页沿用原有语义，资料库持续新增记录时不承诺跨命令快照一致性。
