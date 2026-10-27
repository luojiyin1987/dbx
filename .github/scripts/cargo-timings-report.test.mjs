import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { longestChain, parseTimingReport, renderMarkdown, resolveReportPath, summarizeTimingReport } from "./cargo-timings-report.mjs";

function reportHtml({ wall = 40, units } = {}) {
  return `<html><body><script>\nDURATION = ${wall};\nconst UNIT_DATA = ${JSON.stringify(units, null, 2)};\n</script></body></html>`;
}

const units = [
  { i: 1, name: "leaf", version: "1.0.0", mode: "todo", start: 0, duration: 10, unblocked_units: [3], sections: [["frontend", { start: 0, end: 4 }], ["codegen", { start: 4, end: 10 }]] },
  { i: 2, name: "helper", version: "1.0.0", mode: "todo", start: 0, duration: 10, unblocked_units: [], sections: [["frontend", { start: 0, end: 10 }]] },
  { i: 3, name: "middle", version: "1.0.0", mode: "todo", start: 10, duration: 20, unblocked_units: [4], sections: [["frontend", { start: 0, end: 20 }]] },
  { i: 4, name: "root", version: "2.0.0", mode: "todo", start: 30, duration: 5, unblocked_units: [], sections: null },
];

test("the timing report parser reads the embedded duration and unit array", () => {
  const report = parseTimingReport(reportHtml({ units }));
  assert.equal(report.wallSeconds, 40);
  assert.deepEqual(report.units.map((unit) => unit.name), ["leaf", "helper", "middle", "root"]);
});

test("the timing report parser rejects reports without timing data", () => {
  assert.throws(() => parseTimingReport("<html></html>"), /missing DURATION/);
  assert.throws(() => parseTimingReport("DURATION = 4;\n"), /missing const UNIT_DATA/);
});

test("the summary measures parallel width, the serial tail and the longest chain", () => {
  const summary = summarizeTimingReport(parseTimingReport(reportHtml({ units })));

  assert.equal(summary.unitCount, 4);
  assert.equal(summary.unitSeconds, 45);
  assert.equal(summary.meanParallelism, 1.125);
  assert.equal(summary.prefixSeconds, 0);
  assert.equal(summary.serialSeconds, 30);
  assert.equal(summary.serialTailSeconds, 30);
  assert.deepEqual(summary.concurrency, [
    { width: 0, seconds: 5, share: 0.125 },
    { width: 1, seconds: 25, share: 0.625 },
    { width: 2, seconds: 10, share: 0.25 },
  ]);
  assert.deepEqual(summary.sections, [
    { name: "frontend", seconds: 34 },
    { name: "codegen", seconds: 6 },
  ]);
  assert.deepEqual(summary.criticalPath, {
    seconds: 35,
    units: [
      { name: "leaf", version: "1.0.0", mode: "todo", duration: 10, start: 0 },
      { name: "middle", version: "1.0.0", mode: "todo", duration: 20, start: 10 },
      { name: "root", version: "2.0.0", mode: "todo", duration: 5, start: 30 },
    ],
  });
});

test("parallel units are counted per overlap window", () => {
  const parallel = [
    { i: 1, name: "left", version: "1", mode: "todo", start: 0, duration: 10, unblocked_units: [] },
    { i: 2, name: "right", version: "1", mode: "todo", start: 0, duration: 10, unblocked_units: [] },
  ];
  const summary = summarizeTimingReport(parseTimingReport(reportHtml({ wall: 10, units: parallel })));
  assert.equal(summary.peakConcurrency, 2);
  assert.deepEqual(summary.concurrency, [{ width: 2, seconds: 10, share: 1 }]);
  assert.equal(summary.serialTailSeconds, 0);
});

test("a unit that is not unblocked by its predecessor still gets a chain", () => {
  const chain = longestChain([
    { i: 1, name: "first", version: "1", mode: "todo", start: 0, duration: 3, unblocked_units: [] },
    { i: 2, name: "second", version: "1", mode: "todo", start: 5, duration: 7, unblocked_units: [] },
  ]);
  assert.equal(chain.seconds, 7);
  assert.deepEqual(chain.units.map((unit) => unit.name), ["second"]);
});

test("the markdown report states wall time, concurrency and the serial tail", () => {
  const markdown = renderMarkdown(summarizeTimingReport(parseTimingReport(reportHtml({ units }))), { title: "Fixture" });
  assert.match(markdown, /^### Fixture$/m);
  assert.match(markdown, /Wall time: 0\.7 min \(40 s\)/);
  assert.match(markdown, /mean parallelism: 1\.13x on 2 units at peak/);
  assert.match(markdown, /trailing serial stretch: 0\.5 min \(75\.0%\)/);
  assert.match(markdown, /Longest dependency chain: 0\.6 min over 3 units/);
  assert.match(markdown, /\| 1 unit \| 0\.4 min \| 62\.5% \|/);
  assert.match(markdown, /- root 2\.0\.0 \(todo\) — 0\.1 min, start 30\.0 s/);
});

test("a report directory resolves to the newest cargo timing file", () => {
  const directory = mkdtempSync(path.join(tmpdir(), "cargo-timings-"));
  try {
    writeFileSync(path.join(directory, "cargo-timing.html"), "old");
    writeFileSync(path.join(directory, "cargo-timing-20260101T000000Z-aaaa.html"), "new");
    writeFileSync(path.join(directory, "notes.txt"), "ignore");
    assert.equal(path.basename(resolveReportPath(directory)), "cargo-timing-20260101T000000Z-aaaa.html");
    assert.throws(() => resolveReportPath(path.join(directory, "missing")), /ENOENT/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("a missing report warns without failing the step", () => {
  const script = fileURLToPath(new URL("./cargo-timings-report.mjs", import.meta.url));
  const result = spawnSync(process.execPath, [script, path.join(tmpdir(), "missing-cargo-timings")], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^::warning::No Cargo timing report at /m);
});
