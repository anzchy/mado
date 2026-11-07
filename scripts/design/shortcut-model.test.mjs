// node --test scripts/design/*.test.mjs (run by npm run design:check). Each case changes one source the check reads
// and expects the named disagreement; the first case is the repository as it is.
import test from 'node:test';
import assert from 'node:assert/strict';
import { FILES, check, readRepo } from './shortcut-model.mjs';

const withChange = (file, edit) => f => (f === file ? edit(readRepo(f)) : readRepo(f));
const replaceOnce = (from, to) => source => {
  assert.ok(source.includes(from), `fixture anchor missing: ${from}`);
  return source.replace(from, to);
};
const fails = (read, pattern) => {
  const problems = check(read);
  assert.ok(problems.some(p => pattern.test(p)), `expected ${pattern}, got:\n${problems.join('\n') || '(no problems)'}`);
};

test('the shortcut page equals the implemented commands', () => {
  assert.deepEqual(check(), []);
});

test('a newly implemented CommandID that the page lacks fails', () => {
  const read = withChange(FILES.commandID, s => s
    .replace('case preview, previous,', 'case rotate, preview, previous,')
    .replace('case .preview: " "', 'case .rotate: "r"\n        case .preview: " "')
    .replace('public var isImplemented: Bool { [.preview,', 'public var isImplemented: Bool { [.rotate, .preview,'));
  fails(read, /code implements command:rotate \(R,/);
});

test('a command removed from the implemented set but still on the page fails', () => {
  fails(withChange(FILES.commandID, replaceOnce('.zoomIn, .zoomOut, .search', '.zoomIn, .search')),
    /page lists command:zoomOut .*which the code does not implement/);
});

test('a new keyed menu item fails until the page lists it', () => {
  fails(withChange(FILES.menu, replaceOnce('app.addItem(withTitle: String(localized: "Show All")',
    'app.addItem(withTitle: String(localized: "Print"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "p")\n        app.addItem(withTitle: String(localized: "Show All")')),
  /code implements menu:Print \(⌘P,/);
});

test('a changed modifier mask fails on the row that shows the old keys', () => {
  fails(withChange(FILES.menu, replaceOnce('sidebar.keyEquivalentModifierMask = [.control, .command]',
    'sidebar.keyEquivalentModifierMask = [.option, .command]')),
  /menu:Hide sidebar .* shows ⌃ ⌘ S, the code has ⌥ ⌘ S/);
});

test('a page row with the wrong keys fails', () => {
  fails(withChange(FILES.page, replaceOnce('data-shortcut="menu:Quit Mado"><span class="name">退出 Mado</span><span class="keys"><kbd>⌘</kbd><kbd>Q</kbd>',
    'data-shortcut="menu:Quit Mado"><span class="name">退出 Mado</span><span class="keys"><kbd>⌘</kbd><kbd>W</kbd>')),
  /menu:Quit Mado .* shows ⌘ W, the code has ⌘ Q/);
});

test('a page row for an Edit-menu key is refused', () => {
  fails(withChange(FILES.page, replaceOnce('data-shortcut="menu:Quit Mado"', 'data-shortcut="menu:Quit Mado|menu:Undo"')),
    /page lists menu:Undo, which is excluded/);
});

test('a key handler that no longer matches its anchor fails', () => {
  fails(withChange('Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift',
    replaceOnce('if event.keyCode == 48 { onTab?(', 'if event.keyCode == 49 { onTab?(')),
  /key:viewer-tab: .*CanvasView\.swift no longer matches/);
});

test('a key equivalent in a shape the parser does not read fails', () => {
  fails(withChange(FILES.menu, replaceOnce('let recentItem = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "")',
    'let recentItem = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "r")')),
  /found \d+ literal key equivalents .* but parsed \d+/);
});

// #214 fix round 1. Every row on the page is compared (gpt F1), every keyDown site is accounted for (opus M1), and a
// modifier mask belongs to its own item's statements (opus L3).
const CARD_END = '<li class="row" data-shortcut="menu:Hide sidebar">';
test('a visible row without data-shortcut fails', () => {
  fails(withChange(FILES.page, replaceOnce(CARD_END,
    '<li class="row"><span class="name">旋转</span><span class="keys"><kbd>⌘</kbd><kbd>R</kbd></span></li>\n        ' + CARD_END)),
  /row 旋转 .*has no data-shortcut/);
});

test('a keycap outside a row fails', () => {
  fails(withChange(FILES.page, replaceOnce('</ul>\n    </section>\n    <section class="shortcut-card" id="card-viewer"',
    '</ul><p class="hint">按 <kbd>⌘</kbd><kbd>R</kbd> 旋转</p>\n    </section>\n    <section class="shortcut-card" id="card-viewer"')),
  /2 keycaps sit outside a row/);
});

test('a row without a name fails', () => {
  fails(withChange(FILES.page, replaceOnce('<span class="name">退出 Mado</span>', '<span class="name"></span>')),
    /menu:Quit Mado has no name/);
});

test('a new keyDown case fails until it is declared', () => {
  fails(withChange('Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift',
    replaceOnce('case 124: onAdjust?(8)', 'case 124: onAdjust?(8)\n        case 51: onAdjust?(0)')),
  /GridShellView\.swift handles key code 51, which KEY_SITES does not declare/);
});

test('a new keyCode comparison in another file fails until it is declared', () => {
  fails(withChange('App/UI/SettingsPanelWindow.swift',
    replaceOnce('override func cancelOperation(_ sender: Any?) { performClose(sender) }',
      'override func cancelOperation(_ sender: Any?) { performClose(sender) }\n    override func keyDown(with event: NSEvent) { if event.keyCode == 51 { return } }')),
  /SettingsPanelWindow\.swift handles key code 51, which KEY_SITES does not declare/);
});

test('a new code in a key code list fails until it is declared', () => {
  fails(withChange('Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift',
    replaceOnce('![36, 49, 76].contains(event.keyCode)', '![36, 49, 51, 76].contains(event.keyCode)')),
  /CanvasView\.swift handles key code 51, which KEY_SITES does not declare/);
});

test('a key code list without a leading ! is read too', () => {
  fails(withChange('Packages/PicseeKit/Sources/PicseeMacUI/Canvas/CanvasView.swift',
    replaceOnce('![36, 49, 76].contains(event.keyCode)', '[36, 49, 51, 76].contains(event.keyCode)')),
  /CanvasView\.swift handles key code 51, which KEY_SITES does not declare/);
});

test('a new SwiftUI key press fails until it is declared', () => {
  fails(withChange('Packages/PicseeKit/Sources/PicseeMacUI/DesignSystem/Components/DesignComponents.swift',
    replaceOnce('.onKeyPress(.space, action: activateFromKeyboard)', '.onKeyPress(.space, action: activateFromKeyboard).onKeyPress(.return, action: activateFromKeyboard)')),
  /DesignComponents\.swift handles key code return, which KEY_SITES does not declare/);
});

test('a declared key site that is gone fails', () => {
  fails(withChange('Packages/PicseeKit/Sources/PicseeMacUI/Grid/GridShellView.swift', replaceOnce('case 124: onAdjust?(8)\n', '')),
    /KEY_SITES declares key code 124 in .*GridShellView\.swift, which no longer handles it/);
});

test('a modifier mask set in a later function does not change an earlier item', () => {
  const read = withChange(FILES.menu, s => replaceOnce('settings.keyEquivalentModifierMask = [.command]\n', '')(s)
    .replace('@objc private func showDiagnostics(', 'func laterSettings() { let settings = NSMenuItem(); settings.keyEquivalentModifierMask = [.option] }\n    @objc private func showDiagnostics('));
  assert.deepEqual(check(read), []);
});

// #348 fix round 2. Zoom commands show their ⌘ form, then the bare key; ⌘= is the one undisplayed alias.
const ZOOM_ROW = '<kbd>⌘</kbd><kbd>+</kbd><kbd>⌘</kbd><kbd>−</kbd><kbd>+</kbd><kbd>−</kbd>';
test('the ⌘= exclusion does not hide the bare zoom key', () => {
  fails(withChange(FILES.page, replaceOnce(ZOOM_ROW, '<kbd>⌘</kbd><kbd>+</kbd><kbd>⌘</kbd><kbd>−</kbd><kbd>−</kbd>')),
    /command:zoomIn\|command:zoomOut .* shows ⌘ \+ ⌘ − −, the code has ⌘ \+ ⌘ − \+ −/);
});

test('the ⌘= exclusion does not hide the shown ⌘ form', () => {
  fails(withChange(FILES.page, replaceOnce(ZOOM_ROW, '<kbd>⌘</kbd><kbd>−</kbd><kbd>+</kbd><kbd>−</kbd>')),
    /command:zoomIn\|command:zoomOut .* shows ⌘ − \+ −, the code has ⌘ \+ ⌘ − \+ −/);
});

test('the ⌘= exclusion does not hide another extra alternate', () => {
  fails(withChange(FILES.commandID, replaceOnce('CommandKeyBinding(key: "=", command: true)',
    'CommandKeyBinding(key: "=", command: true), CommandKeyBinding(key: "*", command: true)')),
  /command:zoomIn\|command:zoomOut .* the code has ⌘ \+ ⌘ − \+ ⌘ \* −/);
});

test('a ⌘= on the page is refused while it is an undisplayed alias', () => {
  fails(withChange(FILES.page, replaceOnce(ZOOM_ROW, '<kbd>⌘</kbd><kbd>+</kbd><kbd>⌘</kbd><kbd>−</kbd><kbd>+</kbd><kbd>⌘</kbd><kbd>=</kbd><kbd>−</kbd>')),
    /command:zoomIn\|command:zoomOut .* the code has ⌘ \+ ⌘ − \+ −/);
});

test('an excluded alias the code no longer installs fails', () => {
  fails(withChange(FILES.commandID, replaceOnce('CommandKeyBinding(key: "=", command: true)', 'CommandKeyBinding(key: "*", command: true)')),
    /UNDISPLAYED_ALIASES names ⌘= for zoomIn, which the code no longer installs/);
});

test('a bare fit key on the page without the ⌘ form fails', () => {
  fails(withChange(FILES.page, replaceOnce('<kbd>⌘</kbd><kbd>9</kbd><kbd>0</kbd>', '<kbd>0</kbd>')),
    /command:fit \(适应窗口\) shows 0, the code has ⌘ 9 0/);
});
