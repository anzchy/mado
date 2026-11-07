import { readFileSync } from 'node:fs';

// The templates are transcribed from project.yml, App/Info.plist and the app entitlements.
// Per-name feed URLs preserve the frozen feed; null remains undecided until #552.
const source = JSON.parse(readFileSync(new URL('./identity.json', import.meta.url), 'utf8'));

export function identityFor(expectedName = source.expectedName) {
  if (!source.knownNames.includes(expectedName)) throw new Error(`unknown app identity ${JSON.stringify(expectedName)}`);
  const slug = expectedName.toLowerCase();
  const bundleId = source.bundleIdTemplate.replaceAll('{slug}', slug);
  return {
    name: expectedName,
    info: {
      CFBundleName: expectedName,
      CFBundleDisplayName: expectedName,
      CFBundleIdentifier: bundleId,
      SUFeedURL: source.feedURLs[expectedName],
    },
    machLookup: source.machSuffixes.map(suffix => bundleId + suffix),
  };
}

const letter = value => /^[A-Za-z]$/.test(value);
const upper = value => /^[A-Z]$/.test(value);
const lower = value => /^[a-z]$/.test(value);

/** Every forbidden word/identifier part, including camelCase and acronym boundaries. */
export function forbiddenMatches(text, expectedName) {
  const expected = identityFor(expectedName).name;
  const matches = [];
  for (const name of source.knownNames.filter(name => name !== expected)) {
    for (const match of text.matchAll(new RegExp(name, 'ig'))) {
      const start = match.index, end = start + match[0].length;
      const before = text[start - 1] ?? '', first = text[start], second = text[start + 1];
      const last = text[end - 1], next = text[end] ?? '', after = text[end + 1] ?? '';
      const left = !letter(before) || (lower(before) && upper(first)) || (upper(before) && upper(first) && lower(second));
      const right = !letter(next) || (lower(last) && upper(next)) || (upper(last) && upper(next) && lower(after));
      if (left && right) matches.push({ name: match[0], index: start, length: match[0].length });
    }
  }
  return matches.sort((a, b) => a.index - b.index);
}
