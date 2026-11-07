---
status: accepted
date: 2026-10-21
---

# ADR-001：原生 Swift，AppKit 拥有窗口，SwiftUI 只做面板

picsee 用原生 Swift（SwiftUI + AppKit + ImageIO），不用 Tauri、Electron、Qt 或 Rust UI：核心价值（瞬开、真实像素、色彩与 HDR、sandbox 授权、低内存）都直接依赖 ImageIO、Core Animation 和 AppKit 窗口系统，跨平台方案要把最难的部分重写，而产品只面向 macOS。

在原生方案内，**窗口由 AppKit 拥有**：每个查看窗口是一个 `NSWindowController`，画布与网格是原生 AppKit 视图（网格用 `NSCollectionView`）；设置、Inspector、侧栏、空态等面板用 SwiftUI 编写，通过 `NSHostingView` / `NSHostingController` 嵌入。原因是 C 设计的关键体验都在窗口层：红绿灯随工具隐藏（P1-08）、置顶窗口（P4）、全屏、焦点链、多窗口生命周期；由 SwiftUI `WindowGroup` 拥有窗口时，这些都要穿过桥接层，并有 SwiftUI 重建画布与网格的风险（开发计划 §11 风险表已要求画布与交互收敛到 AppKit 单一所有者，这里把同一原则上移到窗口）。

## Considered Options

- **SwiftUI 主导**（`WindowGroup` + `NSViewRepresentable` 嵌入画布与网格）：样板代码更少，但窗口级行为与视图身份不受控。未选。
- **纯 AppKit**：控制最完整，但设置、Inspector、String Catalog 和设计 token 的面板工作量更大。未选；SwiftUI 留给它擅长的面板。

## Consequences

- `PicseeApp` 用 `NSApplicationDelegate` 作为入口和组合根，不用 SwiftUI `App` 场景管理窗口；设置窗口同样由 AppKit 创建、内容为 SwiftUI。
- P0-03 验证的是「AppKit 窗口内嵌 SwiftUI 面板 + AppKit 画布」：Retina 尺寸、鼠标锚点缩放、AppKit 与 SwiftUI 之间的焦点转移。
- 重评条件：确定支持其他平台并有可共享核心时；或 SwiftUI 窗口 API 能完整覆盖上述窗口级行为且有实测证据时。

注：Picsee 是 Mado 的旧名（#547、ADR-0017）。
