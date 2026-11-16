# herdr-nav.nvim

`Ctrl+h/j/k/l` moves between editor splits and [Herdr](https://herdr.dev) panes
as if they were one app: inside the editor the key moves between its splits,
and at a split edge it crosses into the neighbouring Herdr pane. In every other
pane the same key moves Herdr's focus.

This is the two-sided design of
[vim-tmux-navigator](https://github.com/christoomey/vim-tmux-navigator), ported
to Herdr:

- **Herdr side** — a Herdr plugin, id `herdr-nav-nvim` (`herdr-plugin.toml`,
  `nav.ts`). Each key press is checked against the pane's foreground process;
  an editor gets the key written back into its pty, anything else moves Herdr's
  focus.
- **Neovim side** — `herdr-nav.nvim` (`plugin/herdr_nav.lua`). Moves between
  windows and, when the window does not change, calls `herdr pane focus`.

One repository, two plugin conventions: Herdr reads `herdr-plugin.toml` at the
root, Neovim reads `plugin/`. The Herdr plugin id is `herdr-nav`, so keybindings
use `herdr-nav-nvim.left/down/up/right`; the Neovim plugin is `herdr-nav.nvim`.

Either half is useless alone once Herdr owns the keys, so install both.

## Requirements

- Herdr ≥ 0.9.5
- Node.js ≥ 22.18 (runs `nav.ts` directly — no build step, no dependencies)
- Neovim with terminal `<C-h/j/k/l>` free (or remapped, see options)

Herdr, Node and Neovim all run on Linux, macOS and Windows. The Windows path
was not exercised during development; the process matcher strips `.exe` and any
leading path, so `nvim.exe` is recognised the same way as `nvim`.

## Install

### 1. Herdr plugin

From GitHub:

```sh
herdr plugin install Jecrevin/herdr-nav.nvim --yes
```

Or from a local checkout:

```sh
herdr plugin link /path/to/herdr-nav.nvim
```

Bind the four actions in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "ctrl+h"
type = "plugin_action"
command = "herdr-nav-nvim.left"
description = "focus left pane / editor left split"

[[keys.command]]
key = "ctrl+j"
type = "plugin_action"
command = "herdr-nav-nvim.down"
description = "focus down pane / editor lower split"

[[keys.command]]
key = "ctrl+k"
type = "plugin_action"
command = "herdr-nav-nvim.up"
description = "focus up pane / editor upper split"

[[keys.command]]
key = "ctrl+l"
type = "plugin_action"
command = "herdr-nav-nvim.right"
description = "focus right pane / editor right split"
```

Reload with `prefix+shift+r`. Check with `herdr plugin action list --plugin
herdr-nav-nvim` and `herdr plugin log list --plugin herdr-nav-nvim`.

The key Herdr writes back into an editor pane is the editor's own mapping,
written to `nav.json` by the Neovim half from `vim.g.herdr_nav.keys`. Editing
the mapping therefore never touches this plugin's `herdr-plugin.toml`. See
[Customising the keys](#customising-the-keys).

### 2. Neovim

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/Jecrevin/herdr-nav.nvim" })
```

With lazy.nvim (no `config` needed — the plugin is zero-config):

```lua
{ "Jecrevin/herdr-nav.nvim", lazy = false }
```

Manually: add the checkout to `runtimepath`, or copy `plugin/herdr_nav.lua` into
your config's `plugin/` directory.

No `setup()` call. The plugin does nothing outside `$HERDR_ENV=1`, so a tmux
setup keeps working through `vim-tmux-navigator`.

## How it works

```
ctrl+h ──► herdr keybind ──► herdr-nav-nvim.left ──► node nav.ts left
                                                  │
                          foreground program owns the key?
                            ├─ yes ─► herdr pane send-keys <pane> ctrl+h
                            │           └─ editor moves; at its edge it calls
                            │              herdr pane focus itself
                            └─ no ──► herdr pane focus --direction left
```

`pane send-keys` writes into the pane's pty, so it cannot re-trigger the
keybinding. Each action runs in the context of the pane the key came from
(`HERDR_PANE_ID`), so multi-client sessions and remote attach behave.

The editor reports its own pane too: Neovim calls `herdr pane focus --pane
$HERDR_PANE_ID`, falling back to `--current` if that id went stale after the
pane moved to another workspace.

## Options

### Herdr side

`nav.json` in `$HERDR_PLUGIN_CONFIG_DIR` (print it with
`herdr plugin config-dir herdr-nav-nvim`), written with defaults on first run:

```json
{
  "forward": { "left": "ctrl+h", "down": "ctrl+j", "up": "ctrl+k", "right": "ctrl+l" },
  "editors": ["^g?(view|l?n?vim?x?)(diff)?$"],
  "passthrough": [],
  "skipWhenZoomed": false
}
```

| Key | Meaning |
|---|---|
| `forward` | Key written into the pane when its program owns the keys. The Neovim half sets it from `vim.g.herdr_nav.keys` on startup; other editors must set it themselves. |
| `editors` | Regexes matched against the lower-cased foreground process name; a match means "the editor owns these keys". |
| `passthrough` | Extra programs that keep the key, e.g. `["^lazygit$"]`. They do not cross out at an edge — use `prefix+h/j/k/l` to leave the pane. |
| `skipWhenZoomed` | Leave a zoomed pane alone instead of moving focus. |

### Neovim side

Set before the plugin is sourced (i.e. in `init.lua`):

```lua
vim.g.herdr_nav = {
  disabled = false,                                    -- set true to opt out
  keys = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
  leave_terminal = true,   -- also map terminal mode (<C-\><C-n> first)
  save_on_switch = 0,      -- 0 none, 1 :update, 2 :wall before crossing out
}
```

Note the two notations: Neovim writes `<C-h>`, Herdr and `nav.ts` write
`ctrl+h`. Which value each side needs is spelled out under [Customising the
keys](#customising-the-keys).

### Customising the keys

A "key" here is a whole combination such as `alt+h`, not a single character.
Two files hold it, and both are yours:

| File | What it decides |
|---|---|
| `~/.config/herdr/config.toml` → `key =` | which combination Herdr intercepts |
| `vim.g.herdr_nav.keys` | which keys Neovim maps, and what Herdr writes back |

Switching to `<A-h/j/k/l>`, for instance to stop shadowing readline's `Ctrl+l`
and `Ctrl+k` in shells:

```toml
# ~/.config/herdr/config.toml
[[keys.command]]
key = "alt+h"
type = "plugin_action"
command = "herdr-nav-nvim.left"
```

```lua
-- init.lua, before the plugin is sourced
vim.g.herdr_nav = {
  keys = { left = "<A-h>", down = "<A-j>", up = "<A-k>", right = "<A-l>" },
}
```

That is the whole change. On startup the Neovim half writes `forward` in
`nav.json` from those keys, so the half that does the writing and the half that
receives agree by construction — a stale value there used to mean the key
arrived with nothing bound to it and navigation silently did nothing. The
notations differ (Neovim's `<A-h>`, Herdr's `alt+h`) but the combination does
not have to.

Nav.json lives in the plugin's config dir — print it with `herdr plugin
config-dir herdr-nav-nvim`. It also holds `editors`, `passthrough` and
`skipWhenZoomed`; those are written with defaults on first run and preserved on
every sync. Editors without a Neovim half must set `forward` by hand; there is
no other way to learn what to send, because Herdr does not tell a plugin action
which key fired it.

Reload Herdr with `prefix+shift+r` after editing the binding.

## Notes

- **`Ctrl+l` and `Ctrl+k` in shells.** Binding them globally shadows readline's
  clear-screen and kill-line. Same tradeoff as `vim-tmux-navigator`; `Alt`
  combinations avoid it but depend on the outer terminal forwarding `alt+h`.
- **`Ctrl+H` vs Backspace** share `0x08` unless the kitty keyboard protocol is
  active. Neovim ≥ 0.10 enables it inside Herdr panes; older Vim may need a
  separate `<BS>` mapping.
- **Windows** is declared as supported but untested; report anything that
  misroutes a key.
- **Herdr ≥ 0.9.5** is required for the plugin APIs used here; a stale
  `HERDR_BIN_PATH` (after `herdr update`) is detected and falls back to `herdr`
  on `PATH`.
- **Marketplace.** This repository carries the `herdr-plugin` topic so
  `herdr plugin install Jecrevin/herdr-nav.nvim` resolves through the Herdr
  plugin index. Add the `herdr-plugin` topic to the GitHub repository.

## Development

```sh
npm ci               # tooling only (no runtime dependencies)
npm run verify       # everything CI runs: lint, tests, self-check
npm test             # node --test test/nav.test.js + nvim --headless -l test/plugin_spec.lua
npm run lint         # tsc --noEmit + stylua/prettier --check + Lua diagnostics
npm run check:lua    # lua-language-server against .luarc.json (zero warnings)
npm run format       # stylua (Lua) + prettier (TypeScript/JavaScript)
npm run self-check   # the process-name matcher, standalone
```

Format, lint and test choices per language, plus the rules a change has to
follow, are in [CONTRIBUTING.md](CONTRIBUTING.md).

`test/nav.test.js` runs `nav.ts` against a stub `herdr` on `PATH` and asserts
which herdr call each key produces; `test/plugin_spec.lua` checks the Neovim
mappings and the guards behind them. CI (`.github/workflows/ci.yml`) runs both
on Ubuntu against Node 22 and Neovim stable.

## License

MIT — see [LICENSE](LICENSE).
