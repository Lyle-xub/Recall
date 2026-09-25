# Recall 0.4.25 (33) 公证记录

日期：2026-09-25。macOS Apple Silicon 发行版，应用标识 `studio.rewind.replica`，Developer ID 团队 `GXVN75MDQN`。

## 应用

- 提交编号：`6de04c91-7ad6-4878-8c91-71643bd03ea8`。
- Apple 结果：**Accepted**，`Ready for distribution`，无 issues。
- 主程序及 45 个原生组件均通过相同团队、时间戳、Hardened Runtime 签名检查。
- `release/Recall.app` 和已安装的 `/Applications/Recall.app` 均已附加票据，`stapler validate` 通过。
- ZIP 从附加票据后的应用重新生成；解压后票据验证及 Gatekeeper 检查通过，结果为 `Notarized Developer ID`。

## 安装包

- DMG 从附加票据后的应用重新生成，保留安装背景和 Applications 链接，并使用同一 Developer ID 签名。
- 提交编号：`237a73ac-d698-4a0d-8ee2-8bdd35fab017`。
- Apple 结果：**Accepted**，`Ready for distribution`，无 issues。
- DMG 和其中的应用均已附加票据，票据校验、签名校验、Gatekeeper 检查通过；DMG 文件完整性校验通过。

## 审计文件

`release/notarization/` 保存提交回执、Apple 审核日志、上传前文件哈希和最终验证记录。`app-upload.json` 记录实际提交的原始 ZIP；发布 ZIP 在应用附加票据后重新生成，因此其最终哈希与上传时不同，应用代码签名不变。

最终分发校验和保存在 `release/checksums.json`。公证完成后不得重新签名或修改应用代码；后续新构建需要再次公证。
