/**
 * Swift receipt adapter, adapted from mdpro scripts/cargo-test-lane.mjs @9f133f1d.
 * Usage: node scripts/tdd/swift-lane.mjs [filter]
 * Or set PICSEE_SWIFT_FILTER for receipt.js record AND verify (env is inherited).
 * Always runs SwiftPM under the mado heavy lock. No filter => 64; no completed
 * tests / compile failure / inconsistent outcome => 70 (runner-error/environment).
 * Completed assertion failure => 1 plus Maven counts; pass => 0 plus counts.
 * Keeps raw-byte streaming, backpressure, per-stream decoding and signal relay
 * from the copied adapter. Require XCTest's root completion and Swift Testing's
 * completed run; cross-check terminal events against their framework totals.
 * Counts failing tests, not Swift Testing issues or repeated XCTest suites.
 * An xcodebuild/UI lane is intentionally not implemented yet.
 */
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { StringDecoder } from "node:string_decoder";
import { fileURLToPath, pathToFileURL } from "node:url";
const SIGNAL_EXIT_BASE = 128;
const FORWARDED_SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"];
// Diagnostic records only: test labels and assertion prose can discuss crashes.
// Runtime traps may prefix Fatal error with a Swift source location.
const CRASH_RECORDS = [
  /^error: Exited with signal code \d+\s*$/i,
  /^error: Process '[^'\r\n]+' exited with (?:unexpected )?signal code \d+\s*$/i,
  /^(?:[^:\r\n]+\.swift:\d+(?::\d+)?: )?Fatal error:(?: |$)/,
  /^Test (?:Case|Suite) '.+' crashed(?: \([^\r\n]*\))?\.?$/,
  /^✘ Test .+ crashed after \d+(?:\.\d+)? seconds(?: with \d+ issues?)?\.$/,
];

// Only completed summaries prove tests actually ran. Each stream is parsed
// independently so interleaved partial stdout/stderr cannot forge a summary.
function parseOutput(text) {
  const clean = text.replace(/\x1b\[[0-9;]*m/g, "").replace(/\r/g, "");
  const lines = clean.split("\n");
  const crash = lines.some(line => CRASH_RECORDS.some(record => record.test(line)));
  const stack = [];
  const cases = new Map();
  let xctStarted = false, rootPending = false, xct = null, invalid = crash;
  for (const line of lines) {
    const begin = /^Test Suite '(.+)' started at /.exec(line);
    const end = /^Test Suite '(.+)' (passed|failed) at /.exec(line);
    const summary = /^\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \(\d+ unexpected\)/.exec(line);
    if (begin) {
      if (!stack.length) {
        if (xctStarted || !/^(All tests|Selected tests)$|\.xctest$/.test(begin[1])) invalid = true;
        xctStarted = true;
      }
      stack.push(begin[1]);
    } else if (end) {
      if (stack.pop() !== end[1]) invalid = true;
      if (!stack.length) rootPending = true;
    } else if (summary && rootPending) {
      xct = {total:+summary[1], skipped:+(summary[2] || 0), failureEvents:+summary[3]};
      rootPending = false;
    }
    const event = /^Test Case '(.+)' (started\.|passed \(|failed \(|skipped \()/.exec(line);
    if (event) {
      const previous = cases.get(event[1]);
      if (event[2] === 'started.') {
        if (previous) invalid = true;
        cases.set(event[1], 'started');
      } else {
        if (previous !== 'started') invalid = true;
        cases.set(event[1], event[2].split(' ')[0]);
      }
    }
  }
  if (xctStarted && (!xct || stack.length || rootPending)) invalid = true;
  if (xct) {
    const statuses = [...cases.values()];
    // XCTest's root reports assertion failure events, not failed case count.
    // Emit failed cases only from stable terminal identities.
    xct.failed = statuses.filter(v => v === 'failed').length;
    if (statuses.length !== xct.total || statuses.includes('started') ||
        xct.failureEvents < xct.failed ||
        statuses.filter(v => v === 'skipped').length !== xct.skipped) invalid = true;
  }
  const swiftStarts = lines.filter(l => /^◇ Test run started\./.test(l)).length;
  const swiftSummaries = [...clean.matchAll(/^[✔✘━] Test run with (\d+) tests? in \d+ suites? (passed|failed) after .+ seconds(?:\.| with \d+ (?:known )?issues?(?: \(including \d+ known issues?\))?\.)$/gm)];
  let swift = null;
  if (swiftStarts || swiftSummaries.length) {
    if (swiftStarts !== 1 || swiftSummaries.length !== 1) invalid = true;
    else {
      // Normal verbosity omits stable identities for display-named tests. Count
      // terminal events, never unique labels; cross-check with the run's total.
      const total = +swiftSummaries[0][1];
      const failed = lines.filter(l => /^✘ Test (?!run with ).+ failed after /.test(l)).length;
      // A test whose only issues are known passes with a ━ marker.
      const passed = lines.filter(l => /^[✔━] Test (?!run with ).+ passed after /.test(l)).length;
      const skipped = lines.filter(l => /^➜ Test .+ skipped(?::| after |\.)/.test(l)).length;
      if (failed + passed + skipped !== total ||
          ((swiftSummaries[0][2] === 'failed') !== (failed > 0))) invalid = true;
      swift = {total, failed, skipped};
    }
  }
  const total = (xct?.total || 0) + (swift?.total || 0);
  const failed = (xct?.failed || 0) + (swift?.failed || 0);
  const skipped = (xct?.skipped || 0) + (swift?.skipped || 0);
  return {invalid, counts: !invalid && total > 0 && failed + skipped <= total ? {total, failed, skipped} : null};
}
function createDetector() {
  let text = "";
  return { push: chunk => { text += chunk; }, seen: () => parseOutput(text) };
}
/**
 * Write `src` through to `dest` as raw bytes, honouring backpressure, while a
 * per-stream decoder feeds `detector`. EOF ends the last line.
 * @param {import("node:stream").Readable} src
 * @param {NodeJS.WriteStream} dest
 * @param {ReturnType<typeof createDetector>} detector
 */
function pipeThrough(src, dest, detector) {
  const decoder = new StringDecoder("utf8");
  src.on("data", (/** @type {Buffer} */ chunk) => {
    detector.push(decoder.write(chunk));
    if (!dest.write(chunk)) {
      src.pause();
      dest.once("drain", () => src.resume());
    }
  });
  src.on("end", () => detector.push(`${decoder.end()}\n`));
}

/** Run `then` once everything already written to stdout and stderr is flushed. */
function afterDrain(then) {
  process.stdout.write("", () => process.stderr.write("", then));
}

/**
 * Die by `signal`, as the child did. The exit code is the fallback if the
 * signal does not terminate us.
 * @param {string} signal
 */
function reraise(signal) {
  const n = os.constants.signals[/** @type {NodeJS.Signals} */ (signal)] ?? 0;
  process.exitCode = SIGNAL_EXIT_BASE + n;
  process.kill(process.pid, /** @type {NodeJS.Signals} */ (signal));
}

/** argv is only a filter, never shell code or arbitrary runner arguments. */
function main(argv) {
  const filter = argv[0] ?? process.env.PICSEE_SWIFT_FILTER;
  if (argv.length > 1 || !filter?.trim()) {
    process.stderr.write("usage: node scripts/tdd/swift-lane.mjs [filter]; or set PICSEE_SWIFT_FILTER for record and verify\n");
    process.exitCode = 64;
    return;
  }
  const lock = fileURLToPath(new URL("../heavy-lock.sh", import.meta.url));
  const child = spawn(lock, ["swift", "test", "--package-path", "Packages/MadoKit", "--filter", filter], { stdio: ["inherit", "pipe", "pipe"] });
  const stdoutDetector = createDetector();
  const stderrDetector = createDetector();
  pipeThrough(child.stdout, process.stdout, stdoutDetector);
  pipeThrough(child.stderr, process.stderr, stderrDetector);
  const forwarders = FORWARDED_SIGNALS.map(sig => [sig, () => child.kill(sig)]);
  for (const [sig, handler] of forwarders) process.on(sig, handler);
  let settled = false;
  const settle = () => {
    settled = true;
    for (const [sig, handler] of forwarders) process.off(sig, handler);
  };
  child.on("error", error => {
    if (settled || child.pid !== undefined) return;
    settle();
    process.stderr.write(`swift-lane: ${error.message}\n`);
    process.exitCode = 127;
  });
  child.on("close", (code, signal) => {
    if (settled) return;
    settle();
    if (signal) { afterDrain(() => reraise(signal)); return; }
    const out = stdoutDetector.seen();
    const err = stderrDetector.seen();
    // SwiftPM writes complete test output to stdout. Accept stderr-only fixtures
    // too, but fail closed on two separate completed result streams.
    const counts = out.invalid || err.invalid || (out.counts && err.counts) ? null : out.counts || err.counts;
    if (!counts || (code !== 0 && code !== 1) || ((code === 0) !== (counts.failed === 0))) {
      process.stderr.write("swift-lane: no reliable completed test result; environment failure\n");
      process.exitCode = 70;
      return;
    }
    process.stdout.write(`\nswift-lane filter=${JSON.stringify(filter).slice(1, -1)}\nTests run: ${counts.total}, Failures: ${counts.failed}, Errors: 0, Skipped: ${counts.skipped}\n`);
    process.exitCode = code;
  });
}
if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) main(process.argv.slice(2));
