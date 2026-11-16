# Contributing

One repository, two languages, one tool per job. Everything below is enforced by
`npm run verify`, which is what CI runs.

## Toolchain

| File group | Format | Lint / diagnostics | Tests |
|---|---|---|---|
| `plugin/herdr_nav.lua`, `test/plugin_spec.lua` | [stylua](https://github.com/JohnnyMorganz/StyLua) — `stylua.toml` | [lua-language-server](https://github.com/LuaLS/lua-language-server) — `.luarc.json` | `nvim --headless --clean -l` |
| `nav.ts` | [prettier](https://prettier.io) — `.prettierrc.json` | `tsc --noEmit` | `node --test` |
| `test/nav.test.js`, `scripts/*.mjs` | prettier | `tsc --noEmit` | `node --test` |

No second linter per language: lua-language-server is the LSP a contributor
already has open, and its diagnostics cover the undefined globals, unused
locals, `nil`-safety and annotation errors that a separate Lua linter would
report again. ESLint would only restate `tsc` for one file. Do not add either.

`lua-language-server` is pinned to the release named in `ci.yml` (currently
3.19.2). Bump it in the same commit as any change that needs newer diagnostics,
and mention the reason.

## Commands

```sh
npm ci                # tooling only; nav.ts has no runtime dependencies
npm run verify        # typecheck + format check + Lua diagnostics + all tests
npm run lint          # everything except tests
npm test              # node --test + nvim headless
npm run format        # stylua + prettier, writes
npm run check:lua     # LuaLS diagnostics; $LUA_LS_BIN to pick a binary
```

`npm run check:lua` asks Neovim for `$VIMRUNTIME` and hands it to `.luarc.json`,
so `vim.*` resolves without any editor-specific configuration. Set
`CHECKLEVEL=Error` to see only errors.

## Rules

1. **Layout.** 80 columns, 4-space indent. Both formatters enforce it; do not
   hand-wrap against them.
2. **Every Lua function carries a LuaLS docstring**: a one-paragraph summary of
   what it does and why, then `---@param` and `---@return` for every parameter
   and return, then `---@see` where an external document explains the format.
   Shared shapes get `---@class` / `---@alias` in `plugin/herdr_nav.lua`.
   Annotations are checked: an unchecked `nil` or a wrong argument type fails
   `npm run check:lua`.
3. **Zero warnings, not just zero errors.** `.luarc.json` runs the same
   configuration as the editor, and CI fails on `Warning`.
4. **No runtime dependencies.** `nav.ts` runs on bare Node with Node's own
   modules; `devDependencies` are tooling only. Node ≥ 22.18, no build step.
5. **Tests.** A new branch, loop or parser needs a case. `test/nav.test.js`
   spawns a stub `herdr` on `PATH` and asserts the argv it would run;
   `test/plugin_spec.lua` loads the plugin under a given environment. Assertions
   beat snapshots: both harnesses exist so a routing decision can be read.
6. **Startup stays non-blocking.** `plugin/herdr_nav.lua` runs on the startup
   path: never `vim.system(...):wait()` there, and only spawn a subprocess when
   `$HERDR_ENV=1`. The plugin does nothing outside Herdr.
7. **Generated files are not inputs.** `nav.json` belongs to the herdr half and
   is written from `vim.g.herdr_nav.keys`; never hand-edit or commit it.
   `herdr-plugin.toml` holds no environment-specific values — chords live in the
   user's `config.toml` and Neovim config.
8. **Vocabulary.** A "key" is one whole combination such as `alt+h`. Not
   "chord", not "shortcut". `keybinding` is the config entry that binds it.
9. **Failures speak.** `nav.ts` writes `herdr-nav: <message>` to stderr and
   exits non-zero; the Lua half uses `vim.notify(..., vim.log.levels.WARN)`.
   Silence is a bug — a routing mistake with no message is what this project
   exists to avoid.
10. **Two halves stay in step.** Anything added to the herdr half needs its
    Neovim counterpart and the other way round; see the architecture note in the
    README before changing what `nav.json` means.

## Editor setup

Nothing project-specific to configure:

- Neovim: `lua_ls` picks up `.luarc.json` in the repository root, `ts_ls` picks
  up `tsconfig.json`. Format on save with stylua (Lua) and prettier (TS).
- VS Code / other editors: point the Lua language server at the same
  `.luarc.json`, or run `npm run check:lua` in a terminal.

## Before opening a pull request

```sh
npm run verify
```

CI runs the same steps: `typecheck` and `format:ts:check` on Linux and Windows,
`format:lua:check`, `check:lua`, `test:lua`, `test:node` and `self-check` on
Linux.
