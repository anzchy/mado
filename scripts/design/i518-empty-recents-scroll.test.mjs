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
      page: rect(document.querySelector('#content')),
      pageScrollTop: document.querySelector('#content').scrollTop,
      pageScrollHeight: document.querySelector('#content').scrollHeight,
      pageClientHeight: document.querySelector('#content').clientHeight,
      pageOverflowY: getComputedStyle(document.querySelector('#content')).overflowY,
      available: document.querySelector('#content').clientHeight
        - parseFloat(getComputedStyle(document.querySelector('#content')).paddingTop)
        - parseFloat(getComputedStyle(document.querySelector('#content')).paddingBottom),
    };
  });
}

function visibleButton(value, label) {
  assert.ok(value.button.top >= -1 && value.button.bottom <= value.viewport.height + 1,
    `${label}: choose action inside viewport ${JSON.stringify(value.button)}`);
  assert.ok(value.button.bottom <= value.footer.top + 1, `${label}: choose action above footer`);
  assert.equal(value.buttonInsideList, false, `${label}: action outside row scroller`);
}

// Measure intrinsic parts in a fitting page, not the constrained group height or
// the page's calculated fallback flag. Normal line heights depend on installed fonts.
async function naturalMetrics(page) {
  return page.evaluate(() => {
    const height = selector => document.querySelector(selector).getBoundingClientRect().height;
    return {
      title: height('#state-title'), detail: height('#state-text'),
      action: height('.mock-actions'), header: height('.recent-heading'),
      firstRow: height('.recent-folder'), followingRow: height('.recent-folder + .recent-folder'),
    };
  });
}
function insideUsablePage(value, rect, label) {
  const top = Math.max(value.page.top, 0), bottom = Math.min(value.page.bottom, value.footer.top);
  assert.ok(rect.top >= top - 1 && rect.bottom <= bottom + 1,
    `${label}: fully above footer in page ${JSON.stringify({ rect, top, bottom })}`);
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
      await page.evaluate(() => document.fonts.ready);
      await populate(page, count);
    };
    for (const theme of ['light', 'dark']) {
      await visit({ width: 1280, height: 1600 }, theme, 10);
      const natural = await naturalMetrics(page);
      for (const [name, height] of Object.entries(natural))
        assert.ok(height > 0, `natural ${name} has a measurable height`);
      // Border2, icon32 and normal/compact spacing are fixed by the pinned CSS.
      // Only typography-driven heights come from Chromium in this same theme/page.
      const naturalGroupHeight = count => count
        ? 2 + natural.header + natural.firstRow + (count - 1) * natural.followingRow : 0;
      const fixed = 32 + natural.title + natural.detail + natural.action;
      const naturalStack = count => fixed + 18 + 9 + (count ? 22 : 0) + 18 + naturalGroupHeight(count);
      const compactMinimum = count => fixed + (count ? 64 + naturalGroupHeight(1) : 52);
      const fitting = await geometry(page);
      assert.ok(fitting.available >= 24 + 48 + naturalStack(10), 'intrinsic reference has room for every row');
      assert.ok(Math.abs(fitting.group.height - naturalGroupHeight(10)) <= 1,
        'fitting reference retains independently summed header and row heights');
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
            if (size.width === 1280 && size.height === 800 && [1, 5].includes(count)) {
              // These counts fit by the pin arithmetic, independent of measured overflow.
              assert.ok(fixed + 64 + naturalGroupHeight(count) <= before.available,
                'independent pin arithmetic proves this count fits');
              assert.ok(before.scrollHeight <= before.clientHeight + 1, 'fitting count must not scroll');
              assert.ok(Math.abs(before.group.height - naturalGroupHeight(count)) <= 1,
                `fitting count retains natural group height ${naturalGroupHeight(count)}`);
            }
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
        // SHA-pinned titlebar38, outer16/70, state24/48 and normal gaps;
        // intrinsic text/header/row/button heights are measured independently above.
        const stack = naturalStack(3);
        const icon = 38 + 16 + 24 + (800 - 38 - 16 - 70 - 24 - 48 - stack) / 2;
        for (const [actual, expected] of [[before.icon.top, icon], [before.heading.top, icon + 50],
          [before.group.top, icon + 50 + natural.title + 9 + natural.detail + 22]])
          assert.ok(Math.abs(actual - expected) <= 1, `fitting pin coordinate ${actual} vs ${expected}`);
        await page.setViewportSize({ width: 960, height: 640 }); await settle(page);
        await page.setViewportSize({ width: 1280, height: 800 }); await settle(page);
        const restored = await geometry(page);
        for (const key of ['icon', 'heading', 'group', 'button']) assert.deepEqual(restored[key], before[key], `${key} resize round trip`);
      });
      await t.test(`${theme} reduce spacing before constraining list`, async () => {
        // Introduce a small deficit relative to this font set's natural stack.
        // Optional spacing must absorb it before the list gains a scroll range.
        const height = Math.ceil(38 + 86 + 24 + 48 + naturalStack(10)) - 2;
        await visit({ width: 1280, height }, theme, 10);
        const value = await geometry(page);
        visibleButton(value, 'just crowded');
        assert.ok(value.titleGap < 18 && value.titleGap >= 10 - 0.1, 'first deficit reduces optional title gap');
        assert.ok(value.scrollHeight <= value.clientHeight + 1, 'spacing reduction precedes list clipping');
      });
      const contentHeight = async height => {
        await page.locator('.prototype-shell').evaluate((shell, height) => {
          shell.style.height = `${height + 38}px`;
        }, height);
        await settle(page);
        const actual = await geometry(page);
        assert.ok(Math.abs(actual.shell.height - 38 - height) <= 0.1, 'exact content height after titlebar38');
        return actual;
      };
      const checkScopeAndReachability = async (count, fallback) => {
        const before = await geometry(page);
        if (fallback) {
          assert.match(before.pageOverflowY, /^(auto|scroll)$/, 'short page has real scroll mechanism');
          assert.ok(before.pageScrollHeight > before.pageClientHeight, 'short page has a scroll range');
          assert.ok(before.scrollHeight <= before.clientHeight + 1, 'full page has no nested row range');
          assert.ok(Math.abs(before.group.height - naturalGroupHeight(count)) <= 1,
            'full page retains natural recent header and rows');
        } else {
          assert.ok(before.pageScrollHeight <= before.pageClientHeight + 1, 'bounded-list page stays fixed');
          insideUsablePage(before, before.button, 'bounded-list action');
          if (count) insideUsablePage(before, before.rows[0], 'one complete row at compact threshold');
        }
        assert.equal(before.rows.length, count);
        for (let index = 0; index < count; index++) {
          await page.locator(`.recent-folder[data-row="${index}"]`).evaluate(row => row.scrollIntoView({ block: 'nearest' }));
          await settle(page);
          const value = await geometry(page);
          insideUsablePage(value, value.rows[index], `short row ${index}`);
        }
        await page.locator('.mock-actions button').evaluate(button => button.scrollIntoView({ block: 'nearest' }));
        await settle(page);
        const action = await geometry(page);
        insideUsablePage(action, action.button, 'short action');
        if (count) {
          await page.locator('.recent-folder').last().focus(); await settle(page);
          const focused = await geometry(page);
          insideUsablePage(focused, focused.rows.at(-1), 'short focused last row');
        }
      };
      for (const height of [300, 200]) {
        for (const count of [0, 1, 5, 10]) {
          await t.test(`${theme} short content${height} rows${count}`, async () => {
            await visit({ width: 960, height: 800 }, theme, count);
            const value = await contentHeight(height);
            assert.ok(Math.abs(value.available - (height - 86)) <= 1, 'outer16/70 includes footer40');
            await checkScopeAndReachability(count, value.available < compactMinimum(count));
          });
        }
      }
      for (const count of [0, 1, 10]) {
        for (const delta of [-1, 0, 1]) {
          await t.test(`${theme} compact boundary rows${count} delta${delta}`, async () => {
            await visit({ width: 960, height: 800 }, theme, count);
            // Bracket the independently measured intrinsic minimum, including fractional text heights.
            await contentHeight(compactMinimum(count) + 86 + delta);
            await checkScopeAndReachability(count, delta < 0);
          });
        }
      }
      for (const count of [0, 10]) {
        await t.test(`${theme} full-page resize round trip rows${count}`, async () => {
          await visit({ width: 1280, height: 800 }, theme, count);
          const before = await geometry(page);
          const names = await page.locator('.recent-folder .row-text').allTextContents();
          await contentHeight(200);
          await checkScopeAndReachability(count, true);
          await contentHeight(800 - 38);
          const restored = await geometry(page);
          for (const key of ['icon', 'heading', 'group', 'button'])
            assert.deepEqual(restored[key], before[key], `${key} full-page resize restoration`);
          assert.deepEqual(await page.locator('.recent-folder .row-text').allTextContents(), names, 'row identities conserved');
          await settle(page);
          const repeated = await geometry(page);
          for (const key of ['icon', 'heading', 'group', 'button'])
            assert.deepEqual(repeated[key], restored[key], `${key} repeated layout idempotent`);
          await contentHeight(200);
          await checkScopeAndReachability(count, true);
        });
      }
    }
  } finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
  }
});
