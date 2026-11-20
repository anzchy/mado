#!/usr/bin/env node
import { evaluateReuse } from './reuse-policy.mjs';

if (process.argv.length !== 6) {
  console.error('usage: reuse-check.mjs <old-base> <new-base> <old-head> <new-head>');
  process.exitCode = 2;
} else {
  const result = evaluateReuse(process.cwd(), ...process.argv.slice(2));
  console.log(result.reuse ? 'REUSE' : `RERUN ${result.reason}`);
}
