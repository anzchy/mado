# Mado 视觉来源与清理记录

最初于2026-10-20参考 [anzchy/mdpro](https://github.com/anzchy/mdpro/tree/cee9af46f390b82f3df656552fe7e46da8870ddd/design)，固定提交 `cee9af46f390b82f3df656552fe7e46da8870ddd`。借鉴其冷中性色、单一强调色、系统字体、圆角、细线和浮层层级。

## 当前状态：Mado 自有规范

2026-10-21 按用户要求完成清理。`DESIGN.md`、`DESIGN.stitch.md`、本目录 README 和 prototypes README 已替换为 Mado 内容；它们不再是上游原文。主规范为 [DESIGN.md](DESIGN.md)。

删除49个旧文件，约3.13MB：mdpro 的 mockup/preview、archive、reviews、reference、编号原型，以及仅供旧预览使用的22个编辑器 CSS 文件。删除前逐项核对原始导入哈希，未发现这些导入文件被修改。清单与 SHA256 见 [清理收据](../evidence/design-cleanup-receipt.json)。

保留：

- `picsee-ui-system/`：Mado 正在使用的 token 与三个组件。颜色值未改；说明及导出提示已改为 Mado C 语义。
- `prototypes/picsee-browser/`：Mado 原型及自身版本快照，不属于 mdpro 旧 mock。
- `competence-report/`：FastStone Image Viewer 调研、截图与报告包，与当前看图产品有关。
- `prototypes/picsee-browser/states/` 正式状态稿、`docs/design/` 设计交接及独立操作证据。

原始 [导入收据](../evidence/design-import-receipt.json) 和 [来源清单](../evidence/import-source-manifest.json) 是历史证据，不代表导入路径仍然存在。上游提交可用于追溯来源，不能作为当前 Mado 的产品规则、ADR 或可访问性豁免。
