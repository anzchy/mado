/** Independent iteration telemetry. The heartbeat never waits for a ps subprocess. */
import { spawn } from 'node:child_process';
import path from 'node:path';

export function parsePsTargets(output, group, targetName = 'xctest') {
  const targets = [];
  const lines = output.trim().split('\n');
  if (!output.trim()) return { status: 'ps-malformed', targets };
  for (const line of lines) {
    const row = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+([\d:.\-]+)\s+(.+?)\s*$/.exec(line);
    if (!row || !row[4].includes(':')) return { status: 'ps-malformed', targets: [] };
    const [, pid, pgid, state, cpuTime, command] = row;
    if (Number(pgid) === group && Number(pid) > 0 && !state.startsWith('Z') && path.basename(command) === targetName)
      targets.push({ pid: Number(pid), state, cpuTime });
  }
  return { status: targets.length ? 'ok' : 'target-unavailable', targets };
}

export function startGroupObservation({ group, write, intervalMs = 250, targetName = 'xctest',
  probeCommand = '/bin/ps', probeArgs = ['-axo', 'pid=,pgid=,stat=,time=,comm='], probeTimeoutMs = 1000, spawnProbe = spawn, probeKillGraceMs = 250, probeDrainMs = 500 } = {}) {
  const monotonic = () => Number(process.hrtime.bigint()) / 1e6;
  const origin = monotonic();
  let previous = origin, lastSample = origin, sampleSequence = 0, active = null, stopped = false, stopping, retryAfter = origin, undrained = false;
  let latest = { status: 'target-unavailable', targets: [] };
  const emit = (event, fields = {}) => write({ event, wallUnixMs: Date.now(), monotonicMs: monotonic(), group, ...fields });
  const sample = () => {
    if (stopped || active || undrained || monotonic() < retryAfter) return;
    const id = ++sampleSequence, began = monotonic();
    emit('ps.begin', { sample: id });
    let child;
    try { child = spawnProbe(probeCommand, probeArgs, { stdio: ['ignore', 'pipe', 'ignore'] }); }
    catch {
      latest = { status: 'ps-error', targets: [] }; lastSample = monotonic();
      emit('ps.end', { sample: id, durationMs: lastSample - began, ...latest });
      return;
    }
    let output = '', overflow = false, cause, error = false, deadline, escalation, drain, completed = false;
    let resolveDone;
    const done = new Promise(resolve => { resolveDone = resolve; });
    const signal = name => { if (child.pid && child.exitCode === null && child.signalCode === null) child.kill(name); };
    const cancel = reason => {
      if (cause) return;
      cause = reason;
      signal('SIGTERM');
      escalation = setTimeout(() => {
        signal('SIGKILL');
        // close can remain absent even after KILL (for example a surviving pipe holder).
        // Stop waiting after a bounded drain, explicitly poison admission of later iterations.
        drain = setTimeout(() => complete(null, false), probeDrainMs);
      }, probeKillGraceMs);
    };
    active = { done, cancel };
    child.stdout.on('data', chunk => {
      if (completed) return;
      // A corrupted tool cannot grow the diagnostic output without bound.
      if (output.length + chunk.length > 2 * 1024 * 1024) { overflow = true; cancel('ps-output-limit'); }
      else output += chunk.toString();
    });
    child.on('error', () => { if (!completed) error = true; });
    deadline = setTimeout(() => cancel('ps-timeout'), probeTimeoutMs);
    const complete = (code, reaped = true) => {
      if (completed) return;
      completed = true;
      clearTimeout(deadline); clearTimeout(escalation); clearTimeout(drain);
      if (!reaped) {
        undrained = true;
        child.stdout.destroy();
        child.unref();
      }
      const ended = monotonic();
      latest = !reaped ? { status: 'ps-undrained', targets: [], reaped: false } : cause ? { status: cause, targets: [] } : error || code !== 0 || overflow
        ? { status: 'ps-error', targets: [] } : parsePsTargets(output, group, targetName);
      lastSample = ended;
      // Failed tools back off for a second rather than spawning at heartbeat frequency.
      retryAfter = ['ps-error', 'ps-malformed'].includes(latest.status) ? ended + 1000 : ended;
      emit('ps.end', { sample: id, durationMs: ended - began, ...latest });
      active = null;
      resolveDone();
    };
    child.once('close', code => complete(code));
  };
  const tick = () => {
    if (stopped) return;
    const now = monotonic();
    emit('heartbeat', { gapMs: now - previous, sampleAgeMs: now - lastSample,
      inFlight: active !== null, ...latest });
    previous = now;
    sample();
  };
  tick();
  const timer = setInterval(tick, intervalMs);
  return {
    stop() {
      if (stopping) return stopping;
      stopped = true; clearInterval(timer);
      const pending = active;
      pending?.cancel('ps-cancelled');
      stopping = (async () => {
        // Only the owned probe is signalled; close is the reap boundary before terminal output.
        if (pending) await pending.done;
        emit('stopped', { sampleAgeMs: monotonic() - lastSample, ...latest });
        return { drained: !undrained };
      })();
      return stopping;
    }
  };
}
