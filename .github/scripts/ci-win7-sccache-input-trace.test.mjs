import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const trace = readFileSync(new URL("./ci-win7-sccache-input-trace.ps1", import.meta.url), "utf8");
const wrapper = readFileSync(new URL("./ci-win7-sccache-input-wrapper.rs", import.meta.url), "utf8");

test("Win7 input tracing stays limited to the two drifting crates", () => {
  for (const crate of ["dbx_lib", "psm"]) {
    assert.ok(trace.includes(`"${crate}"`));
    assert.ok(wrapper.includes(`crate_name != "${crate}"`));
  }
});

test("Win7 input tracing hashes environment values", () => {
  for (const excluded of ["CARGO_MAKEFLAGS", "CARGO_REGISTRIES_", "CARGO_BUILD_JOBS", "CARGO_ENCODED_RUSTFLAGS"]) {
    assert.ok(trace.includes(excluded));
  }
  for (const output of ["env_dep=$($entry.name) value_sha256=", "cargo_env=$($entry.name) value_sha256="]) {
    assert.ok(trace.includes(output));
  }
  assert.doesNotMatch(trace, /cargo_env=.*\$\(\$entry\.value\)(?!_sha256)/);
});

test("Win7 input tracing records each remaining key input class", () => {
  for (const marker of ["source=$($entry.path) sha256=", "env_dep=", "cargo_env=", "staticlib=$($entry.path) sha256="]) {
    assert.ok(trace.includes(marker));
  }
  assert.ok(trace.includes('$compilerOutputDirectory = Get-ArgumentValue $arguments "--out-dir"'));
  assert.ok(trace.includes('"psm_s.lib", "libpsm_s.a", "psm_s.a"'));
});
