const PREFIX = 'Linux-Preflight (supplementary; GitHub required checks remain binding):';
const FACTS = ['distro', 'kernel', 'sh_target', 'node', 'git', 'python3', 'zsh', 'procps'];
const COUNTS = ['tests', 'pass', 'fail', 'skip', 'todo', 'cancelled'];

export function blankSummary(head, workflow, outcome = 'NOT VERIFIED', reason = '') {
  return {
    head, workflow_sha256: workflow.workflowSha256, steps_total: workflow.steps.length,
    steps_run: 0, outcome, reason, secs: '0.0', peak_rss_kb: 'unknown',
    facts: Object.fromEntries(FACTS.map(key => [key, 'unknown'])),
    steps: workflow.steps.map(step => ({ name: step.name,
      kind: step.kind === 'checkout' ? 'bundle-checked' : step.kind === 'setup-node' || step.kind === 'provision' ? 'provision-checked' : 'not-run',
      exit: step.kind === 'run' ? 'not-run' : '0', secs: '0.0', peak_rss_kb: 'unknown',
      tests: 0, pass: 0, fail: 0, skip: 0, todo: 0, cancelled: 0,
      tap_footer: 'not-applicable', python_tests: 0, python_result: 'unknown' })),
    failed: [],
  };
}

export function serializeSummary(summary) {
  const lines = [
    `head=${summary.head}`, `workflow_sha256=${summary.workflow_sha256}`,
    `steps_total=${summary.steps_total}`, `steps_run=${summary.steps_run}`,
    `outcome=${summary.outcome}`,
  ];
  if (summary.reason) lines.push(`reason=${clean(summary.reason)}`);
  lines.push(`secs=${summary.secs}`, `peak_rss_kb=${summary.peak_rss_kb}`);
  for (const key of FACTS) lines.push(`${key}=${clean(summary.facts[key] ?? 'unknown')}`);
  for (const step of summary.steps) {
    const prefix = `step:${step.name}`;
    lines.push(`${prefix}=${step.kind}`);
    for (const key of ['exit', 'secs', 'peak_rss_kb', ...COUNTS, 'tap_footer', 'python_tests', 'python_result']) lines.push(`${prefix}:${key}=${step[key]}`);
  }
  for (const name of summary.failed) lines.push(`failed:${clean(name)}`);
  lines.push('DONE');
  return `${lines.join('\n')}\n`;
}

function clean(value) { return String(value).replace(/[\r\n]/g, ' ').trim(); }

export function checkSummary(raw, expectedHead, workflow) {
  if (!/^[a-f0-9]{40}$/.test(expectedHead)) throw Error('expected full head SHA');
  const lines = raw.split(/\r?\n/);
  if (lines.at(-1) === '') lines.pop();
  if (lines.at(-1) !== 'DONE' || lines.filter(line => line === 'DONE').length !== 1) throw Error('summary missing or duplicate DONE');
  const fields = new Map();
  const failed = [];
  for (const line of lines.slice(0, -1)) {
    if (line.startsWith('failed:')) { failed.push(line.slice(7)); continue; }
    const index = line.indexOf('=');
    if (index < 1) throw Error(`invalid summary line ${line}`);
    const key = line.slice(0, index);
    if (fields.has(key)) throw Error(`duplicate summary key ${key}`);
    fields.set(key, line.slice(index + 1));
  }
  const inventory = lines.filter(line => /^step:[^:=]+=/.test(line)).map(line => line.slice(5, line.indexOf('=')));
  if (inventory.length !== workflow.steps.length || inventory.some((name, index) => name !== workflow.steps[index].name)) throw Error('step inventory order mismatch');
  function requireField(key) { if (!fields.has(key)) throw Error(`missing ${key}`); return fields.get(key); }
  if (requireField('head') !== expectedHead) throw Error('summary head mismatch');
  if (requireField('workflow_sha256') !== workflow.workflowSha256) throw Error('workflow hash mismatch');
  if (Number(requireField('steps_total')) !== workflow.steps.length) throw Error('step inventory length mismatch');
  const outcome = requireField('outcome');
  if (!['PASS', 'FAIL', 'TIMEOUT', 'NOT VERIFIED'].includes(outcome)) throw Error('invalid outcome');
  if (outcome === 'NOT VERIFIED' && !requireField('reason')) throw Error('missing reason');
  for (const key of ['secs', 'peak_rss_kb']) validateMetric(requireField(key), key);
  for (const key of FACTS) requireField(key);
  let runCount = 0;
  let total = 0; let pass = 0; let fail = 0; let skip = 0; let todo = 0; let cancelled = 0;
  let accountingIssue = null;
  let badStep = null; let timeoutStep = null;
  for (const step of workflow.steps) {
    const prefix = `step:${step.name}`;
    const kind = requireField(prefix);
    const expectedKind = step.kind === 'checkout' ? 'bundle-checked' : step.kind === 'run' ? null : 'provision-checked';
    if (expectedKind && kind !== expectedKind || !expectedKind && !['run', 'not-run'].includes(kind)) throw Error(`invalid step inventory ${step.name}`);
    const exit = requireField(`${prefix}:exit`);
    if (kind === 'run') {
      if (!/^\d+$/.test(exit)) throw Error(`invalid exit ${step.name}`);
      runCount++;
      if (Number(exit) !== 0) badStep ??= step.name;
      if ([124, 137].includes(Number(exit))) timeoutStep ??= step.name;
    } else if (kind === 'not-run') {
      if (exit !== 'not-run') throw Error(`invalid not-run exit ${step.name}`);
    } else if (exit !== '0') throw Error(`invalid mapped exit ${step.name}`);
    validateMetric(requireField(`${prefix}:secs`), `${prefix}:secs`);
    validateMetric(requireField(`${prefix}:peak_rss_kb`), `${prefix}:peak_rss_kb`);
    for (const key of COUNTS) {
      const value = requireField(`${prefix}:${key}`);
      if (!/^\d+$/.test(value)) throw Error(`invalid ${prefix}:${key}`);
    }
    const tapFooter = requireField(`${prefix}:tap_footer`);
    if (!['complete', 'missing', 'not-applicable'].includes(tapFooter)) throw Error(`invalid TAP footer ${step.name}`);
    const pyTests = requireField(`${prefix}:python_tests`);
    if (!/^\d+$/.test(pyTests)) throw Error(`invalid python tests ${step.name}`);
    const pyResult = requireField(`${prefix}:python_result`);
    if (!['OK', 'FAILED', 'unknown'].includes(pyResult)) throw Error(`invalid python result ${step.name}`);
    if (kind === 'run' && exit === '0') {
      if (step.run.includes('python3 -m unittest') && (Number(pyTests) === 0 || pyResult === 'unknown')) throw Error(`missing Python unittest totals ${step.name}`);
      if (Number(fields.get(`${prefix}:tests`)) === 0 || tapFooter !== 'complete') accountingIssue ??= `missing Node TAP totals ${step.name}`;
      if (Number(fields.get(`${prefix}:tests`)) > 0 && tapFooter !== 'complete') accountingIssue ??= `incomplete TAP footer ${step.name}`;
      if (Number(fields.get(`${prefix}:pass`)) + Number(fields.get(`${prefix}:fail`)) + Number(fields.get(`${prefix}:skip`)) + Number(fields.get(`${prefix}:todo`)) + Number(fields.get(`${prefix}:cancelled`)) !== Number(fields.get(`${prefix}:tests`))) accountingIssue ??= `TAP totals mismatch ${step.name}`;
    }
    total += Number(fields.get(`${prefix}:tests`));
    pass += Number(fields.get(`${prefix}:pass`));
    fail += Number(fields.get(`${prefix}:fail`));
    skip += Number(fields.get(`${prefix}:skip`));
    todo += Number(fields.get(`${prefix}:todo`));
    cancelled += Number(fields.get(`${prefix}:cancelled`));
  }
  if (Number(requireField('steps_run')) !== runCount) throw Error('steps_run mismatch');
  if (accountingIssue && outcome !== 'NOT VERIFIED' && outcome !== 'TIMEOUT') throw Error(accountingIssue);
  if (outcome === 'PASS' && (runCount !== workflow.steps.filter(step => step.kind === 'run').length || badStep || fail || cancelled || !total)) throw Error('inconsistent PASS');
  if (outcome === 'FAIL' && !badStep && !fail && !cancelled) throw Error('inconsistent FAIL');
  if (outcome === 'TIMEOUT' && !timeoutStep && requireField('reason') !== 'whole run deadline reached') throw Error('inconsistent TIMEOUT');
  const counts = `${pass}/${total} (${skip} skip${todo ? `, ${todo} todo` : ''})`;
  const detail = outcome === 'PASS' ? counts :
    outcome === 'NOT VERIFIED' ? clean(requireField('reason')) :
    `${outcome === 'TIMEOUT' ? timeoutStep ?? requireField('reason') : badStep ?? failed[0] ?? 'test failure'}; ${counts}`;
  return `${PREFIX} ${expectedHead.slice(0, 7)} agent-tooling ${outcome} ${detail}`;
}

function validateMetric(value, key) {
  const pattern = key.endsWith('secs') ? /^\d+(?:\.\d+)?$/ : /^(?:\d+|unknown)$/;
  if (!pattern.test(value)) throw Error(`invalid ${key}`);
}
