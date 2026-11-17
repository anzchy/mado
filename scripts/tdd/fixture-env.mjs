/** Environment for test fixtures that launch their own heavy-lock supervisors (#705).
 *
 * When the test runner is itself a heavy-lock job (`scripts/heavy-lock.sh node
 * --test …`), process.env carries that job's handoff: HELD, control and flock FD
 * numbers that are not open in the fixture, the mdpro marker and the caller's
 * timing overrides. A fixture that copies them is refused by heavy-lock.py as a
 * contradictory or reverse nesting before it runs what the test is about. The
 * handoff belongs to the caller, so every fixture starts from a copy without it,
 * and sets the MADO_HEAVY_* values it needs through `overrides`. The node:test
 * worker context is dropped too: a fixture's own `node --test` is an independent
 * runner. Production lanes (node-lane.mjs, trash-lane.mjs) keep passing the
 * handoff on and must not use this. An override whose value is undefined
 * removes the key. */
export function fixtureEnv(overrides = {}) {
  const env = {};
  for (const [name, value] of Object.entries(process.env))
    if (!name.startsWith('MADO_HEAVY_') && name !== 'MDPRO_HEAVY_LOCK_HELD' && name !== 'NODE_TEST_CONTEXT') env[name] = value;
  for (const [name, value] of Object.entries(overrides)) {
    if (value === undefined) delete env[name];
    else env[name] = value;
  }
  return env;
}
