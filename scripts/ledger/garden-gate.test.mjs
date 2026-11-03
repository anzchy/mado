import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const gate = fileURLToPath(new URL("./garden-gate.mjs", import.meta.url));
const build = fileURLToPath(new URL("./build.mjs", import.meta.url));
const fixtureLedger = readFileSync(new URL("./fixtures/garden-gate-ledger.md", import.meta.url), "utf8");
const LEDGER = "docs/feature-ledger.md";
const HTML = "docs/feature-ledger.html";

function makeRepo(t) {
  const repo = mkdtempSync(join(tmpdir(), "picsee-garden-gate-"));
  t.after(() => rmSync(repo, { recursive: true, force: true }));
  const git = (...args) => execFileSync("git", args, { cwd: repo, encoding: "utf8" }).trim();
  const write = (path, content) => {
    mkdirSync(dirname(join(repo, path)), { recursive: true });
    writeFileSync(join(repo, path), content);
  };
  const read = (path) => readFileSync(join(repo, path), "utf8");
  const buildHtml = () => execFileSync(process.execPath, [build, "--source", join(repo, LEDGER), "--output", join(repo, HTML)]);
  const commit = (message, files) => {
    for (const [path, content] of Object.entries(files)) write(path, content);
    git("add", "--", ...Object.keys(files));
    git("commit", "-q", "-m", message);
    return git("rev-parse", "HEAD");
  };
  const commitLedger = (message, ledger, { rebuild = true } = {}) => {
    write(LEDGER, ledger);
    if (rebuild) buildHtml();
    git("add", "--", LEDGER, HTML);
    git("commit", "-q", "-m", message);
    return git("rev-parse", "HEAD");
  };
  git("init", "-q", "-b", "main");
  git("config", "user.email", "test@example.invalid");
  git("config", "user.name", "Test");
  write(LEDGER, fixtureLedger);
  buildHtml();
  write("scripts/tool.py", "print('base')\n");
  git("add", "--", LEDGER, HTML, "scripts/tool.py");
  git("commit", "-q", "-m", "chore: base");
  const base = git("rev-parse", "HEAD");
  const run = (...args) => {
    const result = spawnSync(process.execPath, [gate, ...args], { cwd: repo, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const lines = result.stdout.split("\n").filter(Boolean);
    assert.equal(lines.length, 1, `expected exactly one stdout line, got: ${result.stdout}`);
    return { line: lines[0], stderr: result.stderr };
  };
  return { repo, git, write, read, commit, commitLedger, buildHtml, base, run };
}

const short = (sha) => sha.slice(0, 7);
const skipLine = (base, head) => `Ledger-Gardener: SKIP ${short(base)}..${short(head)} (no mapped paths)`;

test("tooling-only range gives SKIP", (t) => {
  const r = makeRepo(t);
  const head = r.commit("chore(tools): tweak script", { "scripts/tool.py": "print('head')\n", "docs/agents/notes.md": "x\n" });
  assert.equal(r.run(r.base, "HEAD").line, skipLine(r.base, head));
});

test("an App path gives RUN", (t) => {
  const r = makeRepo(t);
  r.commit("chore: app tweak", { "App/PicseeApp.swift": "// x\n" });
  assert.equal(r.run(r.base, "HEAD").line, "RUN");
});

for (const path of ["Packages/PicseeKit/Sources/PicseeCore/Item.swift", "docs/validation/P1.md", "project.yml", HTML]) {
  test(`fixed mapped prefix ${path} gives RUN`, (t) => {
    const r = makeRepo(t);
    r.commit("chore: touch", { [path]: "x\n" });
    assert.equal(r.run(r.base, "HEAD").line, "RUN");
  });
}

test("a 在哪 file outside App/Packages gives RUN", (t) => {
  const r = makeRepo(t);
  r.commit("chore: entitlements", { "Config/Picsee.entitlements": "<plist/>\n" });
  assert.equal(r.run(r.base, "HEAD").line, "RUN");
});

test("a file under a 在哪 directory gives RUN", (t) => {
  const r = makeRepo(t);
  r.commit("chore: asset", { "TestAssets/access/one.jpg": "x\n" });
  assert.equal(r.run(r.base, "HEAD").line, "RUN");
});

test("a path change made and reverted inside the range still gives RUN", (t) => {
  const r = makeRepo(t);
  r.commit("chore: add", { "Config/Picsee.entitlements": "<plist/>\n" });
  r.git("rm", "-q", "Config/Picsee.entitlements");
  r.git("commit", "-q", "-m", "chore: remove");
  assert.equal(r.run(r.base, "HEAD").line, "RUN");
});

test("a ledger row ID in a commit body gives RUN", (t) => {
  const r = makeRepo(t);
  r.commit("chore(tools): tweak\n\nRelated: ACCESS-01", { "scripts/tool.py": "print('id')\n" });
  assert.equal(r.run(r.base, "HEAD").line, "RUN");
});

test("an ID from the 不做 table gives RUN", (t) => {
  const r = makeRepo(t);
  r.commit("chore(tools): NOPE-01 note", { "scripts/tool.py": "print('id')\n" });
  assert.equal(r.run(r.base, "HEAD").line, "RUN");
});

test("an ID that is not in the ledger gives SKIP", (t) => {
  const r = makeRepo(t);
  const head = r.commit("chore(tools): tweak\n\nRelated: FOO-99, VIEW-77", { "scripts/tool.py": "print('id')\n" });
  assert.equal(r.run(r.base, "HEAD").line, skipLine(r.base, head));
});

for (const id of ["P2-08", "P2-08c", "p3-01"]) {
  test(`plan WP ID ${id} in a message gives RUN`, (t) => {
    const r = makeRepo(t);
    r.commit(`chore(tools): prep for ${id}`, { "scripts/tool.py": "print('wp')\n" });
    assert.equal(r.run(r.base, "HEAD").line, "RUN");
  });
}

test("REUSE after a docs-only fix commit", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  const head = r.commit("docs(agents): fix typo", { "docs/agents/notes.md": "y\n" });
  for (const verdict of ["CLEAN", "UPDATED"]) {
    assert.equal(
      r.run(r.base, "HEAD", "--since", gardened, "--verdict", verdict).line,
      `Ledger-Gardener: REUSE ${verdict} ${short(r.base)}..${short(head)} (no mapped change since ${short(gardened)})`,
    );
  }
});

test("RUN after a mapped fix commit", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  r.commit("fix: app", { "App/PicseeApp.swift": "// y\n" });
  assert.equal(r.run(r.base, "HEAD", "--since", gardened, "--verdict", "CLEAN").line, "RUN");
});

test("REUSE is not given for NEEDS-OWNER or BLOCK with a docs-only fix", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  r.commit("docs(agents): fix typo", { "docs/agents/notes.md": "y\n" });
  assert.equal(r.run(r.base, "HEAD", "--since", gardened, "--verdict", "NEEDS-OWNER").line, "RUN");
  assert.equal(r.run(r.base, "HEAD", "--since", gardened, "--verdict", "BLOCK").line, "RUN");
});

test("RESOLVED after a ledger-only owner commit", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  const edited = r.read(LEDGER).replace("`Config/Picsee.entitlements`", "`Config/Picsee.entitlements`、`App/Access/`");
  const head = r.commitLedger("docs(ledger): owner fixes ACCESS-01", edited);
  assert.equal(
    r.run(r.base, "HEAD", "--since", gardened, "--verdict", "NEEDS-OWNER").line,
    `Ledger-Gardener: RESOLVED ${short(r.base)}..${short(head)} (owner fixed rows after NEEDS-OWNER at ${short(gardened)})`,
  );
});

// #416 supersedes the previous expectation that limitation-only edits require RUN.
for (const [name, before, after, resolved] of [
  ["limitation-only edit", "打开一张 JPEG，画布显示该图。限制：真机未验", "打开一张 JPEG，画布显示该图。限制：真机与 @2x 未验", true],
  ["acceptance edit before marker", "打开一张 JPEG，画布显示该图。限制：真机未验", "打开两张 JPEG，画布显示该图。限制：真机未验", false],
  ["changed marker-free cell", "按 ⌘1，图片按像素 1:1 显示", "按 ⌘2，图片按像素 1:1 显示", false],
  ["add limitation with identical raw prefix", "按 ⌘1，图片按像素 1:1 显示 |", "按 ⌘1，图片按像素 1:1 显示 限制：待验证 |", true],
  ["remove limitation with identical raw prefix", "打开一张 JPEG，画布显示该图。限制：真机未验 |", "打开一张 JPEG，画布显示该图。|", true],
  ["edit between first and second marker", "限制：真机未验", "限制：新限制；限制：后续说明", true],
  ["whitespace before marker", "该图。限制：", "该图。 限制：", false],
  ["leading cell padding", "| 打开一张 JPEG", "|  打开一张 JPEG", false],
  ["marker-free trailing padding", "1:1 显示 |", "1:1 显示  |", false],
]) {
  test(`owner fix: ${name}`, (t) => {
    const r = makeRepo(t);
    // Disambiguate the capability label from the acceptance text before the owner range.
    if (name === "marker-free trailing padding") {
      r.commitLedger("chore: distinct fixture label", r.read(LEDGER).replace("| VIEW-02 | 1:1 显示 |", "| VIEW-02 | 原始像素 |"));
    }
    const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
    const original = r.read(LEDGER);
    assert.ok(original.includes(before));
    const head = r.commitLedger("docs(ledger): owner", original.replace(before, after));
    const result = r.run(r.base, "HEAD", "--since", gardened, "--verdict", "NEEDS-OWNER");
    assert.equal(result.line, resolved
      ? `Ledger-Gardener: RESOLVED ${short(r.base)}..${short(head)} (owner fixed rows after NEEDS-OWNER at ${short(gardened)})`
      : "RUN");
    if (!resolved) assert.match(result.stderr, /cell of VIEW-0[12]/);
  });
}

test("unsafe intermediate acceptance edit cannot be hidden by a revert", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  const original = r.read(LEDGER);
  r.commitLedger("docs: edit acceptance", original.replace("打开一张 JPEG", "打开两张 JPEG"));
  r.commitLedger("docs: restore acceptance and fix limitation", original.replace("限制：真机未验", "限制：未做真机验收"));
  assert.equal(r.run(r.base, "HEAD", "--since", gardened, "--verdict", "NEEDS-OWNER").line, "RUN");
});

for (const [cell, from, to] of [["状态", "| Partial | 单元 | P0-09", "| Shipped | 单元 | P0-09"], ["验证", "| Partial | 单元 | P0-09", "| Partial | 真机 | P0-09"]]) {
  test(`not RESOLVED when the owner commit edits a ${cell} cell`, (t) => {
    const r = makeRepo(t);
    const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
    r.commitLedger("docs(ledger): owner", r.read(LEDGER).replace(from, to));
    const result = r.run(r.base, "HEAD", "--since", gardened, "--verdict", "NEEDS-OWNER");
    assert.equal(result.line, "RUN");
    assert.match(result.stderr, /cell of ACCESS-01/);
  });
}

test("not RESOLVED when the owner commit adds a row", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  r.commitLedger("docs(ledger): owner", r.read(LEDGER).replace("| VIEW-02 |", "| VIEW-03 | 缩放 | Absent | 无 | P1-05 | — | 捏合缩放 |\n| VIEW-02 |"));
  const result = r.run(r.base, "HEAD", "--since", gardened, "--verdict", "NEEDS-OWNER");
  assert.equal(result.line, "RUN");
  assert.match(result.stderr, /adds or removes ledger rows/);
});

test("not RESOLVED when the owner commit also touches a non-ledger file", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  r.write(LEDGER, r.read(LEDGER).replace("`Config/Picsee.entitlements`", "`Config/Picsee.entitlements`、`App/Access/`"));
  r.buildHtml();
  r.commit("docs(ledger): owner with extra file", { "docs/agents/notes.md": "z\n", [LEDGER]: r.read(LEDGER), [HTML]: r.read(HTML) });
  const result = r.run(r.base, "HEAD", "--since", gardened, "--verdict", "NEEDS-OWNER");
  assert.equal(result.line, "RUN");
  assert.match(result.stderr, /docs\/agents\/notes\.md, not only the ledger/);
});

test("not RESOLVED with no commits since the gardened head", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  const result = r.run(r.base, "HEAD", "--since", gardened, "--verdict", "NEEDS-OWNER");
  assert.equal(result.line, "RUN");
  assert.match(result.stderr, /no commits/);
});

test("not RESOLVED when the generated HTML is stale at head", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  const edited = r.read(LEDGER).replace("`Config/Picsee.entitlements`", "`Config/Picsee.entitlements`、`App/Access/`");
  r.commitLedger("docs(ledger): owner", edited, { rebuild: false });
  const result = r.run(r.base, "HEAD", "--since", gardened, "--verdict", "NEEDS-OWNER");
  assert.equal(result.line, "RUN");
  assert.match(result.stderr, /stale|html/i);
});

test("a non-ancestor --since gives RUN for a mapped range", (t) => {
  const r = makeRepo(t);
  r.git("checkout", "-q", "-b", "old");
  const gardened = r.commit("chore: app old", { "App/PicseeApp.swift": "// old\n" });
  r.git("checkout", "-q", "main");
  r.commit("chore: app new", { "App/PicseeApp.swift": "// new\n" });
  r.commit("docs(agents): note", { "docs/agents/notes.md": "y\n" });
  assert.equal(r.run(r.base, "HEAD", "--since", gardened, "--verdict", "CLEAN").line, "RUN");
});

test("a non-ancestor --since gives SKIP when the whole range is unmapped", (t) => {
  const r = makeRepo(t);
  r.git("checkout", "-q", "-b", "old");
  const gardened = r.commit("chore: tool old", { "scripts/tool.py": "print('old')\n" });
  r.git("checkout", "-q", "main");
  const head = r.commit("chore: tool new", { "scripts/tool.py": "print('new')\n" });
  assert.equal(r.run(r.base, "HEAD", "--since", gardened, "--verdict", "CLEAN").line, skipLine(r.base, head));
});

test("a base that is not an ancestor is judged from the merge-base", (t) => {
  const r = makeRepo(t);
  r.git("checkout", "-q", "-b", "feature");
  const head = r.commit("chore: tool", { "scripts/tool.py": "print('f')\n" });
  r.git("checkout", "-q", "main");
  r.commit("feat: app on main", { "App/PicseeApp.swift": "// main\n" });
  r.git("checkout", "-q", "feature");
  assert.equal(r.run("main", "HEAD").line, skipLine(r.base, head));
});

test("errors fail closed to RUN with a reason", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: tool", { "scripts/tool.py": "print('x')\n" });
  const cases = [
    ["no-such-ref", "HEAD"],
    [r.base, "no-such-ref"],
    [r.base, "HEAD", "--since", "no-such-ref", "--verdict", "CLEAN"],
    [r.base, "HEAD", "--since", gardened],
    [r.base, "HEAD", "--since", gardened, "--verdict", "SKIP"],
    [r.base, "HEAD", "--verdict", "CLEAN"],
    [r.base],
    [r.base, "HEAD", "--bogus"],
  ];
  for (const args of cases) {
    const result = r.run(...args);
    assert.equal(result.line, "RUN", `args ${args.join(" ")}`);
    assert.ok(result.stderr.trim().length > 0, `no reason for ${args.join(" ")}`);
  }
});

test("an unreadable ledger fails closed to RUN", (t) => {
  const r = makeRepo(t);
  r.git("rm", "-q", LEDGER);
  r.git("commit", "-q", "-m", "chore: drop ledger");
  r.commit("chore: tool", { "scripts/tool.py": "print('x')\n" });
  const base = r.git("rev-parse", "HEAD~1");
  const result = r.run(base, "HEAD");
  assert.equal(result.line, "RUN");
  assert.match(result.stderr, /ledger/i);
});

test("outside a git repository it fails closed to RUN", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "picsee-garden-gate-nogit-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const result = spawnSync(process.execPath, [gate, "main", "HEAD"], { cwd: dir, encoding: "utf8", env: { ...process.env, GIT_CEILING_DIRECTORIES: dirname(dir) } });
  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), "RUN");
  assert.ok(result.stderr.trim());
});

// F1: Git quotes non-ASCII and quote characters in display output; paths must be read raw.
const quotedPaths = [
  ["a unicode path under App/", "App/画布.swift", null],
  ["a unicode path named in 在哪", "Config/授权.entitlements", (ledger) => ledger.replace("`Config/Picsee.entitlements`", "`Config/授权.entitlements`")],
  ["a path with a quote and a space named in 在哪", 'Config/Pic "see" one.entitlements', (ledger) => ledger.replace("`Config/Picsee.entitlements`", '`Config/Pic "see" one.entitlements`')],
];
for (const [name, path, edit] of quotedPaths) {
  test(`${name} gives RUN`, (t) => {
    const r = makeRepo(t);
    const base = edit ? r.commitLedger("chore: ledger", edit(r.read(LEDGER))) : r.base;
    r.commit("chore: adjust file", { [path]: "x\n" });
    const result = r.run(base, "HEAD");
    assert.equal(result.line, "RUN");
    assert.ok(result.stderr.includes(path), result.stderr);
  });

  test(`${name} gives RUN instead of REUSE`, (t) => {
    const r = makeRepo(t);
    if (edit) r.commitLedger("chore: ledger", edit(r.read(LEDGER)));
    const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
    r.commit("chore: adjust file", { [path]: "x\n" });
    const result = r.run(r.base, "HEAD", "--since", gardened, "--verdict", "CLEAN");
    assert.equal(result.line, "RUN");
    assert.ok(result.stderr.includes(path), result.stderr);
  });
}

// F2: a `*` in a 在哪 path keeps its literal prefix as a plain string prefix.
const wildcards = [
  ["a file-prefix wildcard", "`Config/Picsee*.entitlements`", "Config/PicseeDebug.entitlements"],
  ["a directory wildcard", "`Config/*`", "Config/Other.plist"],
  ["a leading star", "`*.entitlements`", "Elsewhere/thing.txt"],
];
for (const [name, named, path] of wildcards) {
  test(`${name} in 在哪 gives RUN`, (t) => {
    const r = makeRepo(t);
    const base = r.commitLedger("chore: ledger", r.read(LEDGER).replace("`Config/Picsee.entitlements`", named));
    r.commit("chore: adjust file", { [path]: "x\n" });
    assert.equal(r.run(base, "HEAD").line, "RUN");
    const gardened = r.git("rev-parse", "HEAD~1");
    assert.equal(r.run(base, "HEAD", "--since", gardened, "--verdict", "CLEAN").line, "RUN");
  });
}

test("a literal 在哪 file path does not cover a sibling with a longer name", (t) => {
  const r = makeRepo(t);
  const head = r.commit("chore: adjust file", { "Config/Picsee.entitlements.bak": "x\n" });
  assert.equal(r.run(r.base, "HEAD").line, skipLine(r.base, head));
});

// F3: only a confirmed absence counts as "no ledger at the baseline"; any other Git failure is RUN.
function gitShim(t, failWhenArgsInclude) {
  const dir = mkdtempSync(join(tmpdir(), "picsee-garden-gate-shim-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const realGit = execFileSync("sh", ["-c", "command -v git"], { encoding: "utf8" }).trim();
  const shim = join(dir, "git");
  writeFileSync(shim, `#!/bin/sh\ncase " $* " in\n  *"${failWhenArgsInclude}"*) echo "fatal: injected object read failure" >&2; exit 128 ;;\nesac\nexec "${realGit}" "$@"\n`, { mode: 0o755 });
  return { ...process.env, PATH: `${dir}:${process.env.PATH}` };
}

function runWith(r, env, ...args) {
  const result = spawnSync(process.execPath, [gate, ...args], { cwd: r.repo, encoding: "utf8", env });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.split("\n").filter(Boolean).length, 1, result.stdout);
  return { line: result.stdout.trim(), stderr: result.stderr };
}

test("a failed baseline ledger read gives RUN, not SKIP", (t) => {
  const r = makeRepo(t);
  r.commit("chore: notes", { "notes.txt": "x\n" });
  assert.match(r.run(r.base, "HEAD").line, /^Ledger-Gardener: SKIP /);
  const result = runWith(r, gitShim(t, `show ${r.base}:${LEDGER}`), r.base, "HEAD");
  assert.equal(result.line, "RUN");
  assert.match(result.stderr, /injected object read failure/);
});

test("a failed baseline ledger lookup gives RUN, not SKIP", (t) => {
  const r = makeRepo(t);
  r.commit("chore: notes", { "notes.txt": "x\n" });
  const result = runWith(r, gitShim(t, `ls-tree --full-tree -z ${r.base}`), r.base, "HEAD");
  assert.equal(result.line, "RUN");
  assert.match(result.stderr, /injected object read failure/);
});

test("a failed --since ledger read gives RUN, not REUSE", (t) => {
  const r = makeRepo(t);
  const gardened = r.commit("chore: app", { "App/PicseeApp.swift": "// x\n" });
  r.commit("chore: notes", { "notes.txt": "x\n" });
  assert.match(r.run(r.base, "HEAD", "--since", gardened, "--verdict", "CLEAN").line, /^Ledger-Gardener: REUSE /);
  const result = runWith(r, gitShim(t, `show ${gardened}:${LEDGER}`), r.base, "HEAD", "--since", gardened, "--verdict", "CLEAN");
  assert.equal(result.line, "RUN");
  assert.match(result.stderr, /injected object read failure/);
});

test("a ledger that did not exist at the base is not an error", (t) => {
  const r = makeRepo(t);
  r.git("rm", "-q", LEDGER, HTML);
  r.git("commit", "-q", "-m", "chore: no ledger yet");
  const base = r.git("rev-parse", "HEAD");
  r.write(LEDGER, fixtureLedger);
  r.buildHtml();
  r.git("add", "--", LEDGER, HTML);
  r.git("commit", "-q", "-m", "chore: add ledger");
  const result = r.run(base, "HEAD");
  assert.equal(result.line, "RUN");
  assert.match(result.stderr, /is a mapped path/);
});
