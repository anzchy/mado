// Runs in design:check, including shallow CI checkouts; no git history is required.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright';
import { readFileSync, mkdirSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';

const base = 'design/prototypes/picsee-browser/states/';

async function snapshot(page) {
  return page.evaluate(() => {
    const styles = (element, pseudo) => {
      const style = getComputedStyle(element, pseudo);
      return Object.fromEntries([...style]
        .filter(key => !key.startsWith('--'))
        .map(key => [key, style.getPropertyValue(key)]));
    };
    return {
      protected: [...document.querySelectorAll('.inspector, .c-filmstrip')].map(element => ({
        html: element.outerHTML,
        styles: [element, ...element.querySelectorAll('*')].map(node => styles(node)),
      })),
      foreground: [...document.querySelectorAll(
        '[data-viewer-controls] .ds-icon-button, [data-viewer-controls] svg, '
        + '[data-viewer-controls] .viewer-file-label, [data-viewer-controls] .viewer-file-label > *, '
        + '[data-viewer-controls] .zoom-label',
      )].map(element => styles(element)),
      pods: [...document.querySelectorAll('.viewer-floating-controls > [data-viewer-controls]')]
        .map(element => {
          const style = getComputedStyle(element);
          const backing = getComputedStyle(element, '::before');
          return {
            kind: element.dataset.viewerControls,
            background: style.backgroundColor,
            blur: style.backdropFilter,
            radius: style.borderRadius,
            shadow: style.boxShadow,
            backing: {
              inset: backing.inset,
              radius: backing.borderRadius,
              background: backing.backgroundColor,
            },
          };
        }),
    };
  });
}

async function material(page, percentage, theme) {
  return page.evaluate(({ percentage, theme }) => {
    const probe = document.createElement('i');
    const panel = theme === 'light' ? '#ffffff' : '#141821';
    probe.style.backgroundColor = `color-mix(in srgb, ${panel} ${percentage}%, transparent)`;
    probe.style.boxShadow = 'var(--shadow-soft)';
    document.body.append(probe);
    const style = getComputedStyle(probe);
    const result = { background: style.backgroundColor, shadow: style.boxShadow };
    probe.remove();
    return result;
  }, { percentage, theme });
}

test('#540 tools material variants preserve inspector, filmstrip, backing and foreground', async () => {
  const serverErrors = [];
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, 'http://localhost');
    const file = path.join(base, url.pathname);
    try {
      const bytes = readFileSync(file);
      response.setHeader('Content-Type', file.endsWith('.html') ? 'text/html'
        : file.endsWith('.jpg') ? 'image/jpeg' : 'application/octet-stream');
      response.end(bytes);
    } catch (error) {
      serverErrors.push(`${file}: ${error.stack}`);
      response.writeHead(500);
      response.end(`Design fixture read failed: ${file}`);
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const visit = async url => {
      const response = await page.goto(url);
      assert.deepEqual(serverErrors, [], 'fixture server read errors');
      assert.equal(response.status(), 200, url);
    };
    for (const file of ['viewer-controls', 'viewer-inspector', 'viewer-filmstrip']) {
      for (const theme of ['light', 'dark']) {
        const url = `http://127.0.0.1:${server.address().port}/${file}.html?theme=${theme}`;
        await visit(url);
        const original = await snapshot(page);
        assert.equal(original.protected.length, file === 'viewer-controls' ? 0 : 1);
        assert.ok(original.foreground.length > 0);
        const backingMaterial = await material(page, 50, theme);
        for (const opacity of ['30', '50', '100', 'default', 'invalid']) {
          await visit(url + (opacity === 'default' ? '' : `&tool-opacity=${opacity}`));
          const actual = await snapshot(page);
          const label = `${file} ${theme} ${opacity}`;
          assert.deepEqual(actual.protected, original.protected, `${label} protected surfaces`);
          assert.deepEqual(actual.foreground, original.foreground, `${label} foreground`);
          assert.equal(actual.pods.length, file === 'viewer-filmstrip' ? 2 : 3);
          const percentage = ['30', '100'].includes(opacity) ? +opacity : 50;
          const expected = await material(page, percentage, theme);
          for (const pod of actual.pods) {
            assert.equal(pod.background, expected.background, `${label} ${pod.kind} alpha`);
            assert.equal(pod.blur, 'blur(20px) saturate(1.6)');
            assert.equal(pod.radius, '6px');
            assert.equal(pod.shadow, expected.shadow);
            assert.deepEqual(pod.backing, {
              inset: '2px', radius: '4px', background: backingMaterial.background,
            }, `${label} ${pod.kind} backing`);
          }
          if (process.env.I540_SCREENSHOTS && ['30', '50', '100'].includes(opacity)) {
            mkdirSync(process.env.I540_SCREENSHOTS, { recursive: true });
            await page.screenshot({
              path: path.join(process.env.I540_SCREENSHOTS, `${file}-${theme}-${opacity}.png`),
            });
          }
        }
      }
    }
    assert.deepEqual(serverErrors, [], 'fixture server read errors');
  } finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
  }
});
