import fs from 'node:fs';
import path from 'node:path';

// Keep offsets and newlines while hiding comments and literals, including nested Swift block comments.
export function scrubSwift(source) {
  let out = '', i = 0, block = 0, line = false, quote = null;
  while (i < source.length) {
    const c = source[i], next = source[i + 1];
    if (line) {
      if (c === '\n') { line = false; out += c; } else out += ' ';
      i++; continue;
    }
    if (block) {
      if (c === '/' && next === '*') { block++; out += '  '; i += 2; continue; }
      if (c === '*' && next === '/') { block--; out += '  '; i += 2; continue; }
      out += c === '\n' ? '\n' : ' '; i++; continue;
    }
    if (quote) {
      if (c === '\\') { out += '  '; i += 2; continue; }
      if (source.startsWith(quote, i)) { out += ' '.repeat(quote.length); i += quote.length; quote = null; continue; }
      out += c === '\n' ? '\n' : ' '; i++; continue;
    }
    if (c === '/' && next === '/') { line = true; out += '  '; i += 2; continue; }
    if (c === '/' && next === '*') { block = 1; out += '  '; i += 2; continue; }
    if (c === '"') { quote = source.startsWith('"""', i) ? '"""' : '"'; out += ' '.repeat(quote.length); i += quote.length; continue; }
    out += c; i++;
  }
  return out;
}

export function findForWhere(source) {
  const clean = scrubSwift(source);
  const tokens = [...clean.matchAll(/[A-Za-z_][A-Za-z_0-9]*|[^\s]/g)];
  const hits = [];
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i][0] !== 'for' || tokens[i - 1]?.[0] === '(' || tokens[i - 1]?.[0] === '.') continue;
    let depth = 0, sawIn = false, sawWhere = false;
    for (let j = i + 1; j < tokens.length; j++) {
      const t = tokens[j][0];
      if ('(['.includes(t)) depth++;
      else if (')]'.includes(t)) depth--;
      if (depth < 0) break;
      if (depth === 0 && t === 'in') sawIn = true;
      if (depth === 0 && t === 'where' && sawIn) sawWhere = true;
      if (depth === 0 && (t === '{' || t === ';' || t === '}')) {
        if (t === '{' && sawWhere) hits.push(1 + clean.slice(0, tokens[i].index).split('\n').length - 1);
        break;
      }
    }
  }
  return hits;
}

export function scanTree(root) {
  const hits = [];
  function visit(dir) {
    for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, item.name);
      if (item.isDirectory()) visit(file);
      else if (item.name.endsWith('.swift')) for (const line of findForWhere(fs.readFileSync(file, 'utf8'))) hits.push(`${path.relative(root, file)}:${line}`);
    }
  }
  visit(root);
  return hits;
}

// Both SwiftPM sources and the native App target compile into the product.
export function scanProductionTrees(repoRoot) {
  const roots = ['Packages/MadoKit/Sources', 'App'];
  return roots.flatMap((relative) => scanTree(path.join(repoRoot, relative))
    .map((hit) => `${relative}/${hit}`));
}
