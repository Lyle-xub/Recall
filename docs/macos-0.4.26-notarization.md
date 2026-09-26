# Recall 0.4.26 (34) 公证记录

日期：2026-09-26。macOS Apple Silicon 发行版，应用标识 `studio.rewind.replica`。构建来源为 `a55fb9a0ddae7a585fcb21a1c63889743968fa2f`。

## 主分支与签名

- `main` 采用 Rhine Lab Mode（莱茵生命模式）版本，包括全屏唤醒、Dock、交互性能及存储设置修复。
- 经典版本保留在 `legacy/main-before-rhine`（`5391af1`）；本次发布前的主分支快照保留在 `backup/main-before-release-20260926`（`ea5385f`）。仓库未配置远程，以上分支变更均为本地变更。
- 签名身份为 `Developer ID Application: bo xu (GXVN75MDQN)`。主程序及 45 个原生组件均通过相同团队、时间戳、Hardened Runtime 签名检查。
- 新包与已安装应用、当前运行的应用具有相同的 designated requirement。

## 应用和 ZIP

- Apple 提交编号：`9e5bde6b-5e1a-4b90-90ae-6c3f93b91539`。
- Apple 结果：**Accepted**，`Ready for distribution`，无 issues。
- `release/Recall.app` 已附加票据，`stapler validate`、严格签名校验与 Gatekeeper 检查通过，结果为 `Notarized Developer ID`。
- `release/Recall-macOS-0.4.26.zip` 从附加票据后的应用生成。解压后再次验证版本、签名、公证票据和 Gatekeeper，全部通过；ZIP 完整性检查通过。

## DMG

- `release/Recall-macOS-0.4.26.dmg` 从附加票据后的应用生成，保留安装背景和 Applications 链接，并使用同一 Developer ID 签名。
- Apple 提交编号：`23484735-7b91-4ad1-a190-e5a1e0d362a5`。
- Apple 结果：**Accepted**，`Ready for distribution`，无 issues。
- DMG 已附加票据；签名、票据、Gatekeeper 与磁盘映像完整性检查通过。
- 只读挂载后，包内应用的版本、签名、票据和 Gatekeeper 检查全部通过，检查后已卸载映像。

## 分发与审计

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `Recall-macOS-0.4.26.dmg` | 91,998,192 | `c4ba46ef5600b7d47190e9fb93ef42a46bfafe10d20ea7ab2f19ba59143a64b1` |
| `Recall-macOS-0.4.26.zip` | 91,304,287 | `fad7247f5ea9fe02a0e390d72e772f953be8c41c6b82201cf69387cb134f7e97` |

`release/Recall-macOS.dmg` 和 `release/Recall-macOS.zip` 与对应版本文件完全一致。旧 0.4.25 (33) 分发包和校验和保存在 `release/previous/0.4.25-33/`，备份哈希已验证。

`release/notarization/0.4.26-34/` 保存构建日志、原生组件签名预检、上传哈希、提交回执、Apple 审核日志、附票据日志和最终验证记录。`release/checksums.json` 已更新 macOS 包的校验和，保留原有 Windows 包记录。

上传 ZIP 在附加应用票据前生成，发布 ZIP 在附加票据后生成；DMG 上传后也附加了票据，因此最终分发哈希与上传哈希不同。公证完成后没有重新签名或修改应用代码。本次只生成分发包，没有替换已安装或正在运行的应用。
