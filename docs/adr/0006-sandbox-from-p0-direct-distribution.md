---
status: proposed
date: 2026-10-22
---

# ADR-006：从 P0 起启用 App Sandbox，首发先 Developer ID 直接分发

picsee 从第一个可运行构建起就开启 App Sandbox；首发按启用 sandbox 的 Developer ID 应用设计，签名、公证后直接下载（架构 §1.2「分发」）。用户能访问的范围只来自用户动作：Access Root 只由系统打开面板授权并以 bookmark 跨重启保留；从 Finder 打开或拖入得到的是 File Grant，只在本次会话有效，不能被当作父目录授权（GLOSSARY.md；架构 §3.3）。核心流程不依赖 Full Disk Access。

这样选，是因为目录授权体验是最大的产品风险之一（开发计划 §11 风险表「bookmark 与目录授权体验不成立」），越晚开启 sandbox，越可能在已写好的功能里发现不可行；而先做直接分发，可以不被商店审核节奏卡住，又因为一开始就在 sandbox 里，保留以后上 Mac App Store 的可能。P0-01 已用 Apple Development 证书手动签出带 sandbox 的 App，使 P0-04 的 bookmark 结论接近发布签名（开发计划 P0-01）。

## Considered Options

- **先不开 sandbox，发布前再开**：早期开发更省事，但授权、bookmark、租约释放的问题会推迟到最贵的时候暴露。未选。
- **首发即上 Mac App Store**：分发与更新省心，但审核与商店约束提前进入关键路径。未选；作为未来渠道保留（架构 §10「尚待产品决定」）。

## Consequences

- P0-04 验证单文件打开、授权父目录、bookmark 跨重启恢复、关闭后释放范围；P2-01 完成 `AccessLease` 引用计数、stale bookmark 修复与 Access Root 存储（账簿 ACCESS-01..05）。
- 冲突处理固定：sandbox 与必要功能冲突时，记录复现步骤和替代方案、写 ADR、问用户，不关 sandbox，不加 Full Disk Access 依赖（开发计划 P0 决策点；AGENTS.md）。
- P6-06 申请 Developer ID Application 证书并完成签名、公证、staple、Gatekeeper 验证；证书不进 CI（开发计划 P0-01、P6-06）。
- 首发经 **GitHub Releases** 分发 Developer ID 签名并公证的包，并在首发就提供 **Sparkle 自动更新**（用户决定（2026-10-22））。这把原 P7-09 的自动更新提前到 P6-08。按 Sparkle 的 sandbox 指南，P6-08 至少要做到：
  - 打开安装器启动服务：Info.plist 设 `SUEnableInstallerLauncherService = YES`，并加 mach-lookup 临时例外 `$(PRODUCT_BUNDLE_IDENTIFIER)-spks`、`$(PRODUCT_BUNDLE_IDENTIFIER)-spki`；
  - 选定下载方式：加 `com.apple.security.network.client`，或用 Sparkle 的 Downloader XPC（`SUEnableDownloaderService = YES`）；二选一写进 P6-08 的实现记录；
  - 更新包用 EdDSA 签名，appcast 携带每个包的签名，App 内置 `SUPublicEDKey`；appcast 本身的签名是可选项（Sparkle 2.9 起的 `SURequireSignedFeed`），不是 sandbox 的前提；
  - Sparkle 的 XPC 服务与辅助程序随 App 用 Hardened Runtime 重签并一起公证，不用 `--deep`。
- 写权限在 P5-04 加入 `com.apple.security.files.user-selected.read-write`，此前保持只读（用户决定（2026-10-22））；加入时同步更新相关账簿行。所有写用户文件的功能都排在这个写权限切片之后：P5-02 的设置/清除 Finder 标签、P5-04 的导出、P5-06 的移到废纸篓。
- 只读期间创建的 bookmark（P2-01、P3-14/15）不加 `.securityScopeAllowOnlyReadAccess`。P5-04 必须实测：写权限加入后，此前授权的 Access Root 能否写入；不能写时，第一次写操作经系统打开面板重新授权该目录，并替换旧 bookmark，不静默失败。
- 重评条件：某个特定功能被证明与 sandbox 冲突且有复现记录时；或产品决定上 Mac App Store 时（商店构建不能包含 Sparkle，需要单独的构建配置去掉它）。

注：Picsee 是 Mado 的旧名（#547、ADR-0017）。
