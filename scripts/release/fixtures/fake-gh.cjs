#!/usr/bin/env node
// #891: fake gh for check-tag-ci.test.mjs (checked in, 100755, symlinked per run so no fresh file is exec'd).
const fs = require('node:fs');
const count = fs.existsSync(process.env.FAKE_COUNTER) ? Number(fs.readFileSync(process.env.FAKE_COUNTER)) : 0;
fs.writeFileSync(process.env.FAKE_COUNTER, String(count + 1));
const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_COUNTER + '.args', JSON.stringify(args) + '\n');
const fixture = JSON.parse(fs.readFileSync(process.env.FAKE_FIXTURE))[count];
if (!process.env.GH_TOKEN && !process.env.GITHUB_TOKEN) process.exit(9);
if (fixture && fixture.error) { process.stderr.write('transport error token=' + process.env.GH_TOKEN); process.exit(1); }
if (fixture && fixture.raw !== undefined) { process.stdout.write(fixture.raw); process.exit(0); }
// Simulate gh pagination semantics, so dropping either option cannot pass pagination cases.
const value = args.includes('--paginate') && args.includes('--slurp') ? fixture : fixture?.[0];
process.stdout.write(JSON.stringify(value));
