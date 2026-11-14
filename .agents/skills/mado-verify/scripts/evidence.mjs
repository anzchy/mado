#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { gateVerdict } from './gate-policy.mjs';

const [mode, input] = process.argv.slice(2);
function privacyHits(body) {
  return [
    ['/Users/', /\/Users\//], ['/private/', /\/private\//], ['/var/folders/', /\/var\/folders\//],
    ['secret-like string', /(?:gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(?:api[_-]?key|secret|token|password)\s*[:=]\s*["']?[A-Za-z0-9+/_=-]{12,})/i],
  ].filter(([, re]) => re.test(body)).map(([label]) => label);
}
function render(d) {
  const sha7 = d.head.slice(0, 7);
  const gates = d.gates.map(g => `- \`${g.command}\` → exit ${g.exitCode}; ${g.keyLine || 'no decisive line recorded'}`).join('\n');
  const rows = d.byType.map(x => `| ${x.behavior} | ${x.expected} | ${x.actual} | ${x.result} |`).join('\n');
  const shots = d.screenshots?.length ? `\n\n#### 截图（仅 UI 修改）\n| 状态 | 修复前（base \`${d.base?.slice(0, 7)}\`） | 修复后（head \`${sha7}\`） | 机器 |\n|---|---|---|---|\n${d.screenshots.map(s => `| ${s.state} | ${s.before} | ${s.after} | ${s.machine} |`).join('\n')}` : '';
  return `<!-- mado-verify issue=${d.issue} task=${d.task} head=${d.head} -->\n### mado-verify：#${d.issue} · \`${d.task}\` · \`${d.branch}\` @ \`${sha7}\`\n\n工具链：${d.toolchain || 'NOT VERIFIED'}；机器：${d.machine || 'NOT VERIFIED'}；沙盒模式（Codex）：${d.sandbox || 'n/a'}\n\n#### 门禁\n${gates}\n\n#### 测试完整性\n${d.integrity}\n\n#### 按类型加跑\n| 行为（brief / 账簿行） | 预期 | 实际 | 结果 |\n|---|---|---|---|\n${rows}${shots}\n\n#### NOT VERIFIED\n${d.notVerified.map(x => `- ${x}`).join('\n')}\n`;
}
function head() { const r = spawnSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }); if (r.status) throw new Error('not a git repo'); return r.stdout.trim(); }
const commentPattern = issue => new RegExp(`^https://github\\.com/[^/]+/[^/]+/issues/${issue}#issuecomment-\\d+$`);
// Manual acceptance check the delegator runs before audit and before merge (no Stop hook since 2026-11-14).
function check(args) {
  const usage = 'usage: evidence.mjs check --head <sha> [--worktree <wt>]';
  let want, worktree = process.cwd();
  while (args.length) {
    const flag = args.shift(), value = args.shift();
    if (flag === '--head' && value && !want) want = value;
    else if (flag === '--worktree' && value) worktree = value;
    else throw new Error(usage);
  }
  if (!want || !/^[0-9a-f]{7,40}$/i.test(want)) throw new Error(usage);
  const git = (...a) => { const r = spawnSync('git', a, { cwd: worktree, encoding: 'utf8' }); return r.status === 0 ? r.stdout.trim() : null; };
  const current = git('rev-parse', 'HEAD');
  if (!current) throw new Error(`not a git worktree: ${worktree}`);
  const named = git('rev-parse', '--verify', '--quiet', `${want}^{commit}`);
  if (named !== current) throw new Error(`--head ${want} is not the worktree HEAD ${current}: stale head, rerun mado-verify for the final head`);
  if (git('status', '--porcelain', '--untracked-files=no')) throw new Error('worktree has tracked changes; the record covers a commit, not a dirty tree');
  const top = git('rev-parse', '--show-toplevel');
  const file = path.join(top, '.build/mado-verify', `${current}.json`);
  let record;
  try { record = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { throw new Error(`no mado-verify record for ${current} (expected .build/mado-verify/${current}.json)`); }
  if (record.head !== current) throw new Error(`record head ${record.head} differs from ${current}`);
  if (!Number.isSafeInteger(record.issue) || record.issue < 1) throw new Error('record has no valid issue');
  if (typeof record.commentUrl !== 'string' || !commentPattern(record.issue).test(record.commentUrl)) throw new Error(`record commentUrl is missing or not an evidence comment on issue #${record.issue}`);
  const verdict = gateVerdict(record.gates);
  if (!verdict.complete) throw new Error(`record gates incomplete: ${verdict.problems.join(', ')}`);
  console.log(`OK head=${current} issue=${record.issue} comment=${record.commentUrl}`);
}
try {
  if (mode === 'check') { check(process.argv.slice(3)); process.exit(0); }
  if (!['render', 'post', 'record'].includes(mode) || !input) throw new Error('usage: evidence.mjs render|post|record input.json | check --head <sha> [--worktree <wt>]');
  const d = JSON.parse(fs.readFileSync(input, 'utf8'));
  if (!/^[0-9a-f]{40}$/.test(d.head) || !Number.isSafeInteger(d.issue) || d.issue < 1 || !Array.isArray(d.gates) || !Array.isArray(d.byType) || !Array.isArray(d.notVerified)) throw new Error('invalid evidence fields');
  if (d.head !== head()) throw new Error('evidence head does not match current HEAD');
  const body = render(d), hits = privacyHits(body);
  if (hits.length) throw new Error(`privacy scan refused: ${hits.join(', ')}`);
  if (mode === 'render') process.stdout.write(body);
  if (mode === 'post') {
    const temp = path.join(process.cwd(), '.build/mado-verify', `${d.head}.md`);
    fs.mkdirSync(path.dirname(temp), { recursive: true }); fs.writeFileSync(temp, body);
    const r = spawnSync('gh', ['issue', 'comment', String(d.issue), '--body-file', temp], { encoding: 'utf8' });
    if (r.status) throw new Error(r.stderr.trim() || 'gh comment failed');
    process.stdout.write(r.stdout);
  }
  if (mode === 'record') {
    if (!commentPattern(d.issue).test(d.commentUrl || '')) throw new Error('record requires evidence comment URL for this issue');
    const verdict = gateVerdict(d.gates);
    const target = path.join(process.cwd(), '.build/mado-verify', `${d.head}.json`);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, JSON.stringify({ head: d.head, gates: d.gates, complete: verdict.complete, problems: verdict.problems, commentUrl: d.commentUrl, issue: d.issue, recordedAt: new Date().toISOString() }, null, 2) + '\n');
    console.log(target);
  }
} catch (error) { console.error(error.message); process.exitCode = 1; }
