-- Headless checks for plugin/herdr_nav.lua: which keys it maps, and the
-- guards that keep it inert outside Herdr.
--
--   nvim --headless --clean -l test/plugin_spec.lua

local failures = 0

--- Record the outcome of one check and keep the process exit code honest.
---
--- @param name string One-line description of what was checked.
--- @param ok boolean|nil Whether the expectation held; anything falsy fails.
--- @return nil
local function check(name, ok)
    io.write((ok and "ok   " or "FAIL ") .. name .. "\n")
    if not ok then failures = failures + 1 end
end

local plugin = vim.fn.fnamemodify("plugin/herdr_nav.lua", ":p")
local modes = { "n", "t" }

--- Whether `lhs` has no mapping left in `mode`.
---
--- @param mode string A single mode string understood by `maparg()`, e.g. `"n"`.
--- @param lhs string Key notation to look up, e.g. `"<C-h>"`.
--- @return boolean unmapped True when nothing is bound.
local function unmapped(mode, lhs) return vim.fn.maparg(lhs, mode) == "" end

--- Drop the mappings, options and env a previous case installed.
---
--- Mapping state survives `dofile()`, so every case starts from this slate.
---
--- @return nil
local function reset()
    for _, mode in ipairs(modes) do
        for _, lhs in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>", "<C-a>" }) do
            pcall(vim.keymap.del, mode, lhs)
        end
    end
    vim.g.herdr_nav = nil
    vim.env.HERDR_PLUGIN_CONFIG_DIR = nil
end

--- Source the plugin once under a given environment and set of options.
---
--- @param env string|nil Value for `$HERDR_ENV`; nil simulates a non-herdr terminal.
--- @param options herdr_nav.Options|nil Value for `vim.g.herdr_nav`.
--- @param config_dir string|nil Value for `$HERDR_PLUGIN_CONFIG_DIR`; nil forces the plugin to ask herdr instead.
--- @return nil
local function load(env, options, config_dir)
    reset()
    vim.g.herdr_nav = options
    vim.env.HERDR_ENV = env
    vim.env.HERDR_PANE_ID = "pane-1"
    vim.env.HERDR_PLUGIN_CONFIG_DIR = config_dir
    dofile(plugin)
end

--- Decode `<config_dir>/nav.json`, the file the herdr half reads.
---
--- @param dir string Plugin config dir used for this case.
--- @return table? config Decoded config, or nil when the file is missing or unreadable.
local function nav_json(dir)
    local file = io.open(dir .. "/nav.json", "r")
    if not file then return nil end
    local parsed = select(2, pcall(vim.json.decode, file:read("*a")))
    file:close()
    return type(parsed) == "table" and parsed or nil
end

-- The plugin only maps when it can find the herdr binary.
local stub = vim.fn.tempname()
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, stub)
vim.fn.setfperm(stub, "rwxr-xr-x")
vim.env.HERDR_BIN_PATH = stub

load(nil)
check("outside herdr nothing is mapped", unmapped("n", "<C-h>"))

load("1")
check("inside herdr normal mode is mapped", not unmapped("n", "<C-h>"))
check("inside herdr terminal mode is mapped", not unmapped("t", "<C-h>"))
check("all four directions are mapped", vim.fn.maparg("<C-l>", "n") ~= "")

load("1", { leave_terminal = false })
check("leave_terminal = false skips terminal mode", unmapped("t", "<C-h>"))
check("leave_terminal = false keeps normal mode", not unmapped("n", "<C-h>"))

load("1", { keys = { left = "<C-a>" } })
check("keys override the default key", not unmapped("n", "<C-a>"))
check("an overridden key leaves the others alone", unmapped("n", "<C-h>"))
check("keys merge with the defaults", not unmapped("n", "<C-l>"))

-- nav.json holds what the herdr half writes back; the Neovim half generates it.
local dir = vim.fn.tempname()
load("1", nil, dir)
local written = nav_json(dir)
check(
    "default keys are written to nav.json",
    written
        and written.forward.left == "ctrl+h"
        and written.forward.right == "ctrl+l"
)

vim.fn.mkdir(dir, "p")
vim.fn.writefile(
    { '{"editors":["^cat$"],"forward":{"left":"ctrl+h"}}' },
    dir .. "/nav.json"
)
load("1", { keys = { left = "<A-h>", right = "<D-l>" } }, dir)
written = nav_json(dir)
assert(written, "nav.json exists after the sync")
check("nav.json follows the overridden key", written.forward.left == "alt+h")
check("nav.json converts super", written.forward.right == "super+l")
check("nav.json keeps the other fields", written.editors[1] == "^cat$")

local stat = vim.uv.fs_stat(dir .. "/nav.json")
assert(stat, "nav.json exists before the unchanged check")
load("1", { keys = { left = "<A-h>", right = "<D-l>" } }, dir)
check(
    "an unchanged nav.json is not rewritten",
    vim.uv.fs_stat(dir .. "/nav.json").mtime.nsec == stat.mtime.nsec
)

-- Without the env var the dir comes from `herdr plugin config-dir`, off the
-- startup path, so the file appears after the load returns.
local async_dir = vim.fn.tempname()
local async_stub = vim.fn.tempname()
vim.fn.writefile(
    { "#!/bin/sh", 'printf "%s\\n" "$NAV_DIR"', "exit 0" },
    async_stub
)
vim.fn.setfperm(async_stub, "rwxr-xr-x")
local stub_bin = vim.env.HERDR_BIN_PATH
vim.env.HERDR_BIN_PATH = async_stub
vim.env.NAV_DIR = async_dir
load("1", { keys = { left = "<A-h>" } })
local synced = vim.wait(2000, function() return nav_json(async_dir) ~= nil end)
check(
    "the config dir is asked for asynchronously",
    synced and nav_json(async_dir).forward.left == "alt+h"
)
vim.env.NAV_DIR = nil
vim.env.HERDR_BIN_PATH = stub_bin

load("1", { disabled = true })
check("disabled = true maps nothing", unmapped("n", "<C-h>"))

reset()
vim.env.PATH = vim.fn.tempname()
vim.env.HERDR_BIN_PATH = nil
load("1")
check("no herdr binary maps nothing", unmapped("n", "<C-h>"))

io.write(("%d failure(s)\n"):format(failures))
os.exit(failures == 0 and 0 or 1)
