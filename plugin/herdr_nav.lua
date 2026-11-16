-- Neovim half of <C-h/j/k/l> navigation with herdr: move between Neovim
-- windows, hand the edge case to `herdr pane focus`. The herdr half is the
-- herdr-nav plugin (nav.ts), which re-injects the key into an editor pane.
--
-- Options, set before this file is sourced:
--   vim.g.herdr_nav = {
--     disabled = false,
--     keys = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
--     leave_terminal = true, -- map terminal mode too (<C-\><C-n> first)
--     save_on_switch = 0,    -- 0 none, 1 :update, 2 :wall before leaving
--   }
---@alias herdr_nav.Direction "left"|"down"|"up"|"right"

--- Options, read once when this file is sourced.
---
--- Set them in `vim.g.herdr_nav` before the plugin loads:
---
--- ```lua
--- vim.g.herdr_nav = { keys = { left = "<A-h>" } }
--- ```
---
---@class herdr_nav.Options
---@field disabled? boolean Leave every key alone, e.g. to keep vim-tmux-navigator.
---@field keys? table<herdr_nav.Direction, string> Neovim key notation per direction; nav.json is derived from it.
---@field leave_terminal? boolean Map terminal mode too, escaping with `<C-\><C-n>` first.
---@field save_on_switch? 0|1|2 0 none, 1 `:update`, 2 `:wall` before crossing a pane edge.
if vim.env.HERDR_ENV ~= "1" then return end

local defaults = {
    disabled = false,
    keys = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
    leave_terminal = true,
    save_on_switch = 0,
}
---@type herdr_nav.Options
local opts = vim.tbl_deep_extend("force", defaults, vim.g.herdr_nav or {})
if opts.disabled then return end

-- HERDR_BIN_PATH is injected by the server and can point at a deleted inode
-- after `herdr update`; fall back to PATH.
local bin = vim.env.HERDR_BIN_PATH
if not bin or vim.fn.executable(bin) ~= 1 then bin = "herdr" end
if vim.fn.executable(bin) ~= 1 then return end

local pane = vim.env.HERDR_PANE_ID
--- This Neovim's pane, or whatever herdr has focused if the id is missing.
---@type string[]
local target = pane and pane ~= "" and { "--pane", pane } or { "--current" }

-- The herdr half writes `forward` back into the pane, and `forward` lives in
-- nav.json, so keep nav.json in step with `keys`: customising the mappings must
-- not need a third file edited by hand.
--- Neovim modifier letters to herdr's names, used by `herdr_key`.
---@type table<string, string>
local MODS = { A = "alt", C = "ctrl", S = "shift", D = "super" }

--- Translate a Neovim key notation into the syntax herdr accepts.
---
--- `"<A-h>"` becomes `"alt+h"`, `"<C-S-j>"` becomes `"ctrl+shift+j"`,
--- `"<D-l>"` becomes `"super+l"`.
---
--- @param lhs string Neovim key notation, e.g. `"<A-h>"`.
--- @return string? key herdr key syntax, e.g. `"alt+h"`; nil when `lhs` has no
--- `<...>` wrapper, no key inside it, or a modifier herdr does not name.
--- @see https://herdr.dev for the key syntax herdr parses
local function herdr_key(lhs)
    local inner = lhs:match("^<(.-)>$")
    if not inner then return nil end
    local parts = vim.split(inner, "-", { plain = true })
    local key = table.remove(parts)
    if not key or key == "" then return nil end
    local mods = {}
    for _, mod in ipairs(parts) do
        local name = MODS[mod]
        if not name then return nil end
        mods[#mods + 1] = name
    end
    return table.concat(mods, "+") .. (#mods > 0 and "+" or "") .. key
end

--- Write `forward` in the herdr-nav plugin's `nav.json`.
---
--- nav.json is the only thing the herdr half (`nav.ts`) reads to decide which
--- key to write back into this pane, so it has to agree with `opts.keys`; a
--- stale value there means the key arrives with nothing bound to it and
--- navigation silently does nothing.
---
--- Everything else in the file (`editors`, `passthrough`, `skipWhenZoomed`, and
--- any direction already in `forward`) is preserved, and nothing is written
--- unless a value actually changed, so an ordinary start touches no file.
---
--- @param dir string The plugin config dir, from `herdr plugin config-dir
--- herdr-nav-nvim`.
--- @return nil
local function write_forward(dir)
    local path = dir .. "/nav.json"
    local config = {}
    local file = io.open(path, "r")
    if file then
        local parsed = select(2, pcall(vim.json.decode, file:read("*a")))
        file:close()
        if type(parsed) == "table" then config = parsed end
    end
    config.forward = config.forward or {}

    local changed = false
    for direction, lhs in pairs(opts.keys) do
        local key = herdr_key(lhs)
        if not key then
            vim.notify(
                ("herdr-nav: cannot express %s in herdr key syntax"):format(lhs),
                vim.log.levels.WARN
            )
        elseif config.forward[direction] ~= key then
            config.forward[direction] = key
            changed = true
        end
    end
    if not changed then return end

    vim.fn.mkdir(dir, "p")
    local out = io.open(path, "w")
    if not out then return end
    out:write(vim.json.encode(config) .. "\n")
    out:close()
end

--- Bring nav.json in line with `opts.keys`, off the startup path.
---
--- Herdr exports `HERDR_PLUGIN_CONFIG_DIR` to plugin actions only, so a Neovim
--- started from a pane has to ask herdr for the directory. That spawn is
--- asynchronous on purpose: a synchronous wait here charges the subprocess
--- latency to every single startup.
---
--- @return nil
local function sync_forward()
    -- Set for plugin actions; a Neovim started from a pane has to ask.
    local dir = vim.env.HERDR_PLUGIN_CONFIG_DIR
    if dir then
        write_forward(dir)
        return
    end
    vim.system(
        { bin, "plugin", "config-dir", "herdr-nav-nvim" },
        { text = true },
        function(out)
            vim.schedule(function()
                local path = out.code == 0 and vim.trim(out.stdout or "") or ""
                if path ~= "" then write_forward(path) end
            end)
        end
    )
end

sync_forward()

--- Which `wincmd` letter moves a window in each direction.
---@type table<herdr_nav.Direction, string>
local wincmd = { left = "h", down = "j", up = "k", right = "l" }

--- Move herdr's focus one pane in `direction`.
---
--- Fire and forget: the call is asynchronous and its result is only used for
--- the stale-pane retry. `HERDR_PANE_ID` is captured when this Neovim starts
--- and goes stale if the pane moves to another workspace, so a failed `--pane`
--- call is retried once against whatever herdr currently considers focused.
---
--- @param direction herdr_nav.Direction Edge to cross.
--- @return nil
local function focus(direction)
    vim.system(
        { bin, "pane", "focus", "--direction", direction, unpack(target) },
        {},
        function(out)
            -- A pane id captured when this Neovim started goes stale if the pane
            -- moves to another workspace; retry against the caller's pane.
            if out.code ~= 0 and target[1] == "--pane" then
                vim.system({
                    bin,
                    "pane",
                    "focus",
                    "--direction",
                    direction,
                    "--current",
                })
            end
        end
    )
end

for direction, lhs in pairs(opts.keys) do
    --- Move to the neighbouring Neovim window, or hand the edge to herdr.
    ---
    --- `wincmd` is the whole move; an unchanged window means there is no split
    --- in that direction, so the key belongs to herdr instead. `save_on_switch`
    --- is honoured only on that edge, which is also the moment the buffer stops
    --- being visible.
    ---
    --- @return nil
    local function navigate()
        local win = vim.api.nvim_get_current_win()
        vim.cmd("wincmd " .. wincmd[direction])
        -- An unchanged window means no split that way: hand it to herdr.
        if vim.api.nvim_get_current_win() ~= win then return end
        if opts.save_on_switch ~= 0 then
            local save = opts.save_on_switch == 2 and "wall" or "update"
            pcall(function() vim.cmd(save) end)
        end
        focus(direction)
    end

    --- Leave terminal mode, then navigate as in normal mode.
    ---
    --- A terminal has no `wincmd`, and the terminal job owns the keys, so the
    --- mapping first feeds `<C-\\><C-n>` with `n` (no remap) to get back to
    --- normal mode without looping through this mapping again.
    ---
    --- @return nil
    local function navigate_terminal()
        local esc =
            vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
        vim.api.nvim_feedkeys(esc, "n", false)
        navigate()
    end

    local desc = "Focus " .. direction .. " pane"
    vim.keymap.set("n", lhs, navigate, { desc = desc, silent = true })
    if opts.leave_terminal then
        vim.keymap.set("t", lhs, navigate_terminal, {
            desc = desc,
            silent = true,
        })
    end
end
