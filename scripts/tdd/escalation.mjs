/** Startup-budget escalation for supervisor fixtures (#705).
 *
 * In the app-lane discovery fixtures one budget does two jobs: it is the
 * timeout under test, and it has to outlast the startup of node, python3 and
 * ps before the fixture's native task exists. Startup takes ~0.3 s on a quiet
 * machine and several times that under load, so no single number does both.
 *
 * runEscalating runs the attempt with the short budget first and repeats it at
 * 4×, 16× and 64× only when the attempt proved nothing: no PID evidence that
 * the fixture started, and the supervisor reported an execution timeout. Any
 * other outcome decides at once: a pass, a failure with evidence, a failure
 * without a timeout, or a thrown assertion. Proving nothing at 64× fails.
 *
 * Stop bounds are measured from the event that starts the stop (a signal, a
 * kill, admission plus budget), never from the test's spawn call, so startup
 * latency cannot push a correct run past its bound. */
import { publishedPID, publishedPIDList } from './fixture-pid.mjs';

export const STARTUP_FACTORS = [1, 4, 16, 64];

/** Whether an attempt's result says nothing about the behaviour under test. */
export function provedNothing(result) {
  return result.verdict !== 'pass' && !result.evidence && Boolean(result.executionTimeout);
}

/** Run attempt(budgetMs, {last}) with escalating budgets; see the module comment. */
export async function runEscalating(attempt, { baseMs, factors = STARTUP_FACTORS } = {}) {
  const budgets = [];
  for (const [index, factor] of factors.entries()) {
    const budget = baseMs * factor;
    budgets.push(budget);
    const result = await attempt(budget, { last: index === factors.length - 1 });
    if (!provedNothing(result)) return { ...result, budgets };
  }
  return { verdict: 'fail', evidence: false, executionTimeout: true, budgets,
    reason: `fixture proved nothing at ${factors.at(-1)}× (${budgets.at(-1)} ms): it never started before its budget expired` };
}

/** Whether exitedAt falls strictly within boundMs of eventAt (both real times, in order). */
export function withinBound(eventAt, exitedAt, boundMs) {
  return Number.isFinite(eventAt) && Number.isFinite(exitedAt) && eventAt > 0 && exitedAt >= eventAt && exitedAt - eventAt < boundMs;
}

/** PID evidence (a complete published PID or non-empty PID list) and whether stderr reports an execution timeout. */
export function attemptFacts({ pidFiles = [], listFiles = [], stderr = '' } = {}) {
  const evidence = pidFiles.some(file => publishedPID(file) !== null) || listFiles.some(file => (publishedPIDList(file) ?? []).length > 0);
  return { evidence, executionTimeout: /execution timeout/.test(stderr) };
}
