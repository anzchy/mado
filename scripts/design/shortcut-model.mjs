#!/usr/bin/env node
// The shortcut list state page (states/shortcuts.html, #214, layout C) must list exactly the shortcuts the app
// implements: every keyed menu item in the command model, every implemented CommandID, and the key handlers outside
// the menus. Every row on the page is compared; a row without data-shortcut or a keycap outside a row fails. Every key
// code a keyDown, keyCode comparison or .onKeyPress handles must be declared in KEY_SITES, as a row or as an exclusion.
// Not compared: modifier variants with the grid arrows, and a second site for a code
// that a file already declares. Run by `npm run design:check`; `node scripts/design/shortcut-model.mjs` runs it alone
// and exits 1 when the page and the code disagree. Sources are read through `read(path)` so tests can feed changed copies.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const FILES = {
  commandID: 'Packages/MadoKit/Sources/MadoCore/Commands/CommandID.swift',
  menu: 'App/Commands/CommandMenu.swift',
  windowCommands: 'Packages/MadoKit/Sources/MadoMacUI/Chrome/ChromeWindowCommands.swift',
  page: 'design/prototypes/picsee-browser/states/shortcuts.html',
};
// Directories searched for key equivalents the parser above does not read; any found fails the check.
const SCAN = ['App', 'Packages/MadoKit/Sources'];

// Keys handled in keyDown rather than by a menu item. Each anchor must still match its file, or the check fails and
// this list has to be revisited together with the page.
export const KEY_HANDLERS = [
  { id: 'key:grid-arrows', file: 'Packages/MadoKit/Sources/MadoMacUI/Grid/GridBrowserView.swift',
    anchor: /case 123: delta = -1\s+case 124: delta = 1\s+case 125: delta = columnStep\s+case 126: delta = -columnStep/,
    keys: ['←', '→', '↑', '↓'] },
  { id: 'key:grid-page-up', file: 'Packages/MadoKit/Sources/MadoMacUI/Grid/GridBrowserView.swift',
    anchor: /let preserveSelection = !event\.modifierFlags\.intersection\(\[\.shift, \.command\]\)\.isEmpty[\s\S]*?case 116: onPageOrEdge\?\(\.page\(-1\), preserveSelection\); return/,
    keys: ['Page Up', '⇧', 'Page Up'] },
  { id: 'key:grid-page-down', file: 'Packages/MadoKit/Sources/MadoMacUI/Grid/GridBrowserView.swift',
    anchor: /let preserveSelection = !event\.modifierFlags\.intersection\(\[\.shift, \.command\]\)\.isEmpty[\s\S]*?case 121: onPageOrEdge\?\(\.page\(1\), preserveSelection\); return/,
    keys: ['Page Down', '⇧', 'Page Down'] },
  { id: 'key:grid-home', file: 'Packages/MadoKit/Sources/MadoMacUI/Grid/GridBrowserView.swift',
    anchor: /let preserveSelection = !event\.modifierFlags\.intersection\(\[\.shift, \.command\]\)\.isEmpty[\s\S]*?case 115: onPageOrEdge\?\(\.first, preserveSelection\); return/,
    keys: ['Home', '⇧', 'Home'] },
  { id: 'key:grid-end', file: 'Packages/MadoKit/Sources/MadoMacUI/Grid/GridBrowserView.swift',
    anchor: /let preserveSelection = !event\.modifierFlags\.intersection\(\[\.shift, \.command\]\)\.isEmpty[\s\S]*?case 119: onPageOrEdge\?\(\.last, preserveSelection\); return/,
    keys: ['End', '⇧', 'End'] },
  { id: 'key:grid-context-menu', file: 'Packages/MadoKit/Sources/MadoMacUI/Grid/GridBrowserView.swift',
    anchor: /if event\.keyCode == 36, contextModifiers == \.control \{/, keys: ['⌃', 'Return'] },
  { id: 'key:viewer-tab', file: 'Packages/MadoKit/Sources/MadoMacUI/Canvas/CanvasView.swift',
    anchor: /if event\.keyCode == 48 \{ onTab\?\(/, keys: ['Tab'] },
];
// Every key code handled outside the menus, per file: the page row it belongs to, or why it has none. A code found in a
// file and not declared here fails, and so does a declared code the file no longer handles.
const FOCUSED_CONTROL = 'focus and activation inside a focused control (Tab, Space, Return), not a command';
const OPEN_KEY_RING = 'Return, Space and keypad Enter open an image; here they only decide that a focus move shows no ring';
const DISPLAY_PANEL_ESC = 'Esc closes the open Display panel, a popover dismissal, not a command';
// #690: R, Esc and the swallowed arrows act only inside Annotate Mode; the page lists ⌘E, which enters it.
const ANNOTATE_ONLY = 'only in Annotate Mode';
export const KEY_SITES = {
  'Packages/MadoKit/Sources/MadoMacUI/Grid/GridBrowserView.swift': {
    123: 'key:grid-arrows', 124: 'key:grid-arrows', 125: 'key:grid-arrows', 126: 'key:grid-arrows',
    116: 'key:grid-page-up', 121: 'key:grid-page-down', 115: 'key:grid-home', 119: 'key:grid-end',
    36: 'key:grid-context-menu' },
  'Packages/MadoKit/Sources/MadoMacUI/Canvas/CanvasView.swift': { 48: 'key:viewer-tab',
    36: { excluded: OPEN_KEY_RING }, 49: { excluded: OPEN_KEY_RING }, 76: { excluded: OPEN_KEY_RING } },
  'App/CanvasWindowController.swift': { 34: 'command:inspector', 53: 'command:escape', 49: 'command:preview', 36: 'command:enter', 76: 'command:enter',
    48: { excluded: 'Tab moves focus between the grid, its footer and the Inspector' } },
  'App/Commands/CommandMenu.swift': { 34: 'command:inspector' },
  'Packages/MadoKit/Sources/MadoApplication/Viewer/InspectorEscapePolicy.swift': { 53: 'command:escape' },
  'Packages/MadoKit/Sources/MadoMacUI/States/ViewerStateFocus.swift': { 53: 'command:escape',
    48: { excluded: FOCUSED_CONTROL }, 49: { excluded: FOCUSED_CONTROL }, 36: { excluded: FOCUSED_CONTROL } },
  'Packages/MadoKit/Sources/MadoMacUI/Chrome/ViewerChromeOverlay.swift': { 53: 'command:escape',
    48: { excluded: FOCUSED_CONTROL }, 49: { excluded: FOCUSED_CONTROL } },
  'Packages/MadoKit/Sources/MadoMacUI/Grid/GridShellView.swift': {
    123: { excluded: 'arrows resize the focused sidebar divider' }, 124: { excluded: 'arrows resize the focused sidebar divider' },
    53: { excluded: DISPLAY_PANEL_ESC }, 48: { excluded: 'Tab stays in the open Display panel\'s own key loop' } },
  'Packages/MadoKit/Sources/MadoMacUI/Grid/GridDisplayPanelView.swift': { 53: { excluded: DISPLAY_PANEL_ESC } },
  'Packages/MadoKit/Sources/MadoMacUI/Grid/GridSidebarTreeView.swift': {
    36: { excluded: FOCUSED_CONTROL }, 49: { excluded: FOCUSED_CONTROL }, 76: { excluded: FOCUSED_CONTROL } },
  'Packages/MadoKit/Sources/MadoMacUI/DesignSystem/Components/DesignComponents.swift': { space: { excluded: FOCUSED_CONTROL } },
  'Packages/MadoKit/Sources/MadoMacUI/States/ReadFailedStateView.swift': { 36: { excluded: FOCUSED_CONTROL }, 76: { excluded: FOCUSED_CONTROL } },
  'App/CanvasWindowController+Annotate.swift': { 53: { excluded: ANNOTATE_ONLY }, 123: { excluded: ANNOTATE_ONLY },
    124: { excluded: ANNOTATE_ONLY }, 125: { excluded: ANNOTATE_ONLY }, 126: { excluded: ANNOTATE_ONLY } },
};
// The one file that maps typed characters to commands; it does so through CommandID.matching, read above.
const CHARACTER_FILES = ['Packages/MadoKit/Sources/MadoMacUI/Canvas/CanvasView.swift'];
// Files that read typed characters for keys the page does not list, each with its reason.
export const CHARACTER_EXCLUSIONS = { 'App/CanvasWindowController+Annotate.swift': ANNOTATE_ONLY };

/** Key codes a Swift source handles: keyCode == N, case N inside switch …keyCode { }, [N, M].contains(….keyCode)
 * (with or without a leading !), and .onKeyPress(.name). */
export function keySites(source) {
  const codes = new Set(), unread = [];
  for (const [, code] of source.matchAll(/\bkeyCode == (\d+)/g)) codes.add(code);
  const codeList = /\[(\d+(?:, *\d+)*)\]\.contains\([\w.]*\.keyCode\)/g;
  for (const [, listed] of source.matchAll(codeList)) for (const code of listed.split(',')) codes.add(code.trim());
  for (const match of source.matchAll(/switch [\w.]*keyCode \{/g)) {
    let depth = 1, i = match.index + match[0].length;
    while (depth && i < source.length) { if (source[i] === '{') depth++; else if (source[i] === '}') depth--; i++; }
    for (const [, list] of source.slice(match.index, i).matchAll(/\bcase ([^:]+):/g))
      for (const code of list.split(',')) /^\d+$/.test(code.trim()) ? codes.add(code.trim()) : unread.push(`case ${list}`);
  }
  for (const [, name] of source.matchAll(/\.onKeyPress\(\.(\w+)/g)) codes.add(name);
  // A keyCode in any other shape (!=, a stored copy, contains on a named set) is not read here.
  for (const line of source.split('\n')) {
    const rest = line.replace(/\bkeyCode == \d+/g, '').replace(/switch [\w.]*keyCode \{/, '').replace(codeList, '').replace(/keyCode: (event\.keyCode|UInt16)/g, '');
    if (/\bkeyCode\b/.test(rest)) unread.push(line.trim());
  }
  if (/\.onKeyPress\((?!\.\w+[,)])/.test(source)) unread.push('.onKeyPress without a single named key');
  return { codes, unread };
}

// Keyed menu items left off the page on purpose. The Edit menu's standard text keys only act in the search field;
// layout C has the three cards 文件与窗口, 网格 and 大图 (spec #212 story 26), none of which holds them.
export const EXCLUDED_MENUS = { edit: 'Edit menu: standard text editing, acts only in the search field' };

// Hidden alternates that work but are not shown on the page, by command: ⌘= is the unshifted ⌘+ on a US layout
// (#348; the owner asked for ⌘+ / ⌘− / ⌘0 / ⌘9). Only these exact keys are dropped; every other key is compared.
export const UNDISPLAYED_ALIASES = { zoomIn: '⌘=' };

const MODIFIERS = [['control', '⌃'], ['option', '⌥'], ['shift', '⇧'], ['command', '⌘']];
const NAMED = { ' ': 'Space', '\r': 'Return', '\u{1b}': 'Esc', '\u{f702}': '←', '\u{f703}': '→', '\u{f700}': '↑', '\u{f701}': '↓', '-': '−', '\t': 'Tab' };

function swiftString(literal) {
  return literal.replace(/\\u\{([0-9a-fA-F]+)\}/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
    .replace(/\\r/g, '\r').replace(/\\t/g, '\t').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
}
const keyGlyph = key => NAMED[key] ?? key.toUpperCase();
const glyphs = (key, modifiers) => MODIFIERS.filter(([m]) => modifiers.includes(m)).map(([, g]) => g).concat(keyGlyph(key));
const listOf = (source, re, what) => {
  const m = source.match(re);
  if (!m) throw Error(`cannot parse ${what}`);
  return m[1].split(',').map(s => s.trim().replace(/^\./, '')).filter(Boolean);
};

/** Every shortcut the code implements, as Map id → { keys, source }. */
export function codeShortcuts(read) {
  const shortcuts = new Map(), problems = [];
  // groups: the keys as the page shows them, shown form first, then the bare alternates; one group for most rows.
  const add = (id, keys, source, groups = [keys]) => {
    if (shortcuts.has(id)) problems.push(`duplicate shortcut id ${id}`);
    shortcuts.set(id, { keys, source, groups });
  };

  // CommandID: the implemented commands, their default keys and whether they use ⌘.
  const commandID = read(FILES.commandID);
  const implemented = listOf(commandID, /var isImplemented: Bool \{ \[([^\]]*)\]/, 'CommandID.isImplemented');
  const usesCommand = listOf(commandID, /var usesCommand: Bool \{ \[([^\]]*)\]/, 'CommandID.usesCommand');
  const keyBlock = commandID.match(/var defaultKey: String \{([\s\S]*?)\n {4}\}/);
  if (!keyBlock) throw Error('cannot parse CommandID.defaultKey');
  const defaultKey = Object.fromEntries([...keyBlock[1].matchAll(/case \.(\w+): "((?:[^"\\]|\\.|\\u\{[0-9a-fA-F]+\})*)"/g)]
    .map(([, id, literal]) => [id, swiftString(literal)]));
  const menuFilter = commandID.match(/static var menuCommands: \[Self\] \{ allCases\.filter \{ \$0\.isImplemented && \$0 != \.(\w+) \} \}/);
  if (!menuFilter) throw Error('cannot parse CommandID.menuCommands');
  // #348: a zoom command shows its ⌘ form (commandKey) and keeps the bare key, plus any extra keys, as hidden alternates.
  const commandKeyBlock = commandID.match(/var commandKey: String\? \{\s*switch self \{([\s\S]*?)\n {8}\}/);
  if (!commandKeyBlock) throw Error('cannot parse CommandID.commandKey');
  const commandKey = Object.fromEntries([...commandKeyBlock[1].matchAll(/case \.(\w+): "((?:[^"\\]|\\.)*)"/g)]
    .map(([, id, literal]) => [id, swiftString(literal)]));
  for (const [shape, what] of [
    [/var menuBinding: CommandKeyBinding \{\s*CommandKeyBinding\(key: commandKey \?\? defaultKey, command: commandKey != nil \|\| usesCommand\)\s*\}/, 'CommandID.menuBinding'],
    [/var alternateMenuBindings: \[CommandKeyBinding\] \{\s*guard commandKey != nil else \{ return \[\] \}\s*let bare = CommandKeyBinding\(key: defaultKey, command: usesCommand\)/, 'CommandID.alternateMenuBindings']])
    if (!shape.test(commandID)) throw Error(`cannot parse ${what}`);
  const extra = commandID.match(/return self == \.(\w+) \? \[bare, ((?:CommandKeyBinding\(key: "[^"]+", command: (?:true|false)\)(?:, )?)+)\] : \[bare\]\n/);
  if (!extra) throw Error('cannot parse the extra alternates in CommandID.alternateMenuBindings');
  const extraBindings = [...extra[2].matchAll(/CommandKeyBinding\(key: "([^"]+)", command: (true|false)\)/g)]
    .map(([, literal, command]) => ({ key: swiftString(literal), command: command === 'true' }));

  // CommandMenu installs CommandID.menuCommands with menuBinding, then each alternate as a hidden item that keeps its key.
  const menu = read(FILES.menu);
  for (const shape of [/for id in CommandID\.menuCommands \{\s*let binding = id\.menuBinding\s*let item = NSMenuItem\([^\n]*keyEquivalent: binding\.key\)\s*item\.keyEquivalentModifierMask = binding\.command \? \[\.command\] : \[\]/,
    /for id in CommandID\.menuCommands \{\s*for \(index, binding\) in id\.alternateMenuBindings\.enumerated\(\) \{\s*let item = NSMenuItem\([^\n]*keyEquivalent: binding\.key\)\s*item\.keyEquivalentModifierMask = binding\.command \? \[\.command\] : \[\]/,
    /item\.isHidden = true\s*item\.allowsKeyEquivalentWhenHidden = true/])
    if (!shape.test(menu)) throw Error(`CommandMenu.swift no longer installs CommandID.menuCommands as expected (${shape})`);
  const binding = (key, command) => glyphs(key, command ? ['command'] : []);
  for (const id of implemented) {
    if (!(id in defaultKey)) throw Error(`CommandID.${id} has no defaultKey`);
    // The command left out of menuCommands (search) has its own menu item, parsed below by its title.
    if (id === menuFilter[1]) continue;
    const bare = binding(defaultKey[id], usesCommand.includes(id));
    if (!(id in commandKey)) { add(`command:${id}`, bare, FILES.commandID); continue; }
    // The shown ⌘ form first, then the hidden alternates in install order, less the aliases the page leaves out.
    const extras = id === extra[1] ? extraBindings.map(b => binding(b.key, b.command)) : [];
    const listed = extras.filter(keys => UNDISPLAYED_ALIASES[id] !== keys.join(''));
    if (UNDISPLAYED_ALIASES[id] && listed.length === extras.length)
      problems.push(`UNDISPLAYED_ALIASES names ${UNDISPLAYED_ALIASES[id]} for ${id}, which the code no longer installs`);
    const groups = [binding(commandKey[id], true), [bare, ...listed].flat()];
    add(`command:${id}`, groups.flat(), FILES.commandID, groups);
  }
  for (const id of Object.keys(UNDISPLAYED_ALIASES)) if (id !== extra[1])
    problems.push(`UNDISPLAYED_ALIASES names ${id}, which has no extra alternates`);
  for (const id of Object.keys(commandKey)) if (!implemented.includes(id)) problems.push(`CommandID.commandKey names ${id}, which is not implemented`);

  // Menu items with a literal title and a literal, non-empty key equivalent.
  let literalKeys = 0;
  const menuItem = /(?:let (\w+) = )?(\w+)\.addItem\(withTitle: String\(localized: "([^"]+)"\),\s*action: [^\n]*?(?:\n[^\n]*?)?keyEquivalent: "((?:[^"\\]|\\.)*)"\)/g;
  for (const file of [FILES.menu, FILES.windowCommands]) {
    const source = read(file);
    for (const match of source.matchAll(menuItem)) {
      const [, variable, receiver, title, literal] = match;
      const key = swiftString(literal);
      if (!key) continue;
      literalKeys++;
      let modifiers = ['command'];
      if (variable) {
        // Only this item's own statements: up to the next item or function.
        const after = source.slice(match.index + match[0].length);
        const end = after.search(/addItem\(|NSMenuItem\(|\bfunc /);
        const mask = after.slice(0, end < 0 ? undefined : end).match(new RegExp(`\\b${variable}\\.keyEquivalentModifierMask = \\[([^\\]]*)\\]`));
        if (mask) modifiers = mask[1].split(',').map(s => s.trim().replace(/^\./, '')).filter(Boolean);
      }
      const id = `menu:${title}`;
      if (EXCLUDED_MENUS[receiver]) { shortcuts.set(id, { keys: glyphs(key, modifiers), source: file, excluded: EXCLUDED_MENUS[receiver] }); continue; }
      add(id, glyphs(key, modifiers), file);
    }
  }
  // Edit's Cut/Copy/Paste/Select All come from a tuple loop; they are excluded like the rest of Edit.
  const editLoop = menu.match(/for \(title, action, key\) in \[([\s\S]*?)\] \{\s*edit\.addItem/);
  if (editLoop) for (const [, title, key] of editLoop[1].matchAll(/\("([^"]+)", "[^"]+", "([^"]+)"\)/g)) {
    literalKeys++;
    shortcuts.set(`menu:${title}`, { keys: glyphs(key, ['command']), source: FILES.menu, excluded: EXCLUDED_MENUS.edit });
  }

  // Every literal key equivalent in the app must be one parsed above; SwiftUI shortcuts are not parsed at all.
  let found = 0;
  const seenSites = new Set();
  const walk = dir => {
    for (const entry of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
      const rel = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(rel);
      else if (entry.name.endsWith('.swift')) {
        const source = read(rel);
        found += [...source.matchAll(/keyEquivalent: "((?:[^"\\]|\\.)+)"/g)].length;
        found += [...source.matchAll(/\("[^"]+", "[^"]+:", "[^"]+"\)/g)].length;
        if (/\.keyboardShortcut\(/.test(source)) problems.push(`${rel} uses .keyboardShortcut, which this check does not read`);
        if (/charactersIgnoringModifiers|\.specialKey\b/.test(source) && !CHARACTER_FILES.includes(rel) && !CHARACTER_EXCLUSIONS[rel])
          problems.push(`${rel} reads typed characters, which this check does not read`);
        const sites = keySites(source), declared = KEY_SITES[rel] ?? {};
        for (const line of sites.unread) problems.push(`${rel} reads a key code in a shape this check does not read: ${line}`);
        for (const code of sites.codes) if (!(code in declared))
          problems.push(`${rel} handles key code ${code}, which KEY_SITES does not declare; give it a page row or an exclusion`);
        for (const code of Object.keys(declared)) if (!sites.codes.has(code))
          problems.push(`KEY_SITES declares key code ${code} in ${rel}, which no longer handles it`);
        seenSites.add(rel);
      }
    }
  };
  for (const dir of SCAN) walk(dir);
  if (found !== literalKeys) problems.push(`found ${found} literal key equivalents in ${SCAN.join(', ')} but parsed ${literalKeys}; teach scripts/design/shortcut-model.mjs the new shape`);

  for (const handler of KEY_HANDLERS) {
    if (!handler.anchor.test(read(handler.file))) problems.push(`${handler.id}: ${handler.file} no longer matches ${handler.anchor}`);
    add(handler.id, handler.keys, handler.file);
  }
  for (const [file, codes] of Object.entries(KEY_SITES)) {
    if (!seenSites.has(file)) problems.push(`KEY_SITES names ${file}, which is not a Swift file under ${SCAN.join(', ')}`);
    for (const [code, row] of Object.entries(codes))
      if (typeof row === 'string' && (!shortcuts.has(row) || shortcuts.get(row).excluded))
        problems.push(`KEY_SITES maps key code ${code} in ${file} to ${row}, which is not a listed shortcut`);
  }
  return { shortcuts, problems };
}

/** Every row of the page, as [{ ids, name, keys }], and the keycaps outside rows. A row is any <li>; it lists its ids in
 * data-shortcut, separated by |, and its keys as <kbd>. */
export function pageShortcuts(html) {
  const rows = [...html.matchAll(/<li\b([^>]*)>([\s\S]*?)<\/li>/g)].map(([, attrs, body]) => ({
    ids: ((attrs.match(/\bdata-shortcut="([^"]*)"/) || [, ''])[1]).split('|').map(id => id.trim()).filter(Boolean),
    name: (body.match(/<span class="name">([^<]*)<\/span>/) || [, ''])[1].trim(),
    keys: [...body.matchAll(/<kbd>([^<]+)<\/kbd>/g)].map(m => m[1]),
  }));
  const strayKeys = (html.match(/<kbd>/g) || []).length - rows.reduce((n, row) => n + row.keys.length, 0);
  return Object.assign(rows, { strayKeys });
}

/** Differences between the code and the page; empty when they agree. */
export function compare({ shortcuts, problems }, rows) {
  const out = [...problems], seen = new Map();
  if (!rows.length) out.push('the page has no data-shortcut rows');
  if (rows.strayKeys) out.push(`${rows.strayKeys} keycaps sit outside a row; every shortcut shown must be a <li> row`);
  for (const row of rows) {
    if (!row.ids.length) { out.push(`row ${row.name || '(no name)'} (${row.keys.join(' ')}) has no data-shortcut`); continue; }
    if (!row.name) out.push(`${row.ids.join('|')} has no name`);
    for (const id of row.ids) {
      if (seen.has(id)) out.push(`${id} is listed twice`);
      seen.set(id, row);
      const code = shortcuts.get(id);
      if (!code) out.push(`page lists ${id} (${row.name}), which the code does not implement`);
      else if (code.excluded) out.push(`page lists ${id}, which is excluded: ${code.excluded}`);
    }
    if (row.ids.every(id => shortcuts.has(id))) {
      // A row with several commands shows each group across them: ⌘+ ⌘− before + −.
      const groups = row.ids.map(id => shortcuts.get(id).groups ?? [shortcuts.get(id).keys]);
      const want = groups[0].flatMap((_, g) => groups.flatMap(gs => gs[g] ?? []));
      if (groups.some(gs => gs.length !== groups[0].length)) out.push(`${row.ids.join('|')} (${row.name}) joins commands with different key groups`);
      if (JSON.stringify(want) !== JSON.stringify(row.keys))
        out.push(`${row.ids.join('|')} (${row.name}) shows ${row.keys.join(' ') || 'no keys'}, the code has ${want.join(' ')}`);
    }
  }
  for (const [id, code] of shortcuts) if (!code.excluded && !seen.has(id))
    out.push(`code implements ${id} (${code.keys.join('')}, ${code.source}) but the page does not list it`);
  return out;
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const readRepo = file => fs.readFileSync(path.join(root, file), 'utf8');

export function check(read = readRepo) {
  let html;
  try { html = read(FILES.page); } catch (error) { return [`cannot read ${FILES.page}: ${error.message}`]; }
  return compare(codeShortcuts(read), pageShortcuts(html));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const problems = check();
  if (problems.length) { console.error('shortcut-model FAIL:\n- ' + problems.join('\n- ')); process.exit(1); }
  console.log('shortcut-model PASS');
}
