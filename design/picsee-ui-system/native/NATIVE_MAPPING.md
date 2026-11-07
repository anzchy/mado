# SwiftUI / AppKit 原生实施映射

2026-10-21。该文档是实施建议，API方向依照Apple文档核对；具体签名、系统可用性和桥接行为需在P0锁定SDK中编译验证。没有生成或测试原生组件代码。

## 1. 层级和归属

保留[架构](../../../docs/PICSEE_ARCHITECTURE.md)的五个production targets。MadoDesignKit是逻辑命名，不新增target。

| 层 | 建议归属 | 责任 |
| --- | --- | --- |
| 语义资源/样式适配 | MadoMacUI/DesignSystem | Colors、Typography、Metrics、Symbols、Appearance；供App内SwiftUI与AppKit共用 |
| 可复用原生视觉 | 同一target下的Components | IconCommandButton、ShortcutHint、FolderRow视觉、InspectorInfoRow、EmptyStateContent等 |
| 大图/网格/窗口宿主 | MadoMacUI的Canvas/Grid/Windows/Input/Bridges | NSCollectionViewItem、画布、视口坐标、NSWindow、系统输入与焦点桥接 |
| 页面组合 | MadoApp/UI | 目录浏览、显示设置、Inspector组合；消费共享组件和Session |
| 状态/命令 | MadoApplication | Selection、DisplayPreferences、ViewerChromeState与CommandRouter；不创建NSWindow |
| 图像与文件服务 | MadoInfrastructure | 解码、metadata、FileAccess、Cache、Watcher；不引用UI组件 |

建议未来目录（仅说明，不创建这些Swift文件）：

```text
MadoMacUI/
  DesignSystem/
    Tokens/          # MadoColors / Typography / Metrics / SymbolCatalog
    Appearance/      # 外观适配与资源解析
    Components/      # 小型原生视觉与样式
  Resources/         # 如采用ColorSet，在此配置模块资源
  Canvas/ Grid/ Windows/ Input/ Bridges/
```

Swift Package资源必须明确bundle入口，避免在可复用模块里隐式假定App主bundle。App依赖MacUI取得共享设计资源；Core/Application不导入SwiftUI/AppKit样式。

## 2. 颜色与外观：一个偏好源，两个UI框架

建议优先用具有浅深外观的命名ColorSet；确需计算的角色可使用动态NSColor解析。选定一种规范资源路径，不分别维护SwiftUI十六进制与AppKit RGB两份常量。[NSColor](https://developer.apple.com/documentation/appkit/nscolor)支持随外观变化的资源颜色；[动态provider](https://developer.apple.com/documentation/appkit/nscolor/init(name:dynamicprovider:))提供按外观解析的路径。

- Application的DisplayPreferences持有 system/light/dark，UI外观适配器将其应用于窗口与SwiftUI宿主。
- system解除强制外观，使窗口继承系统；手动外观在对应窗口层设置，不能只改SwiftUI颜色而让AppKit/NSMenu保留另一套外观。
- SwiftUI通过同一命名资源/动态颜色桥接读取；AppKit从实际view/window的effectiveAppearance解析。不要在启动时转成固定CGColor后永远复用。
- 绘制层确需CGColor时，在正确appearance上下文解析并在外观变化时刷新；不能让解码后台队列任意读取窗口状态。
- 原生系统控件使用系统颜色/材质和可访问性外观，自定义画布/目录/浮层使用语义角色。高对比外观和Reduce Transparency需实机检查，不把普通两主题等同于覆盖全部系统偏好。

Apple说明外观可沿App→Window→View继承，并可在相应层覆盖：[NSAppearance](https://developer.apple.com/documentation/appkit/nsappearance)、[effectiveAppearance](https://developer.apple.com/documentation/appkit/nsappearancecustomization/effectiveappearance)。本产品采用的应用策略仍须P0验证。

## 3. SwiftUI 与 AppKit 分工

| 设计对象 | 首选方向 | 桥接要点 |
| --- | --- | --- |
| 目录/偏好/信息/空态 | SwiftUI页面＋原生控件 | 明确label、focus与命令，避免每次状态更新重建宿主 |
| 大量缩略图/胶片项 | NSCollectionView及可复用item | 稳定身份/代次，应用服务提供载荷；复用时取消旧订阅 |
| 图像画布 | AppKit自定义view/scrolling宿主 | 单一坐标/zoom所有者，渲染结果带请求身份 |
| 浮动工具 | SwiftUI轻量组合或原生view overlay | 由同一布局宿主定位；控制状态来自Session，工具本身不计时 |
| 右键菜单 | NSMenu | 系统键盘行为、目标上下文固定、合法命令启用验证 |
| 窗口/红黄绿/全屏/拖动 | NSWindow与协调器 | 系统区域保持可用，不把灰色网页圆点做成自绘替代品 |
| 打开/访达定位/路径复制 | 系统面板与服务适配器 | UI调用CommandRouter/use case，文件访问与授权生命周期由服务处理 |

无需把所有控件强行包成SwiftUI组件，也不把页面HTML转成WKWebView产品界面。设计系统只规定视觉/行为契约，具体布局和服务留在功能层。

### 符号目录的首批候选

组件传递symbolRole，原生适配层集中选择SF Symbol/template image；以下是候选名称，P0在锁定macOS/SDK中验证可用性，缺失时提供模板图形/文字回退。不要由每张稿自行选择不同画风，也不把键盘提示字符当工具栏图标。

| 角色 | SF Symbol候选 |
| --- | --- |
| 侧栏 / 返回网格 / 更多 | sidebar.left / square.grid.2x2 / ellipsis |
| 上一张 / 下一张 | chevron.left / chevron.right |
| 搜索 / 排序 / 信息 | magnifyingglass / arrow.up.arrow.down / info.circle |
| 文件夹 / 收藏 | folder / heart（选中可用heart.fill） |
| 图片无法读取（#446） | photo（32pt，线框，muted 颜色） |
| 放大 / 缩小 / 胶片条 | plus / minus / film |
| 关闭 / 快捷键帮助 | xmark / keyboard |

系统菜单/窗口优先平台自身符号与状态。无论实际符号名是什么，accessibleLabel必须描述动作而不是读出“ellipsis”等名称。

## 4. 焦点、命令和可见性

设置窗口（P3-07、#218）由 AppKit 持有单个 760×520 原生窗口（含 38 点标题栏，内容区 760×482），180 点侧栏切换通用、显示、缓存、更新、关于五个分区，并记住所选分区。对应状态稿为 [`settings.html`](../../prototypes/picsee-browser/states/settings.html)：`?section=general|display|cache|update|about` 选择分区，追加 `&theme=dark` 查看深色状态。通用页与“显示”菜单共用 DisplayPreferencesStore 和窗口外观适配器，外观、始终显示工具双向同步；显示、更新及关于页的未实现控件禁用并标注“即将推出”。⌘, 打开设置；⌘W、Esc 关闭设置窗口。缓存页继续使用 CacheSettingsModel，显示真实占用和可访问的本地化失败原因；首次打开、再次显示及切入缓存页时测量，测量时显示“正在测量…”（Measuring…）并禁用清理按钮。清理前需确认，取消保留缓存；清理和租约排空期间保持禁用，完成后重新测量占用。此处描述原生映射与行为契约，完整真机视觉、键盘及 VoiceOver 验证以功能账簿和验证记录为准。

SwiftUI侧可用[FocusState](https://developer.apple.com/documentation/swiftui/focusstate)描述本地焦点目标；AppKit侧与窗口first responder/key view路径协调。它们反映同一当前焦点，不能各自持续抢焦点或在每次切图时强制focus。

流程契约：

1. 进入Viewer时保存来源选择/滚动锚点，焦点转到画布；输入框、菜单、对话框先消费相关按键。
2. 隐藏前确认没有交互锁定原因；隐藏动作同时解除命中、键盘停靠和辅助技术暴露。
3. Tab唤回时先恢复可交互的可见结构，再把焦点移向第一个合适入口。
4. 菜单关闭优先恢复触发处；Esc再退出Viewer并恢复来源。不能让同一次Esc既关闭菜单又返回网格。
5. 外观或偏好改变不重置选择、滚动、当前图、zoom或first responder。

状态机归Application，使用可控时钟验证2.5秒延迟和交互锁定；UI组件只上报pointer/focus/menu事件。VoiceOver名称、值、选中状态与焦点顺序使用原生可访问性语义验证，不直接照抄ARIA。

## 5. 图像坐标与像素

- 布局以points工作；当前view的backing空间用于解码目标与1:1。优先使用view/window转换方法，而不是将缓存的全局scale乘到所有尺寸上。[Apple说明](https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor)。
- 1:1定义为源图像素对应backing pixel；例如2×环境下1600px对应约800pt，界面按钮仍维持其布局points。
- fit与actual-size是不同状态；显示的百分比来自实际图像变换，不是fit后的相对倍数。方向归一后的图像坐标用于平移与后续裁剪。
- 跨屏、窗口尺寸变化、sidebar/Inspector展开后重新计算视口；Filmstrip是overlay，不因为展开额外缩小fit主图。
- NSViewRepresentable/宿主更新按差异提交；不在更新回调里重建collection view、重新扫描目录或重置zoom。

## 6. P0-08交付门槛

对应[开发计划](../../../docs/PICSEE_DEVELOPMENT_PLAN.md)P0-08；P0-03/09提供像素与命令验证。

| 检查 | 必须提供的证据 |
| --- | --- |
| 资源一致性 | TOKEN_REGISTRY源哈希、选定角色两主题齐全；SwiftUI/AppKit取同一语义资源 |
| 组件状态 | 30页基础状态的原生预览，含两主题、hover/pressed/focus/disabled、长文案 |
| 外观桥接 | 同一窗口内两框架一致；system实时变化，手动覆盖/解除；系统菜单不突变为另一外观 |
| 布局/像素 | 1×/2×对照和跨屏，控件points不倍增；真实1:1与fit可区分 |
| 焦点 | 纯键盘、菜单Escape、Tab唤回、隐藏工具不可达、基本VoiceOver路径 |
| 视觉可读性 | 自定义控件文字/状态/边界的实测对比度；不能继承旧项目豁免 |
| 资源边界 | 不新增production target；不引入CSS/JS/Stitch/REA为应用运行时依赖 |

不能在本次文档交付中勾选这些原生门槛。当前交付证明的是规格、来源与映射完整；未来记录到 `docs/validation/P0.md`。
