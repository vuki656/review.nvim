---@class ReviewConfig
---@field keymaps ReviewKeymaps
---@field diff ReviewDiffConfig
---@field ui ReviewUIConfig
---@field tmux ReviewTmuxConfig

---@class ReviewKeymaps
---@field toggle string
---@field send_to_tmux string

---@class ReviewDiffConfig
---@field base string Default base for diff comparison

---@class ReviewUIConfig
---@field file_tree_width number Width of file tree panel (percentage)
---@field diff_view_mode "unified"|"split" Default diff view mode
---@field group_reviewed boolean Group reviewed files at bottom (faded)

---@class ReviewTmuxConfig
---@field target string Target window/pane name (e.g., "CLAUDE" or "CLAUDE.0")
---@field auto_enter boolean Whether to send Enter key after pasting

local M = {}

---@type ReviewConfig
M.defaults = {
    keymaps = {
        toggle = "<leader>lr",
        send_to_tmux = "<leader>ls",
    },
    diff = {
        base = "HEAD", -- Compare against HEAD (unstaged changes)
    },
    ui = {
        file_tree_width = 25,
        diff_view_mode = "unified",
        group_reviewed = true,
    },
    tmux = {
        target = "CLAUDE",    -- Target window name
        auto_enter = false,   -- Don't auto-submit, let user review first
    },
}

---@type ReviewConfig
M.options = {}

---@param opts? ReviewConfig
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

---@return ReviewConfig
function M.get()
    return M.options
end

return M
