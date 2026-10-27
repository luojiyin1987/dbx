// Summarize a Cargo HTML timing report (`cargo build --timings`).
// The report embeds a DURATION value and a UNIT_DATA JSON array. This script
// makes the numbers greppable in a step summary: wall time, parallel width,
// serial tail and the longest dependency chain. It does not build anything.

import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const UNIT_DATA_MARKER = "const UNIT_DATA = ";

function extractJsonArray(text, marker) {
  const start = text.indexOf(marker);
  if (start < 0) throw new Error(`missing ${marker.trim()}`);
  const from = start + marker.length;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = from; index < text.length; index += 1) {
    const char = text[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === "[") depth += 1;
    else if (char === "]") {
      depth -= 1;
      if (depth === 0) return JSON.parse(text.slice(from, index + 1));
    }
  }
  throw new Error("unterminated UNIT_DATA array");
}

export function parseTimingReport(html) {
  const duration = /\bDURATION\s*=\s*(\d+(?:\.\d+)?)\s*;/.exec(html);
  if (!duration) throw new Error("missing DURATION value");
  const units = extractJsonArray(html, UNIT_DATA_MARKER);
  if (!Array.isArray(units) || units.length === 0) throw new Error("UNIT_DATA is empty");
  return { wallSeconds: Number(duration[1]), units };
}

function countBy(values) {
  const counts = new Map();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return counts;
}

// Time spent at each number of concurrently running units. A boundary belongs
// to the interval that starts there, so unit stops are applied before starts.
function concurrencyTimeline(units, wallSeconds) {
  const events = [];
  for (const unit of units) {
    events.push({ at: unit.start, delta: 1 });
    events.push({ at: unit.start + unit.duration, delta: -1 });
  }
  events.sort((left, right) => left.at - right.at || left.delta - right.delta);

  const seconds = new Map();
  let current = 0;
  let previous = 0;
  let lastParallelEnd = 0;
  let hadParallel = false;
  for (const event of events) {
    if (event.at > previous) {
      seconds.set(current, (seconds.get(current) ?? 0) + (event.at - previous));
      previous = event.at;
    }
    const before = current;
    current += event.delta;
    if (before >= 2) hadParallel = true;
    if (before >= 2 && current === 1) lastParallelEnd = event.at;
  }
  if (wallSeconds > previous) seconds.set(current, (seconds.get(current) ?? 0) + (wallSeconds - previous));

  let serialSeconds = 0;
  for (const [width, value] of seconds) if (width <= 1) serialSeconds += value;
  const peak = Math.max(...seconds.keys());
  return {
    seconds,
    peak,
    serialSeconds,
    serialTailSeconds: hadParallel ? Math.max(0, wallSeconds - lastParallelEnd) : 0,
  };
}

function sectionTotals(units) {
  const totals = new Map();
  for (const unit of units) {
    for (const [name, range] of unit.sections ?? []) {
      const seconds = Math.max(0, (range.end ?? 0) - (range.start ?? 0));
      totals.set(name, (totals.get(name) ?? 0) + seconds);
    }
  }
  return totals;
}

// Longest dependency chain reconstructed from the `unblocked_units` edges.
// Chain time counts unit durations only; idle gaps are not included.
export function longestChain(units) {
  const predecessors = new Map(units.map((unit) => [unit.i, []]));
  for (const unit of units) {
    for (const id of unit.unblocked_units ?? []) predecessors.get(id)?.push(unit.i);
  }

  const best = new Map();
  const ordered = [...units].sort((left, right) => left.start - right.start);
  for (const unit of ordered) {
    let predecessor = null;
    for (const id of predecessors.get(unit.i) ?? []) {
      const candidate = best.get(id);
      if (!candidate) continue;
      if (!predecessor || candidate.total > predecessor.total) predecessor = candidate;
    }
    best.set(unit.i, {
      total: (predecessor?.total ?? 0) + unit.duration,
      path: [...(predecessor?.path ?? []), unit],
    });
  }

  let longest = { total: 0, path: [] };
  for (const candidate of best.values()) if (candidate.total > longest.total) longest = candidate;
  return {
    seconds: longest.total,
    units: longest.path.map((unit) => ({
      name: unit.name,
      version: unit.version,
      mode: unit.mode,
      duration: unit.duration,
      start: unit.start,
    })),
  };
}

export function summarizeTimingReport(report) {
  const { wallSeconds, units } = report;
  const unitSeconds = units.reduce((sum, unit) => sum + unit.duration, 0);
  const timeline = concurrencyTimeline(units, wallSeconds);
  const sections = sectionTotals(units);
  const modes = countBy(units.map((unit) => unit.mode));
  const firstStart = Math.min(...units.map((unit) => unit.start));

  return {
    wallSeconds,
    unitCount: units.length,
    unitSeconds,
    meanParallelism: wallSeconds > 0 ? unitSeconds / wallSeconds : 0,
    modes: Object.fromEntries(modes),
    prefixSeconds: Math.max(0, firstStart),
    concurrency: [...timeline.seconds.entries()]
      .filter(([, seconds]) => seconds >= 0.05)
      .sort(([left], [right]) => left - right)
      .map(([width, seconds]) => ({ width, seconds, share: wallSeconds > 0 ? seconds / wallSeconds : 0 })),
    peakConcurrency: timeline.peak,
    serialSeconds: timeline.serialSeconds,
    serialTailSeconds: timeline.serialTailSeconds,
    sections: [...sections.entries()]
      .sort((left, right) => right[1] - left[1])
      .map(([name, seconds]) => ({ name, seconds })),
    topUnits: [...units]
      .sort((left, right) => right.duration - left.duration)
      .slice(0, 10)
      .map((unit) => ({
        name: unit.name,
        version: unit.version,
        mode: unit.mode,
        start: unit.start,
        duration: unit.duration,
        end: unit.start + unit.duration,
      })),
    criticalPath: longestChain(units),
  };
}

function minutes(seconds) {
  return `${(seconds / 60).toFixed(1)} min`;
}

function percent(share) {
  return `${(share * 100).toFixed(1)}%`;
}

export function renderMarkdown(summary, { title = "Cargo timings" } = {}) {
  const lines = [];
  lines.push(`### ${title}`);
  lines.push("");
  lines.push(`- Wall time: ${minutes(summary.wallSeconds)} (${summary.wallSeconds.toFixed(0)} s)`);
  lines.push(`- Units: ${summary.unitCount} (${Object.entries(summary.modes).map(([mode, count]) => `${count} ${mode}`).join(", ")})`);
  lines.push(`- Sum of unit time: ${minutes(summary.unitSeconds)}; mean parallelism: ${summary.meanParallelism.toFixed(2)}x on ${summary.peakConcurrency} units at peak`);
  lines.push(`- One unit at a time: ${minutes(summary.serialSeconds)} (${percent(summary.serialSeconds / summary.wallSeconds)}); trailing serial stretch: ${minutes(summary.serialTailSeconds)} (${percent(summary.serialTailSeconds / summary.wallSeconds)})`);
  if (summary.prefixSeconds > 0) {
    lines.push(`- Before the first unit started: ${minutes(summary.prefixSeconds)} (dependency resolution, download or cache handshake)`);
  }
  if (summary.sections.length > 0) {
    lines.push(`- Sections: ${summary.sections.map((section) => `${section.name} ${minutes(section.seconds)}`).join(", ")}`);
  }
  lines.push(`- Longest dependency chain: ${minutes(summary.criticalPath.seconds)} over ${summary.criticalPath.units.length} units`);
  lines.push("");
  lines.push("| Concurrency | Time | Share |");
  lines.push("| --- | --- | --- |");
  for (const bucket of summary.concurrency) {
    lines.push(`| ${bucket.width} unit${bucket.width === 1 ? "" : "s"} | ${minutes(bucket.seconds)} | ${percent(bucket.share)} |`);
  }
  lines.push("");
  lines.push("| Longest units | Start | Duration | End |");
  lines.push("| --- | --- | --- | --- |");
  for (const unit of summary.topUnits) {
    lines.push(`| ${unit.name} ${unit.version} (${unit.mode}) | ${unit.start.toFixed(1)} s | ${minutes(unit.duration)} | ${unit.end.toFixed(1)} s |`);
  }
  if (summary.criticalPath.units.length > 1) {
    lines.push("");
    lines.push("Longest chain:");
    lines.push("");
    for (const unit of summary.criticalPath.units) {
      lines.push(`- ${unit.name} ${unit.version} (${unit.mode}) — ${minutes(unit.duration)}, start ${unit.start.toFixed(1)} s`);
    }
  }
  lines.push("");
  return lines.join("\n");
}

export function resolveReportPath(input) {
  const resolved = path.resolve(input);
  if (statSync(resolved).isFile()) return resolved;
  const candidates = readdirSync(resolved)
    .filter((name) => /^cargo-timing.*\.html$/.test(name))
    .map((name) => path.join(resolved, name))
    .sort((left, right) => statSync(right).mtimeMs - statSync(left).mtimeMs);
  if (candidates.length === 0) throw new Error(`no cargo timing report in ${input}`);
  return candidates[0];
}

function main(argv) {
  const json = argv.includes("--json");
  const inputs = argv.filter((argument) => !argument.startsWith("-"));
  if (inputs.length !== 1) {
    console.log("Usage: node .github/scripts/cargo-timings-report.mjs <cargo-timing.html|timings-dir> [--markdown|--json]");
    process.exitCode = 2;
    return;
  }
  let reportPath;
  try {
    reportPath = resolveReportPath(inputs[0]);
  } catch (error) {
    // A failed build may leave no timing report. Report a warning and keep the
    // step result neutral so it cannot hide the real failure above.
    if (error.code === "ENOENT" || /no cargo timing report/.test(error.message)) {
      console.log(`::warning::No Cargo timing report at ${inputs[0]}`);
      return;
    }
    throw error;
  }
  const summary = summarizeTimingReport(parseTimingReport(readFileSync(reportPath, "utf8")));
  if (json) console.log(JSON.stringify({ report: reportPath, ...summary }, null, 2));
  else console.log(renderMarkdown(summary, { title: `Cargo timings: ${path.basename(reportPath)}` }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main(process.argv.slice(2));
