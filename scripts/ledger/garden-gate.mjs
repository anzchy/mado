#!/usr/bin/env node
// Decides whether the doc gardener has to run for a PR range (#324).
// Prints exactly one line on stdout, a reason on stderr, and always exits 0:
//   Ledger-Gardener: SKIP|REUSE|RESOLVED … when the gardener can be skipped, otherwise RUN.
// Every doubt, including any error, prints RUN.

import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const LEDGER = "docs/feature-ledger.md";
const HTML = "docs/feature-ledger.html";
const BUILD = fileURLToPath(new URL("./build.mjs", import.meta.url));
const REUSABLE = new Set(["CLEAN", "UPDATED"]);
const VERDICTS = new Set(["CLEAN", "UPDATED", "NEEDS-OWNER"]);
const GUARDED_CELLS = ["状态", "验证", "怎么确认"];
const MAPPED_PREFIXES = ["App/", "docs/validation/"];
const MAPPED_FILES = new Set(["project.yml", LEDGER, HTML]);
const PACKAGE_SOURCES = /^Packages\/[^/]+\/Sources\//;
const WP_ID = /\bP\d+-\d{2}[a-z]?\b/i;
const ID_TOKEN = /\b[A-Za-z][A-Za-z0-9]*-\d{2,}\b/g;
const GLOB = /[*?[{]/;

class GateError extends Error {}

function git(...args) {
  return execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 256 * 1024 * 1024 });
}

function resolveCommit(ref) {
  try {
    return git("rev-parse", "--verify", "--quiet", `${ref}^{commit}`).trim();
  } catch {
    throw new GateError(`cannot resolve ${ref} to a commit`);
  }
}

function isAncestor(ancestor, descendant) {
  const result = spawnSync("git", ["merge-base", "--is-ancestor", ancestor, descendant], { encoding: "utf8" });
  if (result.status === 0) return true;
  if (result.status === 1) return false;
  throw new GateError(`git merge-base --is-ancestor failed: ${result.stderr.trim()}`);
}

// Returns null only when Git confirms the path is absent at commit; every other failure throws.
function fileAt(commit, path) {
  const entry = git("ls-tree", "--full-tree", "-z", commit, "--", path);
  if (entry === "") return null;
  return git("show", `${commit}:${path}`);
}

function splitTableRow(line, raw = false) {
  const cells = [];
  let cell = "";
  let inCode = false;
  const body = line.trim().replace(/^\|/, "").replace(/\|$/, "");
  for (let index = 0; index < body.length; index += 1) {
    const character = body[index];
    if (character === "`" && body[index - 1] !== "\\") inCode = !inCode;
    if (character === "|" && !inCode && body[index - 1] !== "\\") {
      cells.push(raw ? cell : cell.trim());
      cell = "";
    } else {
      cell += character;
    }
  }
  cells.push(raw ? cell : cell.trim());
  return raw ? cells : cells.map((value) => value.replaceAll("\\|", "|"));
}

// Every row of every table with an ID column, in file order.
function parseLedgerRows(markdown) {
  const lines = markdown.replaceAll("\r\n", "\n").split("\n");
  const rows = [];
  for (let index = 0; index < lines.length; index += 1) {
    if (!lines[index].startsWith("|") || !/^\|(?:\s*:?-+:?\s*\|)+$/.test(lines[index + 1] ?? "")) continue;
    const header = splitTableRow(lines[index]);
    index += 2;
    const body = [];
    while (index < lines.length && lines[index].startsWith("|")) {
      const line = lines[index++];
      const cells = splitTableRow(line);
      const confirmation = header.indexOf("怎么确认");
      // Preserve the exact acceptance bytes, including Markdown escapes and cell padding.
      if (confirmation >= 0) cells[confirmation] = splitTableRow(line, true)[confirmation];
      body.push(cells);
    }
    if (!header.includes("ID")) continue;
    for (const cells of body) {
      const row = Object.fromEntries(header.map((name, column) => [name, cells[column]]));
      if (row.ID) rows.push(row);
    }
  }
  return rows;
}

function readLedger(commit) {
  const markdown = fileAt(commit, LEDGER);
  if (markdown === null) throw new GateError(`cannot read ${LEDGER} at ${commit.slice(0, 7)}`);
  const rows = parseLedgerRows(markdown);
  if (rows.length === 0) throw new GateError(`no ledger rows with an ID column at ${commit.slice(0, 7)}`);
  return rows;
}

// A 在哪 path with a glob character keeps only its literal prefix, matched as a plain string
// prefix; an empty prefix (a leading glob, or the repository root) matches every path.
function ledgerIndex(rowsList) {
  const ids = new Set();
  const paths = new Map();
  for (const rows of rowsList) {
    for (const row of rows) {
      ids.add(row.ID.toUpperCase());
      for (const match of (row["在哪"] ?? "").matchAll(/`([^`]+)`/g)) {
        const named = match[1].trim();
        const path = named.replace(/^\.\//, "");
        const glob = path.search(GLOB);
        if (glob >= 0) paths.set(named, { prefix: path.slice(0, glob) });
        else if (path === "" || path === "." || path === "/") paths.set(named, { prefix: "" });
        else paths.set(named, { literal: path });
      }
    }
  }
  return { ids, paths };
}

// Raw NUL-delimited names, so Git's quoting of non-ASCII and special characters never applies.
function changedPaths(from, to) {
  const endpoint = git("diff", "--name-only", "-z", "--no-renames", from, to);
  const perCommit = git("log", "-m", "--format=", "--name-only", "-z", "--no-renames", `${from}..${to}`);
  return [...new Set(`${endpoint}\0${perCommit}`.split("\0").filter(Boolean))];
}

function pathIsMapped(path, ledgerPaths) {
  if (MAPPED_FILES.has(path) || PACKAGE_SOURCES.test(path)) return `${path} is a mapped path`;
  if (MAPPED_PREFIXES.some((prefix) => path.startsWith(prefix))) return `${path} is under a mapped directory`;
  for (const [named, { literal, prefix }] of ledgerPaths) {
    if (prefix !== undefined ? path.startsWith(prefix) : path === literal || path.startsWith(literal.endsWith("/") ? literal : `${literal}/`)) {
      return `${path} is named in 在哪 (${named})`;
    }
  }
  return null;
}

// Returns the first reason the range from..to can affect the ledger, or null.
function mappedReason(from, to) {
  const rowsList = [readLedger(to)];
  if (fileAt(from, LEDGER) !== null) rowsList.push(readLedger(from));
  const { ids, paths } = ledgerIndex(rowsList);
  for (const path of changedPaths(from, to)) {
    const reason = pathIsMapped(path, paths);
    if (reason) return reason;
  }
  const messages = git("log", "--format=%B", `${from}..${to}`);
  const wp = messages.match(WP_ID);
  if (wp) return `commit message names plan WP ${wp[0]}`;
  for (const match of messages.matchAll(ID_TOKEN)) {
    if (ids.has(match[0].toUpperCase())) return `commit message names ledger row ${match[0]}`;
  }
  return null;
}

function guardedCells(rows) {
  const seen = new Map();
  const cells = new Map();
  for (const row of rows) {
    const count = (seen.get(row.ID) ?? 0) + 1;
    seen.set(row.ID, count);
    cells.set(`${row.ID}#${count}`, JSON.stringify(GUARDED_CELLS.map((name) => {
      const value = row[name] ?? null;
      // Only the suffix starting at the first exact 限制： is an owner-editable note.
      return name === "怎么确认" && value !== null ? value.split("限制：", 1)[0] : value;
    })));
  }
  return cells;
}

// Returns null when since..head is only owner ledger fixes, otherwise the reason it is not.
function unresolvedReason(since, head) {
  const commits = git("rev-list", "--reverse", "--parents", `${since}..${head}`).split("\n").filter(Boolean);
  if (commits.length === 0) return `no commits since ${since.slice(0, 7)}`;
  for (const line of commits) {
    const [commit, ...parents] = line.split(" ");
    const short = commit.slice(0, 7);
    if (parents.length !== 1) return `${short} is a merge or root commit`;
    const files = git("diff-tree", "--no-commit-id", "--name-only", "-z", "-r", "--no-renames", parents[0], commit).split("\0").filter(Boolean);
    const other = files.find((file) => file !== LEDGER && file !== HTML);
    if (other) return `${short} changes ${other}, not only the ledger`;
    const before = guardedCells(readLedger(parents[0]));
    const after = guardedCells(readLedger(commit));
    if (before.size !== after.size) return `${short} adds or removes ledger rows`;
    for (const [key, value] of after) {
      if (before.get(key) !== value) return `${short} changes the 状态, 验证 or 怎么确认 cell of ${key.split("#")[0]}`;
    }
  }
  const markdown = fileAt(head, LEDGER);
  const html = fileAt(head, HTML);
  if (html === null) return `${HTML} is missing at head`;
  const scratch = mkdtempSync(join(tmpdir(), "picsee-garden-gate-"));
  try {
    writeFileSync(join(scratch, "ledger.md"), markdown);
    writeFileSync(join(scratch, "ledger.html"), html);
    const check = spawnSync(process.execPath, [BUILD, "--check", "--source", join(scratch, "ledger.md"), "--output", join(scratch, "ledger.html")], { encoding: "utf8" });
    if (check.status !== 0) return `generated HTML is stale at head (${check.stderr.trim() || `exit ${check.status}`})`;
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  return null;
}

function parseArguments(argv) {
  const positional = [];
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if ((argument === "--since" || argument === "--verdict") && argv[index + 1] !== undefined) options[argument.slice(2)] = argv[++index];
    else if (argument.startsWith("--")) throw new GateError(`unknown or incomplete option ${argument}`);
    else positional.push(argument);
  }
  if (positional.length !== 2) throw new GateError("usage: garden-gate.mjs <base> <head> [--since <last-gardened-head> --verdict <CLEAN|UPDATED|NEEDS-OWNER>]");
  if ((options.since === undefined) !== (options.verdict === undefined)) throw new GateError("--since and --verdict go together");
  if (options.verdict !== undefined && !VERDICTS.has(options.verdict)) throw new GateError(`verdict ${options.verdict} cannot be reused or resolved`);
  return { base: positional[0], head: positional[1], ...options };
}

function decide(argv) {
  const options = parseArguments(argv);
  const head = resolveCommit(options.head);
  const mergeBase = git("merge-base", resolveCommit(options.base), head).trim();
  const range = `${mergeBase.slice(0, 7)}..${head.slice(0, 7)}`;
  const skipOrRun = (note) => {
    const reason = mappedReason(mergeBase, head);
    if (reason) return { line: "RUN", reason: `${note}${reason}` };
    return { line: `Ledger-Gardener: SKIP ${range} (no mapped paths)`, reason: `${note}no mapped paths, ledger IDs or WP IDs in ${range}` };
  };
  if (options.since === undefined) return skipOrRun("");
  const since = resolveCommit(options.since);
  if (!isAncestor(since, head)) return skipOrRun(`--since ${since.slice(0, 7)} is not an ancestor of head; `);
  const sinceShort = since.slice(0, 7);
  if (options.verdict === "NEEDS-OWNER") {
    const reason = unresolvedReason(since, head);
    if (reason) return { line: "RUN", reason: `not resolved: ${reason}` };
    return { line: `Ledger-Gardener: RESOLVED ${range} (owner fixed rows after NEEDS-OWNER at ${sinceShort})`, reason: "only ledger fixes that leave 状态, 验证 and acceptance before 限制： unchanged; HTML in sync" };
  }
  if (REUSABLE.has(options.verdict)) {
    const reason = mappedReason(since, head);
    if (reason) return { line: "RUN", reason: `mapped change since ${sinceShort}: ${reason}` };
    return { line: `Ledger-Gardener: REUSE ${options.verdict} ${range} (no mapped change since ${sinceShort})`, reason: `nothing mapped in ${sinceShort}..${head.slice(0, 7)}` };
  }
  return { line: "RUN", reason: `verdict ${options.verdict} is not reusable` };
}

let result;
try {
  result = decide(process.argv.slice(2));
} catch (error) {
  const message = error instanceof GateError ? error.message : `git failed: ${(error.stderr?.toString() || error.message).trim()}`;
  result = { line: "RUN", reason: message };
}
process.stdout.write(`${result.line}\n`);
process.stderr.write(`garden-gate: ${result.reason}\n`);
