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
const save = () => fs.writeFileSync(statePath, JSON.stringify(state));
const event = value => state.events.push(value);
const show = name => process.stdout.write(fs.readFileSync(path.join(fixtureDir, `pane-${name}.txt`), 'utf8')
  .replaceAll('~/fixture-worktree', state.cwd.replace(os.homedir(), '~')));
state.cwd ??= path.join(os.homedir(), 'fixture-worktree');

switch (action) {
  case 'pane send-text':
    if (args[3] !== '/new') process.exit(91);
    event('send-new');
    state.phase = 'starting';
    state.reads = 0;
    if (scenario.lostName) state.name = 'codex';
    break;
  case 'pane send-keys':
    event(`key-${args[3]}`);
    if (args[3] === '1' && state.phase === 'dialog' && !scenario.ignoreOne) state.selectedOne = true;
    if (args[3]?.toLowerCase() === 'enter' && state.phase === 'dialog') {
      if (!state.selectedOne) state.cwd = path.join(os.homedir(), 'wrong-worktree');
      state.phase = 'empty';
    }
    break;
  case 'pane read':
    if (state.phase === 'starting') {
      state.reads++;
      if (state.reads >= (scenario.delayReads ?? 1)) state.phase = scenario.dialog ? 'dialog' : 'empty';
    }
    if (scenario.invalidUtf8) { process.stdout.write(Buffer.from([0xff])); break; }
    show(state.phase === 'old' ? 'old' : state.phase === 'starting' ? 'starting' : state.phase);
    break;
  case 'agent rename':
    event('agent-rename');
    if (!scenario.renameFails) state.name = args[3];
    break;
  case 'pane rename':
    event('pane-rename');
    break;
  case 'agent list':
    event('agent-list');
    process.stdout.write(JSON.stringify({ id: 'cli:agent:list', result: { type: 'agent_list', agents: [
      { agent: scenario.nonCodex ? 'claude' : 'codex', name: state.name, pane_id: 'w1:p5', agent_status: state.status, cwd: state.cwd },
      ...(scenario.duplicateName && state.name === 'gpt-auditor' ? [{ agent: 'codex', name: 'gpt-auditor', pane_id: 'w1:p6', agent_status: 'idle', cwd: state.cwd }] : [])
    ] } }) + '\n');
    break;
  case 'agent prompt':
    event('agent-prompt');
    const promptOffset = args[2] === '--' ? 1 : 0;
    if (args[2 + promptOffset] !== state.name) { process.stdout.write('not_found\n'); save(); process.exit(1); }
    if (args[3 + promptOffset]?.startsWith('-') && !promptOffset) { process.stderr.write('option-like prompt\n'); save(); process.exit(2); }
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
