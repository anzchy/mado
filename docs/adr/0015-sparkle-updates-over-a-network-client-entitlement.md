---
status: accepted
date: 2026-10-28
---

# ADR-015：v0.0.1 用 Sparkle 2 自动更新，App 只为此申请网络客户端权限

关联：DIST-01、DIST-04、DIST-05；计划 P6-06、P6-08、§5 v0.0.1 门槛（对外分发）；[ADR-013](0013-build-by-user-journey-slices.md)。

## 决定

- **更新方式：** picsee v0.0.1 起用 Sparkle 2 自动更新。
  - Settings 新增「更新」Tab：显示当前版本与构建号、「自动检查更新」开关、「立即检查」按钮。
  - Sparkle 下载更新包后，用 EdDSA 签名和 Developer ID 签名校验，再安装。
  - appcast 放在 GitHub 上，由发布流程生成，经 PR 合入。
- **沙盒权限：** 沙盒保持开启。只新增 `com.apple.security.network.client`，用途仅限 Sparkle 访问 GitHub 上的 appcast 和更新包。
  - picsee 的其他代码不发起网络请求，不上传图片或元数据。
  - 沙盒下按 Sparkle 文档使用其安装器 XPC 服务。
- **首次询问与系统信息：** 第二次启动时询问是否自动检查（Sparkle 默认），不发送系统概况（`SUEnableSystemProfiling` = NO）。
- **私钥：** Sparkle EdDSA 私钥只存在 GitHub Secrets（发布 workflow 使用），不进仓库。公钥写入 Info.plist。

## 用户决定（原话，2026-10-28 grilling A）

- 「在Settings 中添加更新Tab，Settings 界面接下来我们要一起探讨，作为user journey新增页面」
- 「Sparkle 自动更新」
- 「第二次启动时询问，不发系统信息」
- 「GitHub Actions 自动发布」「推 tag → 生成草稿 Release，你点发布」

## 考虑过的方案

| 方案 | 取舍 |
|---|---|
| 不做更新，用户手动下载 DMG 覆盖 | 不申请网络权限；但对外用户很难收到修复 |
| 只检查不安装（读 GitHub Releases API，给下载链接） | 同样需要网络权限，安装仍靠手动 |
| **Sparkle 2（选定）** | 成熟的签名校验与沙盒安装器；代价是一个外部依赖（MIT）、一项网络权限、一份 appcast 与私钥管理 |

## 后果

- **门槛：** DIST-04（升级保留数据）与 DIST-05（自动更新）进入 v0.0.1 门槛。v0.0.1 起，设置、授权与收藏的存储格式带版本号，供以后迁移。
- **新增工作：**
  - 依赖与许可：Sparkle 作为 SwiftPM 依赖，版本固定；第三方许可清单列出 Sparkle（MIT）。
  - 发布流程：发布 workflow 生成 appcast PR。
  - 界面：Settings「更新」Tab，其所在的 Settings 窗口作为新的旅程页面另行设计。
- **AGENTS.md「sandbox 不关」不受影响：** 沙盒保持开启，只增加一项客户端网络权限，并由本 ADR 记录。
- **隐私说明：** README 与发布说明写明 picsee 不收集数据，只在检查更新时访问 GitHub。

## 2026-10-30 补充：沙盒安装器需要的 mach-lookup 临时例外

#220 实现前核对 Sparkle 沙盒文档（sparkle-project.github.io `documentation/sandboxing`）：沙盒 App 必须启用 Installer XPC Service（`SUEnableInstallerLauncherService` = YES），并为与安装工具通信加一项临时例外：

```xml
<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
<array>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
</array>
```

不加此项的唯一替代是从源码构建 Sparkle 并启用 Installer Connection & Status XPC 服务。

- **用户决定（2026-10-30，选项原文）：** 「Add the exception (Recommended)」；版本「2.10.0 (Recommended)」。
- **结果：** App 的权限为沙盒、用户选择文件只读、app-scope 书签、`network.client`，以及上面这一项只含两个 Sparkle 服务名的 mach-lookup 例外。沙盒保持开启；不加其他例外。Downloader XPC Service 不启用（已有 `network.client`）。
- Sparkle 固定为 2.10.0。

注：Picsee 是 Mado 的旧名（#547、ADR-0017）。
