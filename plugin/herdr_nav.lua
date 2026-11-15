-- Neovim half of <C-h/j/k/l> navigation with herdr: move between Neovim
-- windows, hand the edge case to `herdr pane focus`. The herdr half is the
-- herdr-nav plugin (nav.ts), which re-injects the chord into an editor pane.
--
-- Options, set before this file is sourced:
--   vim.g.herdr_nav = {
--     disabled = false,
--     keys = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
--     leave_terminal = true, -- map terminal mode too (<C-\><C-n> first)
--     save_on_switch = 0,    -- 0 none, 1 :update, 2 :wall before leaving
--   }
if vim.env.HERDR_ENV ~= "1" then return end

local defaults = {
    disabled = false,
    keys = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
    leave_terminal = true,
    save_on_switch = 0,
}
local opts = vim.tbl_deep_extend("force", defaults, vim.g.herdr_nav or {})
if opts.disabled then return end

-- HERDR_BIN_PATH is injected by the server and can point at a deleted inode
-- after `herdr update`; fall back to PATH.
local bin = vim.env.HERDR_BIN_PATH
if not bin or vim.fn.executable(bin) ~= 1 then bin = "herdr" end
if vim.fn.executable(bin) ~= 1 then return end

local pane = vim.env.HERDR_PANE_ID
local target = pane and pane ~= "" and { "--pane", pane } or { "--current" }

local wincmd = { left = "h", down = "j", up = "k", right = "l" }

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
    local function navigate()
        local win = vim.api.nvim_get_current_win()
        vim.cmd("wincmd " .. wincmd[direction])
        -- An unchanged window means no split that way: hand it to herdr.
        if vim.api.nvim_get_current_win() ~= win then return end
        if opts.save_on_switch ~= 0 then
            pcall(vim.cmd, opts.save_on_switch == 2 and "wall" or "update")
        end
        focus(direction)
    end

    local desc = "Focus " .. direction .. " pane"
    vim.keymap.set("n", lhs, navigate, { desc = desc, silent = true })
    if opts.leave_terminal then
        vim.keymap.set("t", lhs, function()
            local esc =
                vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true)
            vim.api.nvim_feedkeys(esc, "n", false)
            navigate()
        end, { desc = desc, silent = true })
    end
end
