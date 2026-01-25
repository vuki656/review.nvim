local config = require("review.config")
local state = require("review.state")
local commands = require("review.commands")
local ui = require("review.ui")
local export = require("review.export.markdown")

local M = {}

---Setup the plugin
---@param opts? ReviewConfig
function M.setup(opts)
    -- Initialize config
    config.setup(opts)
    local cfg = config.get()

    -- Initialize state with config defaults
    state.state.diff_mode = cfg.ui.diff_view_mode
    state.state.base = cfg.diff.base

    -- Set up UI
    ui.setup()

    -- Set up commands
    commands.setup()

    -- Set up keymaps
    if cfg.keymaps.toggle then
        vim.keymap.set("n", cfg.keymaps.toggle, function()
            M.toggle()
        end, { desc = "Toggle review UI" })
    end

    if cfg.keymaps.send_to_tmux then
        vim.keymap.set("n", cfg.keymaps.send_to_tmux, function()
            M.send()
        end, { desc = "Send review comments to tmux" })
    end
end

---Toggle the review UI
function M.toggle()
    ui.toggle()
end

---Open the review UI
function M.open()
    ui.open()
end

---Close the review UI
function M.close()
    ui.close()
end

---Export comments to clipboard
function M.export()
    export.to_clipboard()
end

---Send comments to tmux pane
---@param target? string Optional target pane (defaults to config)
function M.send(target)
    export.to_tmux(target)
end

---Check if UI is open
---@return boolean
function M.is_open()
    return ui.is_open()
end

---Get current state (for debugging/testing)
---@return ReviewState
function M.get_state()
    return state.state
end

---Reset state (for testing)
function M.reset()
    state.reset()
end

return M
