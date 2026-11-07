# Mado 设计稿与 Stitch 交接

更新：2026-10-21。**正式素材已迁到design/；`.stitch/`整体为本地工作目录，不提交。**

## 当前入口

- 主规范：[design/DESIGN.md](../../design/DESIGN.md)。
- 原生组件与映射：[native/README.md](../../design/picsee-ui-system/native/README.md)。
- 交互原型：[viewer-v2.html](../../design/prototypes/picsee-browser/viewer-v2.html)。
- 20份正式静态状态稿：[states/index.html](../../design/prototypes/picsee-browser/states/index.html)。
- 当前页面目录：`design/prototypes/picsee-browser/states/manifest.json`。
- [本地预览](http://127.0.0.1:4313/index.html)；启动方式见 [states/README](../../design/prototypes/picsee-browser/states/README.md)。

## 来源与同步边界

[私有Stitch项目](https://stitch.google.com/projects/2194104928396163363)保存过16份基线/状态HTML和原始图片参考。31–34为本地C补充，未因本次整理而上传。云端另有未采纳探索稿；是否进入正式目录由主规范与用户决定。

本次打包提取了重复内嵌图片，HTML的资源路径和哈希发生变化，视觉不变。`provenance/stitch.json`保留原screen IDs和打包前后哈希，不宣称重新打包后的文件已同步云端。旧13错误稿不采用，修正版来源ID保留。

## 正式状态稿索引

| 标题 | 文件 | 来源screen ID |
| --- | --- | --- |
| 11 网格 · 浅色 | [grid-light.html](../../design/prototypes/picsee-browser/states/grid-light.html) | `14601836994229817048` |
| 12 网格 · 深色 | [grid-dark.html](../../design/prototypes/picsee-browser/states/grid-dark.html) | `3064312406943265187` |
| 13 大图 · 沉浸隐藏 | [viewer-quiet.html](../../design/prototypes/picsee-browser/states/viewer-quiet.html) | `12350118541987102203` |
| 14 大图 · 工具显示 | [viewer-controls.html](../../design/prototypes/picsee-browser/states/viewer-controls.html) | `13589006507119364287` |
| 15 网格 · 显示与外观 | [grid-display.html](../../design/prototypes/picsee-browser/states/grid-display.html) | `11064550040603606807` |
| 16 大图 · 图片信息 | [viewer-inspector.html](../../design/prototypes/picsee-browser/states/viewer-inspector.html) | `12755442922507933941` |
| 21 首次打开 | [first-launch.html](../../design/prototypes/picsee-browser/states/first-launch.html) | `164908240892538176` |
| 22 空文件夹 | [empty-folder.html](../../design/prototypes/picsee-browser/states/empty-folder.html) | `164908240892536508` |
| 23 搜索无结果 | [search-empty.html](../../design/prototypes/picsee-browser/states/search-empty.html) | `12486128623328386720` |
| 24 读取文件夹 | [folder-loading.html](../../design/prototypes/picsee-browser/states/folder-loading.html) | `56944056459542733` |
| 25 图片无法读取 | [image-error.html](../../design/prototypes/picsee-browser/states/image-error.html) | `11744224511424315712` |
| 26 目录权限失效 | [permission-denied.html](../../design/prototypes/picsee-browser/states/permission-denied.html) | `5467803942563442168` |
| 27 原始尺寸与平移 | [original-size.html](../../design/prototypes/picsee-browser/states/original-size.html) | `61167294243124794` |
| 28 键盘焦点 | [keyboard-focus.html](../../design/prototypes/picsee-browser/states/keyboard-focus.html) | `6740836353484827439` |
| 29 紧凑窗口 | [compact-grid.html](../../design/prototypes/picsee-browser/states/compact-grid.html) | `14975705375083274647` |
| 30 组件与状态 | [components.html](../../design/prototypes/picsee-browser/states/components.html) | `9478740685932826683` |
| 31 图片右键菜单 · C | [grid-context-menu.html](../../design/prototypes/picsee-browser/states/grid-context-menu.html) | 本地补充 |
| 32 基础多选 · C | [grid-multiselect.html](../../design/prototypes/picsee-browser/states/grid-multiselect.html) | 本地补充 |
| 33 胶片条展开 · C | [viewer-filmstrip.html](../../design/prototypes/picsee-browser/states/viewer-filmstrip.html) | 本地补充 |
| 34 图片信息 · 浅色 · C | [viewer-inspector-light.html](../../design/prototypes/picsee-browser/states/viewer-inspector-light.html) | 本地补充 |

## 后续使用

命令仍通过 `npm run stitch -- ...` 执行，项目登录/绑定信息位于本地忽略目录。新克隆可以阅读和预览design/，不必先登录Stitch。云端操作需使用对应项目并保留实际收据，不能由本地文件的存在推断云端同步完成。

组件/布局参考不等于原生实现：多选、右键系统动作、授权、真实像素缩放、VoiceOver和性能均按实施计划验证。正式App不打包这些HTML、React、REA或Stitch工具。

## 证据

- `evidence/design-material-reorganization.json`：素材迁移及图片提取收据。
- `states/provenance/stitch.json`：原始来源与文件哈希。
- 既有 `evidence/stitch-*.json` 是历史收据，其旧工作目录路径不作为当前素材入口。
- 旧工作文件保留在本地 `.stitch/revisions/`；不纳入仓库基线。

## 重新上传某一页时

仓库版HTML引用共享图片。需要上传到Stitch时，先通过CLI制作本地自包含副本，再按当时授权上传；不要重新把大量base64塞回仓库源码。

```sh
npm run stitch -- capture file design/prototypes/picsee-browser/states/grid-light.html -o .stitch/captures/grid-light.html --json
# 验证副本后，再使用 upload screen 指向该本地临时文件。
```
