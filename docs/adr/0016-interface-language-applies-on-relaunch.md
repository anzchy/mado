# Interface Language applies on relaunch

The owner asked that all of picsee's text be in one language, English or Chinese, switchable in Settings (2026-10-29: 「关于app的所有文字，要么都是英文，要么都是中文，可以在Setting 中切换」). macOS draws part of the interface itself (the Open panel, standard menu items, full-screen titles, system alert buttons) in the language the process launched with, and that cannot be changed while running. So a change of Interface Language takes effect only at the next launch. Settings offers a 「立即重新启动」 button that relaunches picsee and reopens the folder or image that was open. Until then every text, picsee's own included, stays in the launch language.

## Considered Options

- **Instant switch of picsee's own text**: rejected. Until a relaunch, picsee text and macOS-drawn text would be in two languages, which is what the owner asked to avoid. It would also make every window redraw its strings.
- **Instant switch plus a relaunch prompt**: rejected. It has the same mixed state in between and is the most work.

## Consequences

- The options are Follow System, English and Simplified Chinese; Follow System maps any Chinese system language, Traditional included, to Simplified Chinese.
- Relaunching needs a resume path that reopens the open folder or image inside the sandbox, through its Access Root.
- Scheduled after v0.0.1; until then picsee follows the system language as before.

注：Picsee 是 Mado 的旧名（#547、ADR-0017）。
