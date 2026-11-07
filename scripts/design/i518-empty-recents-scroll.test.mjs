// Real Chromium regression; WI-4 uses standalone node RED, no guardian receipt.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';

const directory = path.resolve('design/prototypes/picsee-browser/states');
const settle = page => page.evaluate(() => new Promise(resolve =>
  requestAnimationFrame(() => requestAnimationFrame(resolve))));

async function populate(page, count) {
  await page.evaluate(count => {
    const group = document.querySelector('.recent-folders');
    const source = group.querySelector('.recent-folder').cloneNode(true);
    const list = group.querySelector('.recent-list') ?? group;
    group.querySelectorAll('.recent-folder').forEach(row => row.remove());
    for (let i = 0; i < count; i++) {
      const row = source.cloneNode(true);
      row.querySelector('.row-text').textContent = `最近文件夹 ${i + 1}`;
      row.dataset.row = String(i);
      list.append(row);
    }
    // An empty data fixture has no recent-list group, as in the native caller.
    group.hidden = count === 0;
    group.style.display = count === 0 ? 'none' : '';
  }, count);
  await settle(page);
}

async function geometry(page) {
  return page.evaluate(() => {
    const rect = element => {
      const { top, bottom, left, right, height } = element.getBoundingClientRect();
      return { top, bottom, left, right, height };
    };
    const group = document.querySelector('.recent-folders');
    const list = group.querySelector('.recent-list') ?? group;
    const button = document.querySelector('.mock-actions button');
    const rows = [...group.querySelectorAll('.recent-folder')];
    const ancestors = [];
    for (let node = list.parentElement; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (/(auto|scroll)/.test(style.overflowY) && node.scrollHeight > node.clientHeight + 1)
        ancestors.push(node.className || node.tagName);
    }
    return {
      viewport: { width: innerWidth, height: innerHeight },
      shell: rect(document.querySelector('.prototype-shell')),
      footer: rect(document.querySelector('.grid-bottom-bar')),
      button: rect(button), group: rect(group), list: rect(list),
      icon: rect(document.querySelector('#state > svg')),
      heading: rect(document.querySelector('#state-title')),
      titleGap: parseFloat(getComputedStyle(document.querySelector('#state-title')).marginTop),
      rows: rows.map(rect), scrollHeight: list.scrollHeight, clientHeight: list.clientHeight,
      overflowY: getComputedStyle(list).overflowY,
      buttonInsideList: list.contains(button), ancestors,
    };
  });
}

function visibleButton(value, label) {
  assert.ok(value.button.top >= -1 && value.button.bottom <= value.viewport.height + 1,
    `${label}: choose action inside viewport ${JSON.stringify(value.button)}`);
  assert.ok(value.button.bottom <= value.footer.top + 1, `${label}: choose action above footer`);
  assert.equal(value.buttonInsideList, false, `${label}: action outside row scroller`);
}

test('#518 recent rows scroll within their box and preserve the external action', async t => {
  const serverErrors = [];
  const server = http.createServer((request, response) => {
    const file = path.resolve(directory, '.' + new URL(request.url, 'http://localhost').pathname);
    try {
      assert.ok(file.startsWith(directory + path.sep));
      response.setHeader('Content-Type', file.endsWith('.html') ? 'text/html' : 'application/octet-stream');
      response.end(readFileSync(file));
    } catch (error) {
      serverErrors.push(String(error));
      response.writeHead(500); response.end('Fixture read failed');
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage();
    const visit = async (size, theme, count) => {
      await page.setViewportSize(size);
      const response = await page.goto(`http://127.0.0.1:${server.address().port}/empty-folder.html?case=no-subfolders&theme=${theme}`);
      assert.equal(response.status(), 200);
      assert.deepEqual(serverErrors, []);
      await populate(page, count);
    };
    for (const theme of ['light', 'dark']) {
      for (const size of [{ width: 960, height: 640 }, { width: 1280, height: 800 }]) {
        for (const count of [0, 1, 5, 10]) {
          await t.test(`${theme} ${size.width}x${size.height} ${count} rows`, async () => {
            await visit(size, theme, count);
            const before = await geometry(page);
            assert.deepEqual(before.viewport, size);
            assert.ok(Math.abs(before.shell.height - size.height) <= 1, 'desktop normalization must not replace the tested viewport');
            visibleButton(before, 'initial');
            assert.equal(before.rows.length, count);
            if (!count) {
              assert.equal(before.group.height, 0, 'no phantom recent group when empty');
              return;
            }
            assert.deepEqual(before.ancestors, [], 'no nested active vertical scrolling ancestor');
            const overflowing = before.scrollHeight > before.clientHeight + 1;
            assert.ok(!overflowing || /^(auto|scroll)$/.test(before.overflowY), 'overflow must have a real scroll mechanism');
            const complete = before.rows.filter(row => row.top >= before.list.top - 1 && row.bottom <= before.list.bottom + 1).length;
            if (size.height === 640) assert.ok(complete >= Math.min(count, 3), `at least three complete rows, got ${complete}`);
            for (let index = 0; index < count; index++) {
              await page.locator(`.recent-folder[data-row="${index}"]`).evaluate(row => row.scrollIntoView({ block: 'nearest' }));
              await settle(page);
              const after = await geometry(page);
              const row = after.rows[index];
              assert.ok(row.top >= after.list.top - 1 && row.bottom <= after.list.bottom + 1, `row ${index} scroll reachable`);
              assert.deepEqual(after.button, before.button, 'scrolling rows must not move action');
            }
            await page.evaluate(() => {
              const group = document.querySelector('.recent-folders');
              (group.querySelector('.recent-list') ?? group).scrollTop = 0;
              document.querySelector('.mock-actions button').focus({ preventScroll: true });
            });
            await settle(page);
            const reset = await geometry(page);
            if (overflowing) assert.ok(reset.rows.at(-1).bottom > reset.list.bottom + 1, 'last row starts clipped before keyboard focus');
            await page.locator('.recent-folder').last().focus();
            await settle(page);
            const focused = await geometry(page);
            assert.equal(await page.locator('.recent-folder').last().evaluate(row => document.activeElement === row), true);
            assert.ok(focused.rows.at(-1).top >= focused.list.top - 1 && focused.rows.at(-1).bottom <= focused.list.bottom + 1,
              'keyboard-focused last row fully revealed');
            assert.deepEqual(focused.button, before.button, 'focus scrolling keeps action fixed');
            visibleButton(focused, 'after focus');
            if (!overflowing) assert.ok(Math.abs(focused.scrollHeight - focused.clientHeight) <= 1, 'fitting rows have no active scroll range');
          });
        }
      }
      await t.test(`${theme} fitting three-row oracle and size restoration`, async () => {
        await visit({ width: 1280, height: 800 }, theme, 3);
        const before = await geometry(page);
        // SHA-pinned original CSS: titlebar38, outer16/70, state24/48,
        // icon32, gaps18/9/22/18, h2=23, detail22.1, recent149, action35.
        const stack = 32 + 18 + 23 + 9 + 22.1 + 22 + 149 + 18 + 35;
        const icon = 38 + 16 + 24 + (800 - 38 - 16 - 70 - 24 - 48 - stack) / 2;
        for (const [actual, expected] of [[before.icon.top, icon], [before.heading.top, icon + 50],
          [before.group.top, icon + 50 + 23 + 9 + 22.1 + 22]])
          assert.ok(Math.abs(actual - expected) <= 1, `fitting pin coordinate ${actual} vs ${expected}`);
        await page.setViewportSize({ width: 960, height: 640 }); await settle(page);
        await page.setViewportSize({ width: 1280, height: 800 }); await settle(page);
        const restored = await geometry(page);
        for (const key of ['icon', 'heading', 'group', 'button']) assert.deepEqual(restored[key], before[key], `${key} resize round trip`);
      });
      await t.test(`${theme} reduce spacing before constraining list`, async () => {
        // Natural ten-row stack594.1 + state72 + outer86 + titlebar38=790.1.
        // A1.1px deficit can be absorbed by optional spacing alone.
        await visit({ width: 1280, height: 789 }, theme, 10);
        const value = await geometry(page);
        visibleButton(value, 'just crowded');
        assert.ok(value.titleGap < 18 && value.titleGap >= 10 - 0.1, 'first deficit reduces optional title gap');
        assert.ok(value.scrollHeight <= value.clientHeight + 1, 'spacing reduction precedes list clipping');
      });
    }
  } finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
  }
});
