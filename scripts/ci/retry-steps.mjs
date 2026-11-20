// #788 item 3, i788a-fix1: retry.sh and Acquire::Retries are allowed only in these install steps, each with exactly this
// text, so a retry can never wrap a test or assertion (scripts/ci/retry.test.mjs runs the check over every workflow).
export const RETRY_STEPS = Object.freeze({
  'ci.yml\u0000Install Playwright Chromium': [
    '      - name: Install Playwright Chromium',
    '        run: |',
    `          echo 'Acquire::Retries "3";' | sudo tee /etc/apt/apt.conf.d/80-mado-retries`,
    '          scripts/ci/retry.sh 3 20 npx playwright install --with-deps chromium',
  ].join('\n') + '\n',
  'pr-body.yml\u0000Install portable device test tools': [
    '      - name: Install portable device test tools',
    '        run: |',
    "          if command -v python3 >/dev/null && command -v git >/dev/null && command -v zsh >/dev/null; then echo 'install: python3, git and zsh already present'; exit 0; fi",
    '          pr-head/scripts/ci/retry.sh 3 15 sudo apt-get -o Acquire::Retries=3 update',
    '          pr-head/scripts/ci/retry.sh 3 15 sudo apt-get -o Acquire::Retries=3 install --no-install-recommends -y python3 git zsh',
  ].join('\n') + '\n',
});

/// Every step of a workflow: a step starts at a `      - ` list item (named or not) and runs until the next line indented
/// six spaces or less. Comment lines are not step text. `name` is the step's own `name:` key, or null.
export function workflowSteps(text) {
  const steps = [];
  let current = null;
  const close = () => {
    if (!current) return;
    while (current.lines.length && !current.lines.at(-1).trim()) current.lines.pop();
    const first = current.lines[0].slice(8), own = current.lines.slice(1).find(line => /^ {8}name: /.test(line));
    const name = first.startsWith('name: ') ? first.slice(6) : own ? own.slice(14) : null;
    steps.push({ name, text: current.lines.join('\n') + '\n' });
    current = null;
  };
  for (const line of text.split('\n')) {
    if (line.trim().startsWith('#')) continue;
    if (/^ {6}- /.test(line)) { close(); current = { lines: [line] }; continue; }
    if (current && (!line.trim() || /^ {7}/.test(line))) { current.lines.push(line); continue; }
    close();
  }
  close();
  return steps;
}

/// Violations over { fileName: text }: a retrying step that is not allowlisted, an allowlisted step whose text differs
/// from its pin, or an allowlisted step that is missing or appears more than once.
export function retryStepViolations(files) {
  const violations = [], seen = new Map();
  for (const [file, text] of Object.entries(files)) for (const step of workflowSteps(text)) {
    if (!/retry\.sh|Acquire::Retries/.test(step.text)) continue;
    const key = `${file}\u0000${step.name}`;
    if (!(key in RETRY_STEPS)) { violations.push(`${file}: step ${step.name ?? '(unnamed)'} retries but is not an allowlisted install step`); continue; }
    seen.set(key, (seen.get(key) ?? 0) + 1);
    if (step.text !== RETRY_STEPS[key]) violations.push(`${file}: step ${step.name} differs from its pinned install command`);
  }
  for (const key of Object.keys(RETRY_STEPS)) if (seen.get(key) !== 1) violations.push(`${key.replace('\u0000', ': step ')} found ${seen.get(key) ?? 0} times`);
  return violations;
}
