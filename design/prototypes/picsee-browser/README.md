# Mado 图片浏览交互原型

日期：2026-10-20。使用已更新的 **baoyu-design v1.3.0**。这是用于评审布局和交互的浏览器原型，产品的 Swift + SwiftUI + AppKit 技术路线不变。

当前：[C 沉浸浏览与精简网格](./VIEWER_OPTIONS.md)。第二稿入口为 `viewer-v2.html`（`viewer-options.html` 同步显示第二稿）；A/B 及方案切换条已移除。下面的初版说明对应保留的 `index.html`。

## 正式状态稿

[states/README.md](states/README.md) 和 [20页索引](states/index.html) 为可提交的静态状态稿。交互实现仍在当前目录，状态稿不等于新增功能已接入。两者共用picsee-ui-system视觉规则。

## 运行

在项目根目录运行：

```sh
python3 -m http.server 4311 --bind 127.0.0.1 --directory design
```

然后打开 [Mado 原型](http://127.0.0.1:4311/prototypes/picsee-browser/)。若端口被占用，更换端口并更新链接即可。保留整个目录便可迁移，React 和演示图片都在本地；运行页面不依赖 CDN。

## 主要流程

1. 点击侧栏选择文件夹；“日本 · 山海之间”展示全部 12 张演示图片，子文件夹展示对应集合。
2. 单击选中缩略图，按 **Space** 或双击打开大图；网格中也支持 Enter。
3. 在大图模式按 **← / →** 或点击两侧箭头翻图；到首尾时停止，不循环。
4. 按 **Esc** 返回网格，保留选中图片、键盘焦点和滚动位置。Space 在画布获得焦点时也可返回。
5. 点击右上角太阳/月亮切换主题，选择在此浏览器保存。网格与大图共用主题。

网格方向键根据实际列数移动；搜索框、排序器等输入控件获得焦点时不会被 Space/方向键劫持。大图保留当前文件夹的筛选和排序范围。

## 额外可操作内容

- 搜索文件名/图片标题，名称或日期排序，搜索空态。
- 收藏/取消收藏与收藏集合；浏览记录。
- 缩略图尺寸滑杆，侧栏与图片信息面板显隐。
- 大图放大、缩小、恢复适应窗口；放大后可拖动画面。
- 快捷键说明弹层，Esc 关闭并恢复焦点。
- “添加文件夹”使用浏览器文件选择器，临时预览所选本地图片。不会上传文件；刷新页面后需重新选择。本地新增图片的支持格式取决于浏览器，不能用它验证未来 ImageIO/RAW 能力。

## 视觉来源与适配

上游设计来源为 `design/DESIGN.md`、`design/DESIGN.stitch.md` 和固定提交 `cee9af46f390b82f3df656552fe7e46da8870ddd` 的实际主题 CSS。

原型使用完整浅深色 token、单一蓝色强调色、冷灰界面、细分隔线、12px 起的系统排版、4/6/10px 圆角和即时主题切换。照片是主要视觉内容，不为缩略图添加浮起卡片或装饰性渐变。macOS 窗口圆点为装饰，不是真实窗口控制。

因复制来的上游资料尚无 baoyu 可消费的 React bundle，本次在 `design/picsee-ui-system/` 建立最小适配源：沿用原 token 值，增加分类注释及 `IconButton / Keycap / NavRow` 三个本地组件，然后使用新版 compiler/checker/importer 生成并导入 `_ds/`。上游复制文件保持不变。绑定、生成路径与资产状态记录在 `_d_meta.json`。

## 数据说明

演示照片来自 [Unsplash](https://unsplash.com/)，逐张来源见 [ASSETS.md](./ASSETS.md) 和 [assets/sources.json](./assets/sources.json)。文件名、分组、日期和中文标题为原型示例；像素尺寸读取自实际图片，不冒充原图 EXIF。收藏和主题保存在当前浏览器 localStorage，近期浏览只保存在本次页面会话。

## 验证结果

已在实际 Chrome 浏览器执行 **30 项检查**，包含：全部图片加载、Space/箭头/Esc、首尾边界、选中和焦点恢复、滚动位置保留、文件夹范围、主题切换及刷新恢复、输入框键盘隔离、搜索空态、排序、侧栏、信息面板、快捷键弹层、缩放，以及 800px 窗口大图布局。运行结果无 pageerror 和页面资源失败。

- [验证记录](./qa/verification.json)
- [浅色网格](./qa/grid-light.png)
- [深色大图](./qa/viewer-dark.png)
- [深色网格](./qa/grid-dark.png)
- [窄窗口大图](./qa/viewer-narrow.png)

这些结果不等于 Swift 原生应用、系统快捷键接管、真实文件访问授权、缓存性能、HDR 或生产可访问性已经验收。添加本地文件夹和拖动平移未包含在上述 30 项自动化记录中，可在后续扩展验证。

## 修改与重新生成

`app.jsx` 管理唯一交互状态，`ui.jsx` 提供图片与图标，`data.js` 为演示集合，`styles.css` 为图片浏览器布局。浏览器加载预编译后的 `app.js / ui.js`。

修改 JSX 后执行：

```sh
node design/prototypes/picsee-browser/build.mjs
```

该脚本使用本机 baoyu-design 内置 Babel；可通过 `BAOYU_DESIGN_HOME` 指定另一安装路径。部署只需静态文件，不需要此构建工具。

设计状态为 **needs-review**，等待用户评审；没有将原型标为已批准或已实现产品。
