#!/usr/bin/env node
// Offline herdr adapter: emits saved pane snapshots and the documented agent-list envelope.
const fs = require('node:fs');
const path = require('node:path');
const scenario = JSON.parse(process.env.MADO_FIXTURE_SCENARIO);
const statePath = process.env.MADO_FIXTURE_STATE;
const fixtureDir = process.env.MADO_FIXTURE_DIR;
const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
const args = process.argv.slice(2);
const action = args.slice(0, 2).join(' ');
const save = () => fs.writeFileSync(statePath, JSON.stringify(state));
const event = value => state.events.push(value);
const show = name => process.stdout.write(fs.readFileSync(path.join(fixtureDir, `pane-${name}.txt`), 'utf8'));

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
    if (args[3] === '1' && state.phase === 'dialog') state.selectedOne = true;
    if (args[3]?.toLowerCase() === 'enter' && state.phase === 'dialog' && state.selectedOne) state.phase = 'empty';
    break;
  case 'pane read':
    if (state.phase === 'starting') {
      state.reads++;
      if (state.reads >= (scenario.delayReads ?? 1)) state.phase = scenario.dialog ? 'dialog' : 'empty';
    }
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
      { agent: 'codex', name: state.name, pane_id: 'w1:p5', agent_status: state.status }
    ] } }) + '\n');
    break;
  case 'agent prompt':
    event('agent-prompt');
    if (args[2] !== state.name) { process.stdout.write('not_found\n'); save(); process.exit(1); }
    state.prompts++;
    if (scenario.lateDialog && state.prompts === 1) state.phase = 'dialog';
    else if (!scenario.neverStarts && (!scenario.swallowFirst || state.prompts > 1)) state.status = 'working';
    process.stdout.write('agent_prompted\n');
    break;
  default:
    process.stderr.write(`unsupported fake herdr command: ${args.join(' ')}\n`);
    process.exit(90);
}
save();
