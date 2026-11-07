# Mado design/

当前设计采用 **C · Quiet Image Canvas**。从 [DESIGN.md](DESIGN.md) 开始；它是主设计规范，不再引用 mdpro 的产品规则或旧 mock。

| 内容 | 入口 | 用途 |
| --- | --- | --- |
| 主设计规范 | [DESIGN.md](DESIGN.md) | C 布局、组件、主题、键盘、可访问性和验收边界 |
| 可复用样式与组件 | [picsee-ui-system/](picsee-ui-system/README.md) | Token 源文件、React primitives 与编译产物 |
| 原生实施规范 | [组件与原生映射](picsee-ui-system/native/README.md) | Token清单、组件契约及SwiftUI/AppKit交接 |
| 交互原型 | [picsee-browser](prototypes/picsee-browser/README.md) | 当前 `viewer-v2.html`；初版/revisions 仅用于 Mado 演进追溯 |
| 20页状态稿 | [设计交接](../docs/design/STITCH_HANDOFF.md) | 本地索引、云端状态与静态/行为边界 |
| FastStone 调研 | [competence-report/](competence-report/README.md) | 本地看图产品研究与截图证据，保留 |
| 视觉来源 | [IMPORT.md](IMPORT.md) | 原始导入来源与清理说明 |

运行中的入口：[交互原型](http://127.0.0.1:4311/prototypes/picsee-browser/viewer-v2.html)、[状态稿索引](http://127.0.0.1:4313/index.html)。网页需经本地 HTTP 服务打开。

mdpro 的旧 mockup、preview、archive、reviews、reference、编辑器 CSS 及编号原型已清理。历史导入哈希保留在 `evidence/`，不再作为当前目录结构或产品要求。
