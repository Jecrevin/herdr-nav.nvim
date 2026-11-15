// Runs nav.ts the way herdr does — `node nav.ts <dir>` — against a stub `herdr`
// on PATH, and asserts which herdr call each chord produces.
//
//   node --test test/

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
    mkdirSync,
    mkdtempSync,
    readFileSync,
    writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const nav = join(dirname(dirname(fileURLToPath(import.meta.url))), "nav.ts");

// Stub herdr: logs its argv, answers the two calls whose JSON nav.ts parses.
const STUB = `#!/usr/bin/env node
import { appendFileSync } from "node:fs";
const args = process.argv.slice(2);
appendFileSync(process.env.FAKE_LOG, JSON.stringify(args) + "\\n");
const out = (value) => process.stdout.write(JSON.stringify(value));
if (args[0] === "pane" && args[1] === "process-info") {
    out({ result: { process_info: { foreground_processes: [{ name: process.env.FAKE_FG }] } } });
} else if (args[0] === "pane" && args[1] === "layout") {
    out({ result: { layout: { zoomed: process.env.FAKE_ZOOMED === "1" } } });
} else if (args[0] === "pane" && args[1] === "current") {
    out({ result: { pane: { pane_id: "pane-current" } } });
}
`;

function sandbox({ foreground = "bash", config, env = {} } = {}) {
    const dir = mkdtempSync(join(tmpdir(), "herdr-nav-"));
    const bin = join(dir, "bin");
    mkdirSync(bin);
    const herdr = join(bin, "herdr");
    writeFileSync(herdr, STUB, { mode: 0o755 });

    const log = join(dir, "calls.log");
    writeFileSync(log, "");
    const configDir = join(dir, "config");
    if (config) {
        mkdirSync(configDir);
        writeFileSync(join(configDir, "nav.json"), JSON.stringify(config));
    }

    return {
        run(args, overrides = {}) {
            return spawnSync(process.execPath, [nav, ...args], {
                encoding: "utf8",
                env: {
                    PATH: bin + delimiter + process.env.PATH,
                    HERDR_BIN_PATH: herdr,
                    HERDR_PANE_ID: "pane-1",
                    HERDR_PLUGIN_CONFIG_DIR: configDir,
                    FAKE_LOG: log,
                    FAKE_FG: foreground,
                    FAKE_ZOOMED: "0",
                    ...overrides,
                },
            });
        },
        calls() {
            return readFileSync(log, "utf8")
                .split("\n")
                .filter(Boolean)
                .map((line) => JSON.parse(line));
        },
        // Everything but the read-only probes (process-info, layout).
        decisions() {
            return this.calls().filter((call) =>
                ["send-keys", "focus"].includes(call[1])
            );
        },
    };
}

test("an editor pane gets the chord written back", () => {
    const box = sandbox({ foreground: "nvim" });
    const result = box.run(["left"]);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(box.decisions(), [
        ["pane", "send-keys", "pane-1", "ctrl+h"],
    ]);
});

test("any other pane moves herdr focus", () => {
    const box = sandbox({ foreground: "bash" });
    const result = box.run(["right"]);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(box.decisions(), [
        ["pane", "focus", "--direction", "right", "--pane", "pane-1"],
    ]);
});

test("passthrough programs keep the chord", () => {
    const box = sandbox({
        foreground: "lazygit",
        config: { passthrough: ["^lazygit$"] },
    });
    assert.equal(box.run(["up"]).status, 0);
    assert.deepEqual(box.decisions(), [
        ["pane", "send-keys", "pane-1", "ctrl+k"],
    ]);
});

test("config overrides the forwarded chord", () => {
    const box = sandbox({
        foreground: "nvim",
        config: { forward: { down: "ctrl+n" } },
    });
    assert.equal(box.run(["down"]).status, 0);
    assert.deepEqual(box.decisions(), [
        ["pane", "send-keys", "pane-1", "ctrl+n"],
    ]);
});

test("a zoomed pane is left alone when skipWhenZoomed is set", () => {
    const box = sandbox({
        foreground: "bash",
        config: { skipWhenZoomed: true },
    });
    const result = box.run(["down"], { FAKE_ZOOMED: "1" });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(box.decisions(), []);
    assert.deepEqual(box.calls().at(-1), ["pane", "layout", "--pane", "pane-1"]);
});

test("without HERDR_PANE_ID the current pane is asked for", () => {
    const box = sandbox({ foreground: "bash" });
    assert.equal(box.run(["left"], { HERDR_PANE_ID: "" }).status, 0);
    assert.deepEqual(box.calls()[0], ["pane", "current"]);
    assert.deepEqual(box.decisions().at(-1), [
        "pane",
        "focus",
        "--direction",
        "left",
        "--pane",
        "pane-current",
    ]);
});

test("a stale HERDR_BIN_PATH falls back to herdr on PATH", () => {
    const box = sandbox({ foreground: "bash" });
    const result = box.run(["left"], { HERDR_BIN_PATH: "/nonexistent/herdr" });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(box.decisions(), [
        ["pane", "focus", "--direction", "left", "--pane", "pane-1"],
    ]);
});

test("an unknown direction fails loudly", () => {
    const box = sandbox();
    const result = box.run(["sideways"]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /usage: nav\.ts/);
    assert.deepEqual(box.decisions(), []);
});

test("--self-check passes", () => {
    const result = sandbox().run(["--self-check"]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /self-check ok/);
});
