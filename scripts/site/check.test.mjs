import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
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
