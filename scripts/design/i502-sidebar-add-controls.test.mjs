import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const directory = path.resolve('design/prototypes/picsee-browser/states');
const html = name => readFileSync(path.join(directory, `${name}.html`), 'utf8');
const heading = source => source.match(/<div class="sidebar-heading folder-heading">.*?<\/div>/s)?.[0];
const add = source => source.match(/<button class="add-folder">.*?<\/button>/s)?.[0];

// These are the accepted sidebar controls, rather than a second styling specification.
for (const name of ['empty-folder', 'permission-denied']) {
  test(`#502 ${name} reuses the page 11/24 add controls and CSS`, () => {
    const reference = html('folder-loading');
    assert.equal(heading(reference), heading(html('grid-light')));
    assert.equal(add(reference), add(html('grid-light')));
    assert.equal(heading(html(name)), heading(reference), 'complete folder header including +');
    assert.equal(add(html(name)), add(reference), 'complete dashed add-folder button');
    for (const selector of ['.tiny-button', '.tiny-button:hover', '.add-folder', '.add-folder:hover']) {
      const rule = source => [...source.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
        .filter(match => match[1].trim() === selector).map(match => match[2]);
      assert.deepEqual(rule(html(name)), rule(reference), `${selector} uses existing CSS`);
      assert.ok(rule(reference).length > 0);
    }
  });
}

test('#502 controls remain visible in sidebar cases without shifting state geometry', async t => {
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    const variants = ['empty-folder', 'empty-folder?case=no-subfolders', 'permission-denied',
      'permission-denied?cause=volume', 'permission-denied?case=missing',
      'permission-denied?case=unknown', 'permission-denied?case=moved'];
    for (const theme of ['light', 'dark']) {
      for (const viewport of [{ width: 1280, height: 800 }, { width: 800, height: 680 }]) {
        await page.setViewportSize(viewport);
        for (const variant of variants) {
          await t.test(`${variant} ${theme} ${viewport.width}x${viewport.height}`, async () => {
            const [name, query = ''] = variant.split('?');
            const url = pathToFileURL(path.join(directory, `${name}.html`));
            url.search = new URLSearchParams(`${query}&theme=${theme}`).toString();
            await page.goto(url.href);
            await page.evaluate(() => document.fonts.ready);
            await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
            const stateGeometry = () => page.evaluate(() => {
              const rect = element => {
                if (!element) return null;
                const { x, y, width, height } = element.getBoundingClientRect();
                return { x, y, width, height };
              };
              return Object.fromEntries(['main', '#content', '#state', '#state-title', '#state-text',
                '.recent-folders', '.mock-actions', '.grid-bottom-bar'].map(selector =>
                [selector, rect(document.querySelector(selector))]));
            });
            const geometry = await stateGeometry();
            console.log(`i502 geometry ${variant} ${theme} ${viewport.width}x${viewport.height} ${JSON.stringify(geometry)}`);
            const plus = page.locator('.sidebar .folder-heading button[aria-label="添加文件夹"]');
            const addFolder = page.locator('.sidebar .add-folder');
            assert.equal(await plus.count(), 1, 'one folder-header add control');
            assert.equal(await addFolder.count(), 1, 'one dashed add-folder control');
            for (const control of [plus, addFolder]) {
              assert.equal(await control.isVisible(), true);
              assert.equal(await control.isEnabled(), true);
              const bounds = await control.boundingBox();
              assert.ok(bounds.width > 0 && bounds.height > 0);
              assert.ok(bounds.y >= 0 && bounds.y + bounds.height <= viewport.height);
            }
            assert.equal((await addFolder.innerText()).trim(), '添加文件夹');
            assert.equal(await addFolder.evaluate(button => getComputedStyle(button).borderTopStyle), 'dashed');
            const sidebar = await page.locator('.sidebar').boundingBox();
            const main = await page.locator('main').boundingBox();
            assert.ok(sidebar.x + sidebar.width <= main.x + 0.01, 'sidebar never overlaps main state');
            // Remove just the new controls to recover the old sidebar. Main/state coordinates must stay exact.
            await plus.evaluate(button => button.remove());
            await addFolder.evaluate(button => button.remove());
            assert.deepEqual(await stateGeometry(), geometry, 'add controls must not move the native state oracle');
          });
        }
      }
    }
  } finally { await browser.close(); }
});
