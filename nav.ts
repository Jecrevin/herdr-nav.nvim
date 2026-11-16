#!/usr/bin/env node
// herdr-nav — <A-h/j/k/l> across herdr panes and editor splits.
//
// Invoked by the four [[actions]] in herdr-plugin.toml as `node nav.ts <dir>`.
// If the pane's foreground program owns these keys (an editor, or anything
// listed in `passthrough`), the key is written into that pane so the program
// moves between its own splits and calls back here at the edge. Otherwise herdr
// moves focus. This is the `is_vim` half of vim-tmux-navigator.
//
// Config: $HERDR_PLUGIN_CONFIG_DIR/nav.json. `forward` — the key written into
// the pane — belongs to the editor's own mapping, so plugin/herdr_nav.lua writes
// it there from vim.g.herdr_nav.keys; the rest is written with defaults on first
// run. Herdr does not tell a plugin action which key fired it, so the key cannot
// be taken from the binding itself.

import { spawnSync } from "node:child_process";
import {
    accessSync,
    constants,
    mkdirSync,
    readFileSync,
    writeFileSync,
} from "node:fs";
import { join } from "node:path";

const DIRECTIONS = ["left", "down", "up", "right"] as const;
type Direction = (typeof DIRECTIONS)[number];

type Config = {
    /** Chord written into the pane when its program owns the keys. */
    forward: Record<Direction, string>;
    /** Regexes matched against the lower-cased foreground process name. */
    editors: string[];
    /** Extra programs that also keep the key (lazygit, k9s, ...). */
    passthrough: string[];
    /** Leave a zoomed pane alone instead of moving focus. */
    skipWhenZoomed: boolean;
};

const DEFAULT_CONFIG: Config = {
    forward: { left: "ctrl+h", down: "ctrl+j", up: "ctrl+k", right: "ctrl+l" },
    editors: ["^g?(view|l?n?vim?x?)(diff)?$"],
    passthrough: [],
    skipWhenZoomed: false,
};

function fail(message: string): never {
    process.stderr.write(`herdr-nav: ${message}\n`);
    process.exit(1);
}

function isExecutable(path: string): boolean {
    try {
        accessSync(path, constants.X_OK);
        return true;
    } catch {
        return false;
    }
}

// The server injects HERDR_BIN_PATH; after `herdr update` replaced the binary it
// can point at a deleted inode, so fall back to PATH rather than failing every
// keypress.
function herdrBinary(): string {
    const injected = process.env.HERDR_BIN_PATH;
    return injected && isExecutable(injected) ? injected : "herdr";
}

function herdrRun(args: string[]): void {
    const result = spawnSync(herdrBinary(), args, { encoding: "utf8" });
    if (result.error) fail(`cannot run herdr: ${result.error.message}`);
    if (result.status !== 0) {
        const detail = (result.stderr || result.stdout).trim();
        fail(`herdr ${args.slice(0, 2).join(" ")} failed: ${detail}`);
    }
}

// Only calls whose JSON we read come through here; `pane send-keys` and
// `pane focus` print nothing on success, so they must not be parsed.
function herdrJson<T>(args: string[]): T {
    const result = spawnSync(herdrBinary(), args, { encoding: "utf8" });
    if (result.error) fail(`cannot run herdr: ${result.error.message}`);
    if (result.status !== 0) {
        const detail = (result.stderr || result.stdout).trim();
        fail(`herdr ${args.slice(0, 2).join(" ")} failed: ${detail}`);
    }
    try {
        return JSON.parse(result.stdout) as T;
    } catch {
        fail(`unexpected herdr output: ${result.stdout.slice(0, 200)}`);
    }
}

function loadConfig(): Config {
    const dir = process.env.HERDR_PLUGIN_CONFIG_DIR;
    if (!dir) return DEFAULT_CONFIG;
    const path = join(dir, "nav.json");
    let raw: string;
    try {
        raw = readFileSync(path, "utf8");
    } catch {
        try {
            mkdirSync(dir, { recursive: true });
            writeFileSync(path, `${JSON.stringify(DEFAULT_CONFIG, null, 2)}\n`);
        } catch (error) {
            process.stderr.write(`herdr-nav: cannot write ${path}: ${error}\n`);
        }
        return DEFAULT_CONFIG;
    }
    let parsed: Partial<Config>;
    try {
        parsed = JSON.parse(raw) as Partial<Config>;
    } catch (error) {
        process.stderr.write(`herdr-nav: ${path}: ${error}\n`);
        return DEFAULT_CONFIG;
    }
    return {
        ...DEFAULT_CONFIG,
        ...parsed,
        forward: { ...DEFAULT_CONFIG.forward, ...parsed.forward },
    };
}

function currentPane(): string {
    // Plugin actions get HERDR_PANE_ID; HERDR_ACTIVE_PANE_ID covers a
    // [[keys.command]] shell binding.
    const fromEnv =
        process.env.HERDR_PANE_ID ?? process.env.HERDR_ACTIVE_PANE_ID;
    if (fromEnv) return fromEnv;
    const { result } = herdrJson<{ result: { pane: { pane_id: string } } }>([
        "pane",
        "current",
    ]);
    return result.pane.pane_id;
}

// Windows reports process names as `nvim.exe` and may send a full path; match on
// the bare executable name so one default works everywhere.
function processName(raw: string): string {
    const base = raw.split(/[\\/]/).pop() ?? raw;
    return base.toLowerCase().replace(/\.exe$/, "");
}

function ownsKeys(names: string[], config: Config): boolean {
    let patterns: RegExp[];
    try {
        patterns = [...config.editors, ...config.passthrough].map(
            (source) => new RegExp(source),
        );
    } catch (error) {
        fail(`bad regex in editors/passthrough: ${error}`);
    }
    return names.some((name) =>
        patterns.some((pattern) => pattern.test(processName(name))),
    );
}

// `node nav.ts --self-check` — the matcher is the one piece of logic that can be
// wrong without a visible failure, so keep a cheap assertion for it.
function selfCheck(): void {
    const cases: [string, boolean][] = [
        ["nvim", true],
        ["NVIM", true],
        ["nvim.exe", true],
        ["C:\\Program Files\\Neovim\\bin\\nvim.exe", true],
        ["/usr/local/bin/vimdiff", true],
        ["pi", false],
        ["nvim.exe.bak", false],
        ["sleep", false],
    ];
    for (const [name, expected] of cases) {
        const got = ownsKeys([name], { ...DEFAULT_CONFIG, passthrough: [] });
        if (got !== expected) fail(`self-check: ${name} -> ${got}`);
    }
    if (
        !ownsKeys(["lazygit"], {
            ...DEFAULT_CONFIG,
            passthrough: ["^lazygit$"],
        })
    ) {
        fail("self-check: passthrough");
    }
    process.stdout.write("self-check ok\n");
}

function main(): void {
    if (process.argv[2] === "--self-check") return selfCheck();

    const direction = process.argv[2] as Direction;
    if (!DIRECTIONS.includes(direction)) {
        fail(`usage: nav.ts <${DIRECTIONS.join("|")}>`);
    }

    const config = loadConfig();
    const pane = currentPane();
    const { result } = herdrJson<{
        result: {
            process_info: {
                foreground_processes: { name?: string }[];
            };
        };
    }>(["pane", "process-info", "--pane", pane]);
    const names = result.process_info.foreground_processes.map(
        (process) => process.name ?? "",
    );

    if (ownsKeys(names, config)) {
        herdrRun(["pane", "send-keys", pane, config.forward[direction]]);
        return;
    }

    if (config.skipWhenZoomed) {
        const layout = herdrJson<{ result: { layout: { zoomed?: boolean } } }>([
            "pane",
            "layout",
            "--pane",
            pane,
        ]);
        if (layout.result.layout.zoomed) return;
    }

    herdrRun(["pane", "focus", "--direction", direction, "--pane", pane]);
}

main();
