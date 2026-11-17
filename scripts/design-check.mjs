#!/usr/bin/env node
// npm run design:check — check shortcuts.html against the command model (scripts/design/shortcut-model.mjs), serve
// design/ and states/ on two local ports, then run scripts/verify_design_catalog.js in headless Chromium (Playwright
// pinned in package-lock.json). Exits 1 when the check fails, 2 when it cannot start.
// Ports: PICSEE_DESIGN_PORT and PICSEE_STATES_PORT, default a free port chosen at listen time. MADO_DESIGN_SCREENSHOT
// sets the preview screenshot path, default a temporary directory (never the repo).
// The servers run in this process, not `python3 -m http.server`: that server resolves the bind address with
// socket.getfqdn() between bind() and listen(), a reverse-DNS lookup that left the port closed for 15 s on a macOS
// GitHub runner (run 40630233760). Listening here has no DNS step, no child process and no probe-then-bind port race.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const check = require('./verify_design_catalog.js');
const { check: checkShortcuts } = await import('./design/shortcut-model.mjs');

const portFrom = name => {
  const value = process.env[name];
  if (!value) return 0;
  if (!/^\d+$/.test(value) || +value < 1 || +value > 65535) throw Error(`${name} must be a port number, got ${value}`);
  return +value;
};

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
  '.svg': 'image/svg+xml', '.md': 'text/markdown', '.txt': 'text/plain',
};

// Static files like http.server: a directory URL without its slash redirects, with it serves index.html.
function respond(base, request, response) {
  const send = (code, headers = {}) => { response.writeHead(code, headers); response.end(); };
  if (request.method !== 'GET' && request.method !== 'HEAD') return send(405);
  const { pathname } = new URL(request.url, 'http://127.0.0.1');
  let urlPath;
  try { urlPath = decodeURIComponent(pathname); } catch { return send(400); }
  let file = path.join(base, urlPath);
  if (file !== base && !file.startsWith(base + path.sep)) return send(404);
  fs.stat(file, function sendFile(error, stat) {
    if (error) return send(404);
    if (stat.isDirectory()) {
      if (!urlPath.endsWith('/')) return send(301, { Location: pathname + '/' });
      if (file.endsWith('index.html')) return send(404);
      file = path.join(file, 'index.html');
      return fs.stat(file, sendFile);
    }
    response.writeHead(200, { 'Content-Type': types[path.extname(file).toLowerCase()] || 'application/octet-stream',
      'Content-Length': stat.size });
    if (request.method === 'HEAD') return response.end();
    fs.createReadStream(file).on('error', () => response.destroy()).pipe(response);
  });
}

const servers = [];
function serve(directory, port) {
  const base = path.join(root, directory);
  const server = http.createServer((request, response) => respond(base, request, response));
  servers.push(server);
  return new Promise((resolve, reject) => {
    server.once('error', error => reject(Error(`server for ${directory} could not listen on port ${port}: ${error.message}`)));
    server.listen(port, '127.0.0.1', () => resolve(`http://127.0.0.1:${server.address().port}`));
  });
}

let status = 0, browser;
try {
  const { chromium } = await import('playwright');
  const design = await serve('design', portFrom('PICSEE_DESIGN_PORT'));
  const states = await serve('design/prototypes/picsee-browser/states', portFrom('PICSEE_STATES_PORT'));
  const screenshot = process.env.MADO_DESIGN_SCREENSHOT
    || path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'picsee-design-check-')), 'design-material-preview.png');
  browser = await chromium.launch();
  const page = await browser.newPage();
  try {
    // shortcuts.html must list exactly the shortcuts the command model implements (#214).
    const shortcutProblems = checkShortcuts();
    if (shortcutProblems.length) throw Error('shortcuts.html and the command model disagree: ' + shortcutProblems.join(' | '));
    const result = await check(page, { design, states, screenshot });
    console.log(JSON.stringify({ ...result, results: undefined }, null, 1));
    console.log(`design:check PASS (${result.stateCount} states, ${result.hashesPinned} hashes, ${result.subcases} sub-cases, ${result.branchPlays} branch plays)`);
  } catch (error) {
    console.error(`design:check FAIL: ${error.message}`);
    status = 1;
  }
} catch (error) {
  console.error(`design:check could not start: ${error.message}`);
  status = 2;
} finally {
  if (browser) await browser.close();
  for (const server of servers) server.close();
}
process.exit(status);
