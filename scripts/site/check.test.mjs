import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkSite } from './check.mjs';

async function fixture(pages, run) {
  const dir = await mkdtemp(join(tmpdir(), 'mado-site-'));
  try {
    for (const [name, html] of Object.entries(pages)) {
      await mkdir(join(dir, name, '..'), { recursive: true });
      await writeFile(join(dir, name), html);
    }
    await run(dir);
  } finally { await rm(dir, { recursive: true, force: true }); }
}

test('rejects draft, internal note and ticket number in rendered pages', async () => {
  await fixture({ 'index.html': '<h1>草稿</h1><p>内部备注：#887</p>' }, async dir => {
    const errors = await checkSite(dir);
    assert.match(errors.join('\n'), /draft|草稿/i);
    assert.match(errors.join('\n'), /internal|内部/i);
    assert.match(errors.join('\n'), /#887/);
  });
});

test('resolves relative and site-root links; rejects absent and escaping pages', async () => {
  await fixture({
    'index.html': '<a href="guide/ok.html#step">OK</a><a href="/mado/missing.html">bad</a><a href="../outside.html">escape</a>',
    'guide/ok.html': '<a href="../index.html">home</a>',
  }, async dir => {
    const errors = await checkSite(dir);
    assert.equal(errors.length, 2);
    assert.match(errors.join('\n'), /missing\.html/);
    assert.match(errors.join('\n'), /outside\.html/);
  });
});

test('rejects glossary and shipped Settings copy violations', async () => {
  await fixture({ 'index.html': '<p>云端识别需要密钥；点“识别文字”然后 Recognize Text。</p>' }, async dir => {
    const errors = await checkSite(dir);
    assert.match(errors.join('\n'), /云端识别/);
    assert.match(errors.join('\n'), /访问密钥/);
    assert.match(errors.join('\n'), /Recognize/);
    assert.match(errors.join('\n'), /「」/);
  });
});

test('accepts user-facing copy and external links', async () => {
  await fixture({ 'index.html': '<p>云识别使用访问密钥；点「识别文字」或 Recognise Text。</p><a href="https://example.com">service</a>' }, async dir => {
    assert.deepEqual(await checkSite(dir), []);
  });
});

test('rejects robots noindex metadata while accepting other robots directives', async () => {
  for (const markup of [
    '<meta name="robots" content="noindex">',
    '<meta content="follow, NOINDEX" name="ROBOTS">',
    '<meta name=robots content="noindex, nofollow">',
  ]) {
    await fixture({ 'index.html': `<h1>Help</h1>${markup}` }, async dir => {
      assert.match((await checkSite(dir)).join('\n'), /robots noindex/);
    });
  }
  await fixture({ 'index.html': '<h1>Help</h1><meta name="robots" content="index, follow">' }, async dir => {
    assert.deepEqual(await checkSite(dir), []);
  });
});

test('rejects internal notes hidden in HTML comments', async () => {
  await fixture({ 'index.html': '<!-- TODO: internal note #887 --><h1>Help</h1>' }, async dir => {
    assert.match((await checkSite(dir)).join('\n'), /internal note in HTML comment/);
  });
});

test('requires the Mado row and exact macOS permission name on the permission page', async () => {
  await fixture({ 'screen-recording.html': '<h1>录屏</h1><p>Open Screen Recording.</p>' }, async dir => {
    assert.match((await checkSite(dir)).join('\n'), /Mado row/);
  });
});

test('scans content, alt, title and aria-label values for notes and terminology', async () => {
  const cases = [
    ['meta content', '<meta name="description" content="owner confirm 云端识别">', /owner confirm.*云端识别/s],
    ['image alt', '<img alt="待确认：访问密钥">', /待确认/],
    ['title', '<a title="Recognizes text" href="index.html">help</a>', /Recogniz/i],
    ['aria-label', '<button aria-label="内部备注：密钥">help</button>', /内部备注.*访问密钥/s],
  ];
  for (const [name, markup, pattern] of cases) {
    await fixture({ 'index.html': `<h1>Help</h1>${markup}` }, async dir => {
      assert.match((await checkSite(dir)).join('\n'), pattern, name);
    });
  }
});

test('scans style, script and all HTML comments for notes and terminology', async () => {
  const cases = [
    ['style', '<style>/* TODO owner confirm 云端识别 */</style>', /TODO.*云端识别/s],
    ['script', '<script>/* TBD Recognizes 密钥 */</script>', /TBD.*Recogniz.*访问密钥/s],
    ['comment', '<!-- 云端识别; recognize; 密钥; 预览版 -->', /云端识别.*Recogniz.*访问密钥.*预览版/s],
  ];
  for (const [name, markup, pattern] of cases) {
    await fixture({ 'index.html': `<h1>Help</h1>${markup}` }, async dir => {
      assert.match((await checkSite(dir)).join('\n'), pattern, name);
    });
  }
});

test('rejects internal markers and proto banner but allows ordinary draft and public issue links', async () => {
  for (const marker of ['TBD', 'WIP', '原型', '预览版', '待确认', 'owner confirm']) {
    await fixture({ 'index.html': `<p>${marker}</p>` }, async dir => {
      assert.match((await checkSite(dir)).join('\n'), new RegExp(marker, 'i'));
    });
  }
  await fixture({ 'index.html': '<div class="proto">Please see the service site.</div>' }, async dir => {
    assert.match((await checkSite(dir)).join('\n'), /proto/);
  });
  await fixture({ 'index.html': '<p>Save a draft before sending it.</p><a href="https://github.com/anzchy/mado/issues/887">Issue #887</a>' }, async dir => {
    assert.deepEqual(await checkSite(dir), []);
  });
});

test('rejects draft banners in visible text, comments and metadata', async () => {
  const cases = [
    ['English block', '<div>Draft: not ready to publish</div>'],
    ['Chinese block', '<p>草稿：本页内容</p>'],
    ['English after sentence', '<p>Help. Draft: not ready to publish</p>'],
    ['comment', '<!-- Draft: not ready to publish -->'],
    ['meta content', '<meta name="description" content="Draft: not ready to publish">'],
    ['alt', '<img alt="Draft: not ready to publish">'],
    ['title', '<a href="index.html" title="Draft: not ready to publish">Help</a>'],
    ['aria-label', '<button aria-label="草稿：尚未发布">Help</button>'],
    ['proto class', '<div class="proto">草稿：本页内容</div>'],
  ];
  for (const [name, markup] of cases) {
    await fixture({ 'index.html': `<h1>Help</h1>${markup}` }, async dir => {
      assert.match((await checkSite(dir)).join('\n'), /draft banner|proto or draft banner class/, name);
    });
  }
});

test('allows ordinary draft copy and a public issue link', async () => {
  await fixture({ 'index.html': '<p>Save a draft before sending it.</p><a href="https://github.com/anzchy/mado/issues/887">Issue #887</a>' }, async dir => {
    assert.deepEqual(await checkSite(dir), []);
  });
});

test('accepts a contained stylesheet while rejecting missing, escaping and navigation asset hrefs', async () => {
  await fixture({ 'index.html': '<link rel="stylesheet" href="style.css">', 'style.css': 'body { margin: 0; }' }, async dir => {
    assert.deepEqual(await checkSite(dir), []);
  });
  await fixture({
    'index.html': '<link rel="stylesheet" href="style.css"><link rel="stylesheet" href="missing.css"><link rel="stylesheet" href="../outside.css"><a href="style.css">CSS</a>',
    'style.css': 'body { margin: 0; }',
  }, async dir => {
    const errors = await checkSite(dir);
    assert.equal(errors.length, 3);
    assert.match(errors.join('\n'), /missing\.css/);
    assert.match(errors.join('\n'), /outside\.css/);
    assert.match(errors.join('\n'), /link is not a page: style\.css/);
  });
});

test('checks quoted, single-quoted and unquoted href and src forms', async () => {
  await fixture({
    'index.html': `<a href=missing-a.html>A</a><a href='missing-b.html'>B</a><a href="missing-c.html">C</a><img src=missing.png><a href=/mado>home</a>`,
  }, async dir => {
    const errors = (await checkSite(dir)).join('\n');
    for (const name of ['missing-a.html', 'missing-b.html', 'missing-c.html', 'missing.png']) assert.match(errors, new RegExp(name.replace('.', '\\.')));
    assert.doesNotMatch(errors, /\/mado(?:\s|$)/);
  });
});

test('rejects a symlink escaping the site for a page or local asset', async () => {
  const outside = await mkdtemp(join(tmpdir(), 'mado-outside-'));
  try {
    await writeFile(join(outside, 'outside.html'), '<h1>outside</h1>');
    await writeFile(join(outside, 'outside.png'), 'png');
    await fixture({ 'index.html': '<a href="escape.html">out</a><img src="escape.png">' }, async dir => {
      await symlink(join(outside, 'outside.html'), join(dir, 'escape.html'));
      await symlink(join(outside, 'outside.png'), join(dir, 'escape.png'));
      const errors = (await checkSite(dir)).join('\n');
      assert.match(errors, /escape\.html/);
      assert.match(errors, /escape\.png/);
    });
  } finally { await rm(outside, { recursive: true, force: true }); }
});

test('decodes numeric character references before checking tickets and quote style', async () => {
  await fixture({ 'index.html': '<p>&#12300;识别文字&#12301; and &#x300C;识别表格&#x300D;</p>' }, async dir => {
    assert.deepEqual(await checkSite(dir), []);
  });
  await fixture({ 'index.html': '<p>&#8220;识别文字&#8221;</p>' }, async dir => {
    assert.match((await checkSite(dir)).join('\n'), /「」/);
  });
});

test('rejects non-page, non-asset files from the published directory', async () => {
  await fixture({ 'index.html': '<h1>Help</h1>', 'README.md': '# Maintainer notes' }, async dir => {
    assert.match((await checkSite(dir)).join('\n'), /README\.md/);
  });
});

test('published site contains only checked pages and assets', async () => {
  assert.deepEqual(await checkSite(), []);
});

test('DeepSeek help routes troubleshooting through the table group Advanced control', async () => {
  const page = await readFile(new URL('../../site/deepseek-key.html', import.meta.url), 'utf8');
  assert.match(page, /设置 › 截图 › 表格识别/);
  assert.match(page, /「高级」[^<]*「地址」/);
  assert.match(page, /「高级」[^<]*「模型」/);
  assert.doesNotMatch(page, /设置 › 高级/);
});

test('help-site CI job has read-only contents and does not persist checkout credentials', async () => {
  const workflow = await readFile(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const job = workflow.split('  site-content:\n')[1]?.split('\n  # The package suite')[0] ?? '';
  assert.match(job, /permissions:\s*\n\s*contents: read/);
  assert.match(job, /persist-credentials: false/);
});

test('privacy copy never names Baidu as the only Cloud Recognition exception', async () => {
  for (const file of ['README.md', 'CHANGELOG.md', 'docs/release/notes-template.md', 'GLOSSARY.md']) {
    const source = await readFile(new URL(`../../${file}`, import.meta.url), 'utf8');
    assert.doesNotMatch(source, /(?:only exception|唯一例外)[^\n]{0,240}(?:Baidu|百度)|(?:Baidu keys|百度密钥)[^\n]{0,80}(?:to Baidu|发送给百度)/i, file);
  }
});
