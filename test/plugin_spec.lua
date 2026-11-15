-- Headless checks for plugin/herdr_nav.lua: which chords it maps, and the
-- guards that keep it inert outside Herdr.
--
--   nvim --headless --clean -l test/plugin_spec.lua

local failures = 0

local function check(name, ok)
    io.write((ok and "ok   " or "FAIL ") .. name .. "\n")
    if not ok then failures = failures + 1 end
end

local plugin = vim.fn.fnamemodify("plugin/herdr_nav.lua", ":p")
local modes = { "n", "t" }

local function unmapped(mode, lhs) return vim.fn.maparg(lhs, mode) == "" end

-- Map state survives dofile(), so each case starts from a clean slate.
local function reset()
    for _, mode in ipairs(modes) do
        for _, lhs in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>", "<C-a>" }) do
            pcall(vim.keymap.del, mode, lhs)
        end
    end
    vim.g.herdr_nav = nil
end

local function load(env, options)
    reset()
    vim.g.herdr_nav = options
    vim.env.HERDR_ENV = env
    vim.env.HERDR_PANE_ID = "pane-1"
    dofile(plugin)
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
check("keys override the chord", not unmapped("n", "<C-a>"))
check("an overridden chord leaves the others alone", unmapped("n", "<C-h>"))
check("keys merge with the defaults", not unmapped("n", "<C-l>"))

load("1", { disabled = true })
check("disabled = true maps nothing", unmapped("n", "<C-h>"))

reset()
vim.env.PATH = vim.fn.tempname()
vim.env.HERDR_BIN_PATH = nil
load("1")
check("no herdr binary maps nothing", unmapped("n", "<C-h>"))

io.write(("%d failure(s)\n"):format(failures))
os.exit(failures == 0 and 0 or 1)
