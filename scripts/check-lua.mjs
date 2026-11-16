#!/usr/bin/env node
// Lua diagnostics with lua-language-server — the same tool the editor LSP and
// CI use, driven from `.luarc.json`.
//
// `.luarc.json` puts `$VIMRUNTIME` on the library path, which is what makes
// `vim.*` resolve; ask Neovim for it rather than guess a directory. Override the
// binary with `$LUA_LS_BIN` (CI installs a release tarball) and the severity
// with `$CHECKLEVEL`.
//
//   node scripts/check-lua.mjs

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const env = { ...process.env };

/** Run a command, exiting with 2 when it cannot be started at all. */
function run(cmd, args) {
    const result = spawnSync(cmd, args, { encoding: "utf8", env });
    if (result.error) {
        process.stderr.write(
            `check-lua: cannot run ${cmd}: ${result.error.message}\n`,
        );
        process.exit(2);
    }
    return result;
}

if (!env.VIMRUNTIME) {
    const probed = run("nvim", [
        "--headless",
        "--clean",
        "+lua io.write(vim.env.VIMRUNTIME)",
        "+q",
    ]).stdout.trim();
    if (!probed) {
        process.stderr.write("check-lua: nvim did not report $VIMRUNTIME\n");
        process.exit(2);
    }
    env.VIMRUNTIME = probed;
}

const logpath = mkdtempSync(join(tmpdir(), "herdr-nav-lls-"));
const result = run(env.LUA_LS_BIN ?? "lua-language-server", [
    `--check=${root}`,
    `--checklevel=${env.CHECKLEVEL ?? "Warning"}`,
    `--logpath=${logpath}`,
]);
rmSync(logpath, { recursive: true, force: true });
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
process.exit(result.status ?? 1);
