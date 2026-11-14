#!/usr/bin/env node
// Resolve a CHANGELOG.md conflict during a rebase/merge:
// keep the "ours" (upstream) file and add to its [Unreleased] section every
// bullet the incoming commit ("theirs", stage 3) added to [Unreleased]
// relative to the common base (stage 1), under the same ### heading.
// Exits 1 if the incoming change touches anything outside [Unreleased]
// (then the conflict is not "simple" and needs a human/agent look).
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const file = process.argv[2] ?? "CHANGELOG.md";
const stage = (n) => {
  try {
    return execFileSync("git", ["show", `:${n}:${file}`], { encoding: "utf8", maxBuffer: 1 << 26 });
  } catch {
    return "";
  }
};
const base = stage(1),
  ours = stage(2),
  theirs = stage(3);
if (!ours || !theirs) {
  console.error("missing stage");
  process.exit(1);
}

const UNREL = /^## \[Unreleased\][^\n]*\n/m;
function split(text) {
  const m = UNREL.exec(text);
  if (!m) return null;
  const start = m.index + m[0].length;
  const rest = text.slice(start);
  const next = rest.search(/^## /m);
  const end = next === -1 ? text.length : start + next;
  return { head: text.slice(0, start), body: text.slice(start, end), tail: text.slice(end) };
}
function sections(body) {
  // heading -> array of entries (an entry is a bullet plus its continuation lines)
  const map = new Map();
  let h = "";
  let cur = null;
  for (const line of body.split("\n")) {
    if (/^### /.test(line)) {
      h = line.trim();
      if (!map.has(h)) map.set(h, []);
      cur = null;
      continue;
    }
    if (/^- /.test(line)) {
      if (!map.has(h)) map.set(h, []);
      cur = [line];
      map.get(h).push(cur);
      continue;
    }
    if (cur && line.trim() !== "") cur.push(line);
    else cur = null;
  }
  return new Map([...map].map(([k, v]) => [k, v.map((e) => e.join("\n"))]));
}

const b = split(base || ours),
  o = split(ours),
  t = split(theirs);
if (!b || !o || !t) {
  console.error("no [Unreleased] section");
  process.exit(1);
}
if (b.tail.trim() !== t.tail.trim() || b.head.trim() !== t.head.trim()) {
  console.error("incoming change edits CHANGELOG outside [Unreleased]; not a simple conflict");
  process.exit(1);
}
const bs = sections(b.body),
  os = sections(o.body),
  ts = sections(t.body);
for (const [h, entries] of ts) {
  const had = new Set(bs.get(h) ?? []);
  const have = new Set(os.get(h) ?? []);
  for (const e of entries) {
    if (had.has(e) || have.has(e)) continue;
    if (!os.has(h)) os.set(h, []);
    os.get(h).push(e);
  }
}
// removals in theirs of base bullets: honour them
for (const [h, entries] of bs) {
  const kept = new Set(ts.get(h) ?? []);
  for (const e of entries)
    if (!kept.has(e) && os.has(h))
      os.set(
        h,
        os.get(h).filter((x) => x !== e),
      );
}
const order = [
  "### Added",
  "### Changed",
  "### Deprecated",
  "### Removed",
  "### Fixed",
  "### Security",
];
const heads = [...os.keys()]
  .filter((h) => os.get(h).length)
  .sort((x, y) => (order.indexOf(x) + 1 || 99) - (order.indexOf(y) + 1 || 99));
let body = "\n";
for (const h of heads) body += (h ? `${h}\n\n` : "") + os.get(h).join("\n") + "\n\n";
writeFileSync(file, o.head + body + o.tail.replace(/^\n+/, ""));
execFileSync("git", ["add", file]);
console.error(`resolved ${file}`);
