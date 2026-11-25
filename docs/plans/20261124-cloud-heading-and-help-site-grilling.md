# Grilling record: 云识别 heading and the help site (2026-11-24)

Scope: two changes that came out of the Settings copy review (#882) and were not covered by the Table Recognition grilling (`20261124-table-recognition-grilling.md`). Decisions are the owner's; the prototype that was compared is described under Decision 1.

## Decision 1: 「云识别」 is a first-level group in Settings › 截图

Owner: 「可以，云识别单独作为一级标题，相应地修改user journey描述」, then chose layout **A** after seeing three variants in a prototype (A: group holds only the switch; B: switch plus every service and key; C: rename only).

- The 截图 pane order: 截图工具条, 截图之后, 全局快捷键, **云识别**, 文字识别, 表格识别.
- 云识别 holds the one switch 「允许云识别（识别文字、识别表格）」 and its one-line hint. Nothing else.
- Each command keeps its own service, access key and (for 表格识别) Test button and shortcut in its own group, because each command has its own service and key.
- State page 35 and journeys J5/J6 show this (PR #883). Tickets #870 (T12) and #871 (T4) carry it in their acceptance.

## Decision 2: when the switch is off, 文字识别 and 表格识别 stay editable

Owner chose 「保持可编辑」. This keeps 2026-11-13 「文字识别不变灰」 and lets a user save a key before turning the switch on. Off means no image leaves the Mac: Recognise Text uses on-device recognition; Recognise Table shows the 「云识别已关闭」 guidance (T8, #877).

## Decision 3: help site goes live before the release that links to it

Owner chose 「我来启用，核对内容后再发布」.

- The owner enables GitHub Pages in the repository settings. The workflow stays manual-dispatch.
- Before publishing: remove the internal notes and the draft banner from every page, and check each page's text against the Settings copy (#882).
- The Settings 「了解更多 ↗」 links point at the real Pages address only after it is live. A release that contains the links is blocked until the site answers (checked in release rehearsal, #860).
- Screen Recording page uses the exact macOS name 「录屏与系统录音」 / Screen & System Audio Recording, checked on a device.

## Glossary

No new term. 「云识别」 is the existing Cloud Recognition (engine) shown as a Settings group; GLOSSARY already says so.
