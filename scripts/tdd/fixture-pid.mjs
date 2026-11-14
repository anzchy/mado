/** PID publication for test fixtures (#705).
 *
 * A fixture child publishes its PID for the test to observe and clean up. A
 * plain writeFileSync truncates before it writes, so a polling reader can see
 * '' or a prefix; Number('') is 0, and process.kill(0, …) signals the test
 * runner's own process group. Writers therefore publish through a temporary
 * file and rename (atomic on one filesystem), readers accept only a complete
 * positive integer, and every signal goes through safeKill, which refuses
 * anything else before process.kill is reached.
 *
 * Newline manifests are shared by several writers, so they stay
 * append-only (one write(2) of "<pid>\n" per writer); the reader ignores an
 * unterminated last line and rejects the manifest if a complete line is not a
 * PID. */
import { readFileSync } from 'node:fs';

const MAX_PID = 2147483647;
const isPID = value => Number.isInteger(value) && value > 0 && value <= MAX_PID;
const parsePID = text => /^[1-9][0-9]*$/.test(text) && Number(text) <= MAX_PID ? Number(text) : null;
const read = file => { try { return readFileSync(file, 'utf8'); } catch { return null; } };

/** The PID in `file`, or null unless it holds exactly one positive integer. */
export function publishedPID(file) {
  const text = read(file);
  return text === null ? null : parsePID(text.trim());
}

/** The PIDs of a JSON array manifest, or null unless it is complete and every entry is a PID. */
export function publishedPIDList(file) {
  const text = read(file);
  if (text === null) return null;
  let value;
  try { value = JSON.parse(text); } catch { return null; }
  return Array.isArray(value) && value.every(isPID) ? value : null;
}

/** The PIDs on the complete lines of an append-only manifest, or null if one is not a PID. */
export function publishedPIDLines(file) {
  const text = read(file);
  if (text === null) return null;
  const lines = text.split('\n').slice(0, -1);
  const pids = lines.map(parsePID);
  return pids.every(pid => pid !== null) ? pids : null;
}

const renameSource = (file, data) =>
  `{const f=require('node:fs'),p=${JSON.stringify(file)},t=p+'.'+process.pid+'.tmp';f.writeFileSync(t,${data});f.renameSync(t,p);}`;
/** CommonJS source that atomically publishes String(expression) to `file`. */
export function publishSource(file, expression = 'process.pid') { return renameSource(file, `String(${expression})`); }
/** CommonJS source that atomically publishes JSON.stringify(expression) to `file`. */
export function publishListSource(file, expression) { return renameSource(file, `JSON.stringify(${expression})`); }

/** Signal `pid` (its group when `group`); false without signalling for a non-PID, false on ESRCH. */
export function safeKill(pid, signal = 'SIGKILL', { group = false } = {}) {
  if (!isPID(pid)) return false;
  try { process.kill(group ? -pid : pid, signal); return true; }
  catch (error) { if (error.code === 'ESRCH') return false; throw error; }
}

/** Whether `pid` names a live process; never probes 0 or a non-PID. */
export function pidAlive(pid) {
  if (!isPID(pid)) return false;
  try { process.kill(pid, 0); return true; }
  catch (error) { if (error.code === 'ESRCH') return false; throw error; }
}
