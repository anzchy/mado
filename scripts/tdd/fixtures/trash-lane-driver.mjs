#!/usr/bin/env node
// Test driver for scripts/tdd/trash-lane.test.mjs: runs the real scenario loop with
// short limits under the real heavy-lock. Only Swift is replaced (by the test's fake).
import { runScenarios } from '../trash-lane.mjs';

const options = JSON.parse(process.argv[2]);
const env = { ...process.env, ...(options.childEnv ?? {}) };
process.exitCode = runScenarios({ ...options, env });
