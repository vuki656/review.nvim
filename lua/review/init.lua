local commands = require("review.commands")
local config = require("review.config")
local export = require("review.export.markdown")
local log = require("review.core.log")
local persistence = require("review.core.persistence")
local quick_comments = require("review.quick_comments")
local state = require("review.state")
local ui = require("review.ui")

local M = {}

---Setup the plugin
---@param opts? ReviewConfig
function M.setup(opts)
    -- Initialize config
    config.setup(opts)
    local cfg = config.get()

    -- Initialize logging
    log.setup(cfg.log_level, cfg.log_file)
    log.info("review.nvim setup complete")

    -- Initialize state with config defaults
    state.state.diff_mode = cfg.ui.diff_view_mode
    state.state.base = cfg.diff.base

    -- Set up UI
    ui.setup()

    -- Set up commands
    commands.setup()

    -- Set up quick comments
    quick_comments.setup()

    -- Set up session persistence
    if cfg.persistence.enabled then
        persistence.setup_autosave()
    end

    -- Set up keymaps
    if cfg.keymaps.toggle then
        vim.keymap.set("n", cfg.keymaps.toggle, function()
            M.toggle()
        end, { desc = "Toggle review UI" })
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

---Send comments through the export callback, or to a tmux pane
---@param target? string Optional target pane, tmux only (defaults to config)
function M.send(target)
    export.send(target)
end

---Send quick comments through the export callback, or to a tmux pane
---@param target? string Optional target pane, tmux only (defaults to config)
---@param opts? { clear?: boolean, silent?: boolean }
---@return boolean success
function M.quick_send(target, opts)
    return quick_comments.send(target, opts)
end

---Clear all review comments, asking for confirmation when any exist
function M.clear_comments()
    ui.clear_comments()
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
