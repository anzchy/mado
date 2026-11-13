---
status: proposed
date: 2026-10-23
---

# ADR-008：只读文件夹访问与 app-scope bookmarks

P0-04（#8，ACCESS-02）沿用 [ADR-006](0006-sandbox-from-p0-direct-distribution.md) 的用户决定（2026-10-22）：P5-04 前仅用 `com.apple.security.files.user-selected.read-only`。增加 `com.apple.security.files.bookmarks.app-scope = true`，将系统打开面板选择的文件夹保存为 Access Root。bookmark 使用 `.withSecurityScope`，不加 `.securityScopeAllowOnlyReadAccess`；以后写操作仍必须经过 P5-04 的 entitlement 和真机验证。

app-scope bookmark 由本应用重启后恢复用户授予的范围。File Grant 只覆盖单个文件，绝不写 bookmark；Recent Item 只是引用，不授予访问。授权不创建 Library Folder。

2026-10-26 修订：上述 File Grant “绝不写 bookmark”仅适用于持久化存储；#140 按用户新决定在会话内存中暂存单文件 security-scoped bookmark 以跟随外部重命名，绝不枚举父目录或写入 Access Root 存储。见 [ADR-0011](0011-session-file-grant-bookmark-recovery.md)。

2026-11-13 修订：为标注副本直接写回授权文件夹，entitlement 按 P5-04 改为 `files.user-selected.read-write`，见 [ADR-020](0020-annotation-saves-a-flattened-copy-into-writable-access-roots.md)。

## Considered Options

- Full Disk Access：扩大访问范围且依赖系统设置，拒绝。
- temporary exceptions：绕过用户授权边界，拒绝。
- 特定文件夹 entitlements：无法表达用户任意选择的 Access Root，拒绝。
- 将拖入或 open event 中的文件夹直接当成根：缺少指定的系统打开面板授权动作，拒绝。
- 仅保留会话授权：每次启动都要重选，不能满足 ACCESS-02，拒绝。

## Consequences

- 根记录以 JSON 原子写入沙盒容器的 Application Support/Picsee/access-roots.json，与缓存分离。每条包含 AccessRootID、bookmark、显示名、创建 build SHA 和日期。Recent 单独保存为 recent-folders.json，至多十个文件夹，无 bookmark。
- FileAccess 是应用级 actor。Access Root 的第一份租约成功 start 后才返回，最后释放配平 stop。File Grant 若 start 返回 false，但系统已允许读取该文件（真机观察为 start=false/readable=true；Finder 拖入提供进程级 sandbox extension 是据此作出的推断，未直接验证该机制），仍可建立仅覆盖该文件的会话租约；通过现有 SecurityScope 边界查询可读性，后续读取仍由 sandbox 强制执行。只有实际成功 start 的 scope 在最后释放时 stop，失败 start 不调用 stop（#73）。每次访问先取得租约，再请求共享 pipeline；取消不能早于同步解码真实返回释放。
- stale 且可解析时，在实际取得 scope 后重新创建并保存 bookmark。无法解析或 start 失败时返回类型化错误，根进入需要重连状态。损坏或不兼容的根库降级为空根列表并置 `storeCorrupt`，公共日志仅写字面量 `AccessStore kind=storeCorrupt`。保留原 `access-roots.json`，新授权原子写入同目录的 `access-roots.json.recovered`；后续启动从该恢复库读取，仍保留损坏标记。恢复库也损坏时降级为空，不影响 File Grant；下一次成功授权可重写恢复库。完整修复管理 UI 属于 P2-01。
- Recent 库同样采用空列表降级和 `storeCorrupt` 标记，仅记录字面量 `RecentStore kind=storeCorrupt`，不记录内容或路径。保留损坏的 `recent-folders.json`；后续成功添加写入 `recent-folders.json.recovered`，重启从该恢复库加载。恢复库也损坏时仍可打开文件和文件夹，下一次成功添加重写恢复库。Recent 不携带授权。
- 边界标准化并解析符号链接，按路径分量比较；不自动读取根外链接目标，根内链接允许。该检查不能消除外部进程在检查与读取之间替换链接的竞态，sandbox 仍是最终权限边界。
- `access` 类别的 `AccessLease` signpost 覆盖租约会话建立至最后释放（成功 start 时包含对应的 stop）；最后释放公共日志带 root ID、`remaining=0` 和 `outcome=`，路径保持 private。
- 开放问题：该平台上的 app-scope entitlement 是否必需尚待真机证据；本次按规范增加，不能自行删除。

## Bookmark after rebuild

**已验证（2026-10-23，Mac mini，见 `docs/validation/P0.md` P0-04/P0-09 第 13 项）**：构建 A（`da64b08`）授权的目录 bookmark 在较晚 SHA 的签名构建 B（`c09c7f0`，CDHash 不同，同团队 GRT84NAK4T）中 `outcome=resolved`，经 File → Open Recent 直接浏览，不再询问授权；实现者冒烟构建 `a1a15ac` 创建的 bookmark 同样解析。未验：不同签名团队、Release/公证构建、系统升级后的解析。

注：Picsee 是 Mado 的旧名（#547、ADR-0017）。
