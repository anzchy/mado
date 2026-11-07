# Mado · Quiet Image Canvas

原生 macOS 本地极简看图软件的设计与技术准备仓库，目标架构为 **Swift + SwiftUI + AppKit**。当前包含设计规范、交互原型、20份状态稿和研究资料；原生App实现尚未开始。

## 先看这些

- [C设计主规范](design/DESIGN.md)
- [共享设计系统与原生映射](design/picsee-ui-system/native/README.md)
- [实施计划](docs/PICSEE_DEVELOPMENT_PLAN.md) / [架构设计](docs/PICSEE_ARCHITECTURE.md)
- [20份正式状态稿](design/prototypes/picsee-browser/states/README.md)
- [交互原型说明](design/prototypes/picsee-browser/README.md)
- [设计交接与Stitch来源](docs/design/STITCH_HANDOFF.md)

## 隐私

Mado 不收集任何数据，不上传图片或元数据。沙盒保持开启，它只读取你通过系统面板授权的文件夹和文件。目前的 App 不联网。计划中（v0.0.1，#220，尚未实现）唯一的联网是检查更新：Sparkle 访问 GitHub 获取更新信息和更新包，不发送系统信息；第二次启动时询问是否自动检查，之后可在“设置 → 更新”中修改（[ADR-015](docs/adr/0015-sparkle-updates-over-a-network-client-entitlement.md)）。

## 发布签名（维护者）

第一次配置或更换证书时，在仓库根目录运行 `.agents/skills/apple-developer-setup/scripts/setup-secrets-wizard.sh`（说明见 skill `apple-developer-setup`）。它会一步步引导你创建 Developer ID 证书和用于公证的 Apple ID App 专用密码，生成 Sparkle 更新签名密钥，并写入 GitHub Secrets；密钥不进仓库（#217）。

## 问题反馈

请在 [GitHub Issues](https://github.com/anzchy/picsee/issues/new/choose) 用问题报告模板提交。不要附上私人照片或个人文件路径。

## 许可

Mado 以 [MIT License](LICENSE) 发布。第三方组件与首次打开页样图的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 本地预览

```sh
npm run preview:prototype
# http://127.0.0.1:4311/prototypes/picsee-browser/viewer-v2.html
# http://127.0.0.1:4311/prototypes/picsee-browser/states/index.html

# 或单独运行20页索引
npm run preview:states
# http://127.0.0.1:4313/index.html
```

这些命令只需Python 3和本地素材，不需要先安装npm依赖或登录Stitch；也可使用状态稿README中的直接Python命令。

```text
design/
  DESIGN.md                      # 主设计规则
  picsee-ui-system/               # token、Web primitives、native规格
  prototypes/picsee-browser/      # 当前交互原型
    states/                      # 正式20页、共享图片、单一manifest、索引
  competence-report/             # FastStone研究与截图资料
docs/
  PICSEE_*                       # 架构与实施计划
  PICVIEW_*                      # 竞品技术/功能研究（仅本地）
  design/                        # 设计决策与交接
scripts/                         # token导出、预览/研究工具
evidence/                        # 验证及研究收据（仅本地）
```

正式设计素材提交 `design/` 与相关 `docs/`。整个 `.stitch/`、`.stitch-cli/`、本地绑定文件和浏览器会话忽略；不将工具缓存作为预览的隐式依赖。原生App不打包React、HTML、REA或Stitch CLI。

## 研究与开发工具

Picview技术分析 `docs/PICVIEW_ANALYSIS.md`、功能清单 `docs/PICVIEW_FEATURES.md` 和REA证据用于研究（本地研究资料，不在公开仓库），不是产品源码。REA 6.7.0 与 Stitch CLI 为固定版本项目开发依赖；见 [项目skills说明](PROJECT_SKILLS.md)。

```sh
npm ci --ignore-scripts
npm run rea -- --help
npm run analyze
npm run stitch -- --help
python3 scripts/export_native_design_tokens.py
```

分析默认针对 `/Applications/Picview.app`，不执行或修改目标。工具MCP配置可能包含本机路径，分享前按实际环境调整；云端操作状态以实际收据为准。原始字符串/大反编译输出和登录凭据不提交。
