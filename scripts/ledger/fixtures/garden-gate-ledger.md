# 功能账簿（garden-gate 测试用）

## Part 1 — picsee 现在有什么

### 查看与画布

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| VIEW-01 | 显示图片 | Partial | 单元 | P1-03 | `Packages/MadoKit/Sources/MadoMacUI/Canvas/CanvasView.swift` | 打开一张 JPEG，画布显示该图。限制：真机未验 |
| VIEW-02 | 1:1 显示 | Absent | 无 | P1-04 | — | 按 ⌘1，图片按像素 1:1 显示 |

### 授权与文件访问

| ID | 能力 | 状态 | 验证 | 计划 | 在哪 | 怎么确认 |
|---|---|---|---|---|---|---|
| ACCESS-01 | sandbox 授权 | Partial | 单元 | P0-09 | `Config/Mado.entitlements`、`TestAssets/access/` | 选一个目录后能读其中图片。限制：真机未验 |

### 不做

| ID | 能力 | 理由 |
|---|---|---|
| NOPE-01 | 覆盖原文件 | 见 ADR-007 |

## Part 3 — 区域审查

| 区域 | 最近审查 | 审查人 | 备注 |
|---|---|---|---|
| 查看与画布 | 2026-10-30 | doc-gardener | 0000000..1111111 |
