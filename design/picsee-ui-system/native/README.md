# picsee 原生设计实施规范

版本0.1 · 2026-10-21 · 状态：**P0-08 原生 token、状态表面与 Debug 组件预览代码已建立，真机验证待完成**。

主设计规则仍由 [DESIGN.md](../../DESIGN.md) 决定；本目录将已确认的 C 布局转换为跨平台语义、组件契约和原生实现边界，不新增产品功能。

| 文档 | 解决的问题 |
| --- | --- |
| [TOKEN_MAPPING.md](TOKEN_MAPPING.md) | 哪些 CSS token 迁入原生、哪些留作兼容；points/pixels、字体、混色与尺寸 |
| [TOKEN_REGISTRY.json](TOKEN_REGISTRY.json) | 由现有 CSS 提取的语义映射清单；记录源文件 SHA256，可校验，非另一套手填颜色 |
| [COMPONENT_CONTRACTS.md](COMPONENT_CONTRACTS.md) | 组件输入、状态、键盘与可访问性、复用边界、对应 mockup 和阶段 |
| [NATIVE_MAPPING.md](NATIVE_MAPPING.md) | SwiftUI/AppKit 职责、外观/焦点/图像坐标的桥接、推荐代码归属与验收 |

约束：保留现有五个 production targets；PicseeDesignKit 是现有 UI target 内的逻辑分组，不新增第六个包。不把 JSX、CSS、静态 HTML 或全部遗留 token 机械翻译成 Swift。

变更路径：先修改主规范和 token 源，再更新本目录，最后实施原生组件。生成清单使用 `python3 scripts/export_native_design_tokens.py`；它只导出规格，不生成 Swift 或原生资源文件。

## #347 · Viewer Tools / Thumbnail Size（owner「A A C」，2026-11-03）

canonical 来源：[`../tokens/viewer-grid.css`](../tokens/viewer-grid.css)。状态稿内联相同 token 和规则，使 `PinnedDesign` 与浏览器读取同一份 SHA 固定的 HTML。

| Token / 规则 | 原生映射 |
| --- | --- |
| `--tool-background-opacity:50%` | Tool Background Opacity 默认0.50，外层 panel 按此比例混合；slider 的含义不变 |
| `--tool-background-blur:20px`、`--tool-background-saturation:1.6` | 浏览器外观参考，原生使用平台 blur material，不照抄 CSS 数字 |
| `--tool-content-backing-opacity:50%`、inset2px、radius4px | 工具内部额外 panel 衬底，外层仍50%；原生以可测量的等效处理保证对比度 |
| `--tool-foreground-halo`、`--tool-glyph-ink` | 图标、计数、zoom label 用 text 色+halo；glyph 同位文字色叠印保留原线宽。两种外观、平白/平黑底图：实际 glyph ≥3:1，文字 ≥4.5:1。33 的计数也包含在内 |
| `--thumbnail-size-min/default/max` =140/220/280 | >720pt 的最小列宽，列均分余宽；不是固定 cell 宽 |
| `--thumbnail-height-base` 与 wide200/medium165 | 默认高 clamp(135pt,窗口宽×.147,225pt)，≥1600为200，≤1050为165；>720时乘 size/220 |
| compact track145 / height150；≤480一列 | 窄窗优先，三档尺寸都遵守，Thumbnail Size 只在 >720pt 影响几何 |

Tool fill 以状态稿14/16/33为准；13/25/27/28/34的solid-tool填充已被取代。220默认几何保持既有 Swift parity 值（1280时188.16pt），尺寸变体留给#349；native blur、可读性和设备对照留给#351。HTML/原生字体栅格差异需独立设备验证，不以网页通过代替。
