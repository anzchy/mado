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
try {
  if (!['render', 'post', 'record'].includes(mode) || !input) throw new Error('usage: evidence.mjs render|post|record input.json');
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
    if (!new RegExp(`^https://github\\.com/[^/]+/[^/]+/issues/${d.issue}#issuecomment-\\d+$`).test(d.commentUrl || '')) throw new Error('record requires evidence comment URL for this issue');
    const verdict = gateVerdict(d.gates);
    const target = path.join(process.cwd(), '.build/mado-verify', `${d.head}.json`);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, JSON.stringify({ head: d.head, gates: d.gates, complete: verdict.complete, problems: verdict.problems, commentUrl: d.commentUrl, issue: d.issue, recordedAt: new Date().toISOString() }, null, 2) + '\n');
    console.log(target);
  }
} catch (error) { console.error(error.message); process.exitCode = 1; }
