# P7-11 / #693：马赛克最小强度测量

决定 5.3（#680 grilling）：「下限足以糊掉整行字」——最弱的马赛克也必须让一行正文无法辨认。本记录是 `RedactionStyle.minimumMosaicStrength` 的依据。只记录实测数字。

账簿行：EDIT-07（Annotate Mode，仍为 Absent；本次只有 Package 层渲染，无用户可见改动）。工作包 P7-11，issue #693 slice A。

## 结论

- 12 个样本全部通过的最小格子边长是 **8 个图像像素**（由 en 17pt @2x、zh 15pt @2x、zh 17pt @2x 决定，三者在 7 时 Vision 仍读出原行字符）。
- 8…40 的每个格子边长，12 个样本中 Vision 都没有返回任何文字观测（observation 数为 0）。
- 取值 **16**（8 的两倍）作为最小强度。16 是安全余量的选择，不是测出的阈值；余量用于未测的字体、渲染和 Vision 版本差异。
- 钉住测试：`issue693MinimumMosaicLeavesVisionNoCharacterOfTheLine`（逐个样本：未打码时 Vision 读出全部字符；`.mosaic(strength: 1)` 被提升到 16 后，Vision 读出的字符与原行无交集）。

## 方法

- **样本**：测试运行时用 CoreText 渲染（`Packages/MadoKit/Tests/MadoInfrastructureTests/RedactionTextSamples.swift`）。系统 UI 字体（`CTFontCreateUIFontForLanguage(.system)`），黑字白底，四周留 12 pt 白边，开启抗锯齿与字体平滑。13/15/17 pt × @1x/@2x（@2x 为同一 pt 字号在 2 倍像素上下文中绘制）× 中英文，共 12 个。
  - 英文：`Transfer 4,280.50 to account 6217 0033 1985 by Friday`（24 个不同字母/数字，不区分大小写）
  - 中文：`请在周五之前把报销单交给财务部的王老师`（19 个不同汉字）
  - 为什么不入库：`TestAssets/` 的已入库素材全部由无字体的 Python 生成器产生，`check.py` 拒绝其他文件；系统文字只能在宿主上渲染。见 `TestAssets/README.md`「Redaction text samples」。
- **打码区域**：整行的排版框（宽 = 行宽，高 = ascent + descent，均按像素），向外取整到整像素；格子从该框左上角对齐。
- **识别器**：Apple Vision `VNRecognizeTextRequest`，`.accurate`，`recognitionLanguages = ["zh-Hans", "en-US"]`，开启语言校正。取每个观测的首选候选。
- **判据**：把 Vision 读出的全部文字和原行都取「字母、数字、汉字」并转小写，求交集；交集为空即通过（标准比「读出某个子串」更严：一个字符都不能出现）。对照组（不打码）必须读出原行全部字符，否则该样本无效。
- **扫描**：每个样本、每个格子边长 2…40 各识别一次（`issue693MeasureMosaicMinimum`，只在设置 `MADO_693_MEASURE` 时运行）。复现：

  ```sh
  MADO_693_MEASURE=/path/out.tsv scripts/heavy-lock.sh swift test --package-path Packages/MadoKit --filter issue693MeasureMosaicMinimum
  ```

## 运行环境

2026-11-13，Mac mini M4，16 GB，macOS 26.4（25E246），Xcode 26.6（17F113）的 SwiftPM 测试进程，分支 `feat/693a-redaction-render`（`74b9f1d8` 之上的工作区）。执行者 opus-imple-1。

扫描共跑了四次。前两次（空字段留空）输出逐字节相同；之后扫描改为空字段写 `-`（避免行尾空白），又跑两次，两份输出逐字节相同（SHA-256 前缀 `8593b016f5958904`），去掉 `-` 后与前两次相同。入库的是后一版。完整输出：[`P7-693-mosaic-minimum.tsv`](P7-693-mosaic-minimum.tsv)（列：样本、像素尺寸与行高、格子边长（0 = 对照）、读出的原行字符（无则 `-`）、观测数、Vision 原文（无则 `-`））。

## 每个样本的结果

| 样本 | 图像像素（行高） | 对照读出 | 仍读出原行字符的格子边长 | 从此全部通过 | 最后一次有观测 |
|---|---|---|---|---|---|
| en 13pt @1x | 362×40（15 px） | 24/24 | 2, 3 | 4 | 3 |
| en 13pt @2x | 724×79（30 px） | 24/24 | 2–6 | 7 | 6 |
| en 15pt @1x | 406×42（17 px） | 24/24 | 2, 3 | 4 | 3 |
| en 15pt @2x | 812×84（35 px） | 24/24 | 2–6 | 7 | 6 |
| en 17pt @1x | 448×45（20 px） | 24/24 | 2, 3 | 4 | 3 |
| en 17pt @2x | 896×89（40 px） | 24/24 | 2–7 | **8** | 7 |
| zh 13pt @1x | 270×40（15 px） | 19/19 | 2 | 3 | 3 |
| zh 13pt @2x | 539×79（30 px） | 19/19 | 2–5 | 6 | 5 |
| zh 15pt @1x | 307×42（17 px） | 19/19 | 2 | 3 | 2 |
| zh 15pt @2x | 614×84（35 px） | 19/19 | 2–7 | **8** | 7 |
| zh 17pt @1x | 345×45（20 px） | 19/19 | 2, 3 | 4 | 3 |
| zh 17pt @2x | 689×89（40 px） | 19/19 | 2–7 | **8** | 7 |

每个样本失败的格子边长都是从 2 开始的连续区间，此后到 40 没有再失败。「最后一次有观测」之后 Vision 不再返回任何观测。

边界处的读出示例（格子边长 7）：

| 样本 | Vision 读出 | 命中的原行字符 |
|---|---|---|
| en 17pt @2x | `Trwrfer 4aoos0te wcour:d2t7 00.23 tan5 by FHdw` | 0 2 3 4 5 7 a b c d e f n o r s t u y |
| zh 15pt @2x | `傳星再出：柯肥的销單究以科多認物业图得` | 的 销 |
| zh 17pt @2x | `谓在国工2開限程弱单疫指财券的的工卷郡` | 单 在 的 财 |

## 限制

- 最小强度以**图像像素**计。比 17 pt @2x（行高 40 px）更大的文字（标题、@3x 截图、拍摄的文档）没有测过；阈值随字形尺寸增长，对这些图片 16 不保证足够。用户可以调高强度。
- 只测了一种识别器（Vision `.accurate`，macOS 26.4）、一种字体（系统 UI 字体）、黑字白底。其他颜色对比、字体或更强的识别/去马赛克方法未测。
- 「弱马赛克可被还原」的提示文案（决定 5.4）属于 UI，不在本 slice。
