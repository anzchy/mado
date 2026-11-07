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

## #502 · 系统焦点环的原生边界

Owner 于 2026-11-04 选择「Native exception (Recommended)」：原生控件默认采用 macOS 系统焦点环；第 24 页读取状态、24F 读取失败状态和第 26 页访问恢复状态明确遵守这一边界。App 保留系统环，不照搬 HTML 的 2 pt 方形强调色环或主按钮双环。

Parity 审查不因系统环与 HTML 的环样式不同而记为 FAIL；焦点位置仍须验收，包括初始焦点是否落在规定动作、Tab / Shift-Tab 的移动目标、当前焦点是否可见。此边界只豁免环样式，不豁免焦点落错控件、焦点丢失或键盘不可达。对应规程见 [UI 对照契约](../../../docs/agents/ui-parity-contract.md)。这是既有原生行为的记录，未改变 App。

## #347 · Viewer Tools / Thumbnail Size（owner「A A C」，2026-11-03）

canonical 来源：[`../tokens/viewer-grid.css`](../tokens/viewer-grid.css)。状态稿内联相同 token 和规则，使 `PinnedDesign` 与浏览器读取同一份 SHA 固定的 HTML。

| Token / 规则 | 原生映射 |
| --- | --- |
| `--tool-background-opacity:50%` | Tool Background Opacity 默认0.50，外层 panel 按此比例混合；slider 的含义不变 |
| `--tool-background-blur:20px`、`--tool-background-saturation:1.6` | 浏览器外观参考，原生使用平台 blur material，不照抄 CSS 数字 |
| #351 原生材质与不透明度 | `NSVisualEffectView` 使用 `.popover`、`.withinWindow`、`.active`，裁到 6 pt 圆角；上方独立颜色表面按偏好的 30–100% 绘制 panel（默认 50%），内部仍叠加 inset 2 pt / radius 4 pt / panel 50%。100% 时颜色层与外层实色底板保留原外观，并暂停绘制被遮住的材质，避免材质影响抗锯齿边缘；低于 100% 时外层底板保持 panel RGB、alpha 为 0，阴影仍在外层容器。picsee 不读取 Reduce Transparency；系统可将材质回落为实色，独立 panel 颜色层仍按偏好绘制。离屏颜色/几何测试不证明 WindowServer 模糊或设备视觉效果，后两者留待真机。 |
| `--tool-content-backing-opacity:50%`、inset2px、radius4px | 工具内部额外 panel 衬底，外层仍50%；原生以可测量的等效处理保证对比度 |
| `--tool-foreground-halo`、`--tool-glyph-ink` | 图标、计数、zoom label 用 text 色+halo；glyph 同位文字色叠印保留原线宽。两种外观、平白/平黑底图：实际 glyph ≥3:1，文字 ≥4.5:1。33 的计数也包含在内 |
| `--thumbnail-size-min/default/max` =140/220/280 | >720pt 的最小列宽，列均分余宽；不是固定 cell 宽 |
| `--thumbnail-height-base` 与 wide200/medium165 | 默认高 clamp(135pt,窗口宽×.147,225pt)，≥1600为200，≤1050为165；>720时乘 size/220 |
| compact track145 / height150；≤480一列 | 窄窗优先，三档尺寸都遵守，Thumbnail Size 只在 >720pt 影响几何 |

Tool fill 以状态稿14/16/33为准；13/25/27/28/34的solid-tool填充已被取代。220默认几何保持既有 Swift parity 值（1280时188.16pt），尺寸变体留给#349；native blur、可读性和设备对照留给#351。HTML/原生字体栅格差异需独立设备验证，不以网页通过代替。
