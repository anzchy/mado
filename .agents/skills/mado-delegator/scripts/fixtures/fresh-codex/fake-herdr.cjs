#!/usr/bin/env node
// Offline herdr adapter: emits saved pane snapshots and the documented agent-list envelope.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const scenario = JSON.parse(process.env.MADO_FIXTURE_SCENARIO);
const statePath = process.env.MADO_FIXTURE_STATE;
const fixtureDir = process.env.MADO_FIXTURE_DIR;
const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
const args = process.argv.slice(2);
const action = args.slice(0, 2).join(' ');
// Reject malformed invocations before mutating the simulated pane, as the CLI does.
const invalid = () => { process.stderr.write(`herdr: invalid option-like positional ${args.find(a => a.startsWith('-')) ?? 'arguments'}\n`); process.exit(2); };
const positional = (count, options = false) => {
  if (args.length !== count || args.slice(2).some(a => a === '--' || (a.startsWith('-') && !options))) invalid();
};
const save = () => fs.writeFileSync(statePath, JSON.stringify(state));
const event = value => state.events.push(value);
const show = name => process.stdout.write(fs.readFileSync(path.join(fixtureDir, `pane-${name}.txt`), 'utf8')
  .replaceAll('~/fixture-worktree', state.cwd.replace(os.homedir(), '~'))
  .replaceAll('~/Documents/mac-app/picsee-wt/gpt-imple-1', state.cwd.replace(os.homedir(), '~')));
state.cwd ??= path.join(os.homedir(), 'fixture-worktree');

switch (action) {
  case 'pane send-text':
    positional(4);
    if (args[3] !== '/new') process.exit(91);
    event('send-new');
    state.phase = scenario.popup ? 'popup' : 'starting';
    state.reads = 0;
    state.enters = 0;
    if (scenario.lostName) state.name = 'codex';
    break;
  case 'pane send-keys':
    positional(4);
    const wasStarting = state.phase === 'starting';
    event(`key-${args[3]}`);
    if (args[3]?.toLowerCase() === 'enter' && state.phase === 'starting') {
      state.enters++;
      if ((scenario.delayReads ?? 1) <= 1) state.phase = scenario.dialog ? 'dialog' : 'empty';
    }
    if (args[3] === 'ctrl+u' && state.phase === 'popup') state.phase = 'cleared';
    if (args[3]?.toLowerCase() === 'enter' && state.phase === 'popup') {
      state.enters++;
      if (!scenario.stuckPopup && state.enters >= (scenario.swallowNewEnter ? 2 : 1)) state.phase = scenario.dialog ? 'dialog' : 'empty';
    }
    if (args[3] === '1' && state.phase === 'dialog' && !scenario.ignoreOne) state.selectedOne = true;
    if (args[3]?.toLowerCase() === 'enter' && state.phase === 'dialog' && !wasStarting) {
      if (!state.selectedOne) state.cwd = path.join(os.homedir(), 'wrong-worktree');
      state.phase = 'empty';
    }
    break;
  case 'pane read':
    if (state.phase === 'starting') {
      state.reads++;
      if (state.enters && state.reads >= (scenario.delayReads ?? 1)) state.phase = scenario.dialog ? 'dialog' : 'empty';
    }
    if (scenario.invalidUtf8) { process.stdout.write(Buffer.from([0xff])); break; }
    show(state.phase === 'old' ? (scenario.realIdle ? 'real-idle' : 'old') : state.phase === 'starting' ? 'starting' : state.phase === 'cleared' ? 'old' : state.phase === 'empty' && scenario.realIdle ? 'real-idle' : state.phase);
    break;
  case 'agent rename':
    positional(4);
    event('agent-rename');
    if (!scenario.renameFails) state.name = args[3];
    break;
  case 'pane rename':
    positional(4);
    event('pane-rename');
    break;
  case 'agent list':
    positional(2);
    event('agent-list');
    process.stdout.write(JSON.stringify({ id: 'cli:agent:list', result: { type: 'agent_list', agents: [
      { agent: scenario.nonCodex ? 'claude' : 'codex', name: state.name, pane_id: 'w1:p5', agent_status: state.status, cwd: state.cwd },
      ...(scenario.duplicateName && state.name === 'gpt-auditor' ? [{ agent: 'codex', name: 'gpt-auditor', pane_id: 'w1:p6', agent_status: 'idle', cwd: state.cwd }] : [])
    ] } }) + '\n');
    break;
  case 'agent prompt':
    positional(4);
    event('agent-prompt');
    if (args[2] !== state.name) { process.stdout.write('not_found\n'); save(); process.exit(1); }
    state.prompts++;
    if (scenario.lateDialog && state.prompts === 1) state.phase = 'dialog';
    else if (scenario.acceptedSlow) state.phase = 'submitted';
    else if (!scenario.neverStarts && (!scenario.swallowFirst || state.prompts > 1)) state.status = 'working';
    process.stdout.write('agent_prompted\n');
    break;
  default:
    process.stderr.write(`unsupported fake herdr command: ${args.join(' ')}\n`);
    process.exit(90);
}
save();
