<p align="center">
  <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/app-icon-128@2x.png" width="128" height="128" alt="Mado 图标">
</p>

<h1 align="center">Mado</h1>

<p align="center">A quiet, native image viewer for macOS.</p>

<p align="center">
  <a href="https://github.com/anzchy/mado/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/anzchy/mado?label=release"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/github/license/anzchy/mado"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-lightgrey">
</p>

Mado 是一个原生 macOS 看图应用，给想在本地安静地看照片和文件夹的人用。界面让位给图片：不动鼠标时工具会隐去，需要时再出现。它用 Swift、SwiftUI 和 AppKit 编写，沙盒开启，只读取你选的文件夹和文件。

## 下载与安装

1. 从 [最新发布页](https://github.com/anzchy/mado/releases/latest) 下载 `Mado-<版本>.dmg`。第一个版本是 [Mado 0.0.1](https://github.com/anzchy/mado/releases/tag/mado-v0.0.1)。
2. 打开 DMG，把 Mado 拖进“应用程序”文件夹。

- 需要 macOS 14 或更高版本。
- DMG 和 App 都用 Developer ID 签名，并经过 Apple 公证。发布页列出了 DMG 的 SHA-256，可以用 `shasum -a 256 Mado-<版本>.dmg` 核对。
- 以后的版本通过 App 内置的 Sparkle 更新（见下文「隐私」）。

> [!NOTE]
> Mado 是 Picsee 改名后的新身份，作为一个新 App 安装。Picsee 的设置、最近打开的文件夹和文件夹授权不会带到 Mado，第一次打开时需要重新选择文件夹（[ADR-0017](docs/adr/0017-rename-to-mado-with-a-new-identity.md)）。

## 功能

Mado 现在实际有什么，以 [功能账簿](docs/feature-ledger.md) 为准。账簿里每项能力都写明了状态、在 App 里怎么确认，以及还有哪些限制。下面只列账簿中已经实现的能力。它们目前都标为 `Partial`：能用，但各有写明的限制，多数是部分入口还没在真机上验证。

**打开**

- 首次打开的首页：选择文件夹，或把图片、文件夹拖进窗口。
- ⌘O 打开单张图片或文件夹；在访达里用“打开方式 → Mado”打开图片。
- 最近打开的文件夹（最多 10 个），退出重开后仍在。
- 图片读不出来时显示错误页，可以重试或看下一张，不会显示上一张图。

**看图**

- 适应窗口、实际像素 1:1、以光标为锚点缩放、放大后拖动平移。
- ⌃⌘F 全屏。
- 按 EXIF 方向正向显示；透明 PNG 不显示成黑色。
- 大图先出预览再变清晰，加载时界面不卡；快速切图时只显示最后选的那张。
- ←/→ 按文件夹顺序翻图，到首尾时按设置停止或循环。
- 不动鼠标时工具自动隐藏，鼠标移到底边或按 Tab 唤回；也可以设为始终显示。Esc 返回进入大图前的网格。

**浏览文件夹**

- 扫描文件夹后进入缩略图网格；扫描时可以取消。
- 按名称（自然排序）、修改日期、类型、大小、拍摄日期、像素尺寸排序；按扩展名过滤；可选包含子文件夹。
- 在访达里新增、删除、重命名图片后，列表会跟着更新。
- 网格与大图来回切换，回来时保留选择和滚动位置；⌘点击、Shift 点击多选，多选后看大图只在所选范围内翻页。
- 目录侧栏和子文件夹列表；按文件名搜索当前文件夹（⌘F）。
- 空文件夹、文件夹找不到、外接盘被推出、授权失效时，都显示对应的页面和下一步操作。

**信息与设置**

- ⌘I 打开信息面板：缩略图、文件名、尺寸、类型、日期、大小；读不到的值显示“未知”。
- 外观可选跟随系统、浅色或深色；跟随系统的“减少动态效果”设置。
- 网格的缩略图大小、是否显示文件名、填充裁剪或完整显示。
- 缩略图磁盘缓存，可以在设置里查看占用并清理。
- 帮助菜单里有键盘快捷键、诊断信息（只显示本地的数量和大小）和“报告问题…”。
- 中文和英文界面。

**格式**：JPEG、PNG、HEIC、TIFF。

**还没有**：旋转、裁剪、导出等编辑功能，GIF 动画、PDF、RAW 等格式，多窗口和幻灯片。App 里标着「即将推出」的入口（例如侧栏的个人收藏和最近查看）也还不能用。

## 隐私

- Mado 不收集任何数据，不上传图片或元数据。
- 沙盒保持开启。Mado 只读取你通过系统面板选的文件夹和文件，不修改它们。
- 唯一的联网是检查更新：内置的 Sparkle 访问 GitHub 上的更新信息和更新包，不发送系统信息。
- 第二次启动时，Mado 会问你是否自动检查更新；之后可以在“设置 → 更新”里修改。
- 为了检查更新，App 只多申请了一项网络客户端权限，见 [ADR-0015](docs/adr/0015-sparkle-updates-over-a-network-client-entitlement.md)。

## 问题反馈

请在 [GitHub Issues](https://github.com/anzchy/mado/issues/new?template=bug_report.yml) 用问题报告模板提交，也可以从 App 的“帮助 → 报告问题…”打开。请写上 Mado 的版本和构建号（在“设置 → 关于”里）。不要附上私人照片，也不要粘贴个人文件路径，用描述代替，例如“外接磁盘上一个有 5000 张 HEIC 的文件夹”。

## 从源码构建

需要 Xcode 26.6 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。Xcode 工程由 `project.yml` 生成，不入库。

```sh
xcodegen generate
swift test --package-path Packages/MadoKit
xcodebuild build -scheme Mado -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd-ci
```

签名构建使用 `project.yml` 里配置的开发团队；没有该团队的证书时，用上面不签名的命令构建。

代码分层：`App/` 是 App target；`Packages/MadoKit/Sources/` 下有 `MadoCore`、`MadoApplication`、`MadoInfrastructure`、`MadoMacUI` 四个模块；测试在 `Packages/MadoKit/Tests/`、`AppTests/` 和 `UITests/`。

## 参与开发

先读 [AGENTS.md](AGENTS.md)。它是仓库的地图，说明规则、命令和该读哪份文件。

| 你要做的事 | 先读 |
|---|---|
| 了解计划与架构 | [开发计划](docs/PICSEE_DEVELOPMENT_PLAN.md)、[架构](docs/PICSEE_ARCHITECTURE.md)、[架构决定（ADR）](docs/adr/) |
| 确认某项功能的状态与验收 | [功能账簿](docs/feature-ledger.md)、[功能验收指南](docs/guide/feature-verification-guide.md) |
| UI、颜色、间距、组件 | [C 设计主规范](design/DESIGN.md)、[设计系统与原生映射](design/picsee-ui-system/native/README.md)、[20 份状态稿](design/prototypes/picsee-browser/states/README.md)、[交互原型](design/prototypes/picsee-browser/README.md)、[设计交接与 Stitch 来源](docs/design/STITCH_HANDOFF.md) |
| 发布新版本 | [发布手册](docs/release/README.md) |
| 项目 skills 与研究工具 | [PROJECT_SKILLS.md](PROJECT_SKILLS.md) |

浏览器原型和状态稿是设计输入，不代表 App 已有的功能。App 不打包原型、研究资料或设计工具。

### 本地设计预览

只需要 Python 3 和仓库里的素材：

```sh
npm run preview:prototype
# http://127.0.0.1:4311/prototypes/picsee-browser/viewer-v2.html
# http://127.0.0.1:4311/prototypes/picsee-browser/states/index.html

npm run preview:states
# http://127.0.0.1:4313/index.html
```

### 发布签名（维护者）

第一次配置或更换证书时，在仓库根目录运行 `.agents/skills/apple-developer-setup/scripts/setup-secrets-wizard.sh`（说明见 [skill `apple-developer-setup`](.agents/skills/apple-developer-setup/SKILL.md)）。它会一步步引导你创建 Developer ID 证书和用于公证的 Apple ID App 专用密码，生成 Sparkle 更新签名密钥，并写入 GitHub Secrets；密钥不进仓库。之后怎么发布，见 [发布手册](docs/release/README.md)。

## 许可

Mado 以 [MIT License](LICENSE) 发布。第三方组件（Sparkle）与首页样图的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
