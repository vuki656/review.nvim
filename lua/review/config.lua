---@class ReviewConfig
---@field keymaps ReviewKeymaps
---@field diff ReviewDiffConfig
---@field ui ReviewUIConfig
---@field tmux ReviewTmuxConfig
---@field quick_comments ReviewQuickCommentsConfig
---@field export ReviewExportConfig
---@field auto_refresh ReviewAutoRefreshConfig
---@field persistence ReviewPersistenceConfig
---@field templates ReviewTemplate[]

---@class ReviewKeymaps
---@field toggle string

---@class ReviewDiffConfig
---@field base string Default base for diff comparison

---@class ReviewUIConfig
---@field file_tree_width number Width of file tree panel (percentage)
---@field diff_view_mode "unified"|"split" Default diff view mode
---@field group_reviewed boolean Group reviewed files at bottom (faded)

---@class ReviewTmuxConfig
---@field target string Target window/pane name (e.g., "CLAUDE" or "CLAUDE.0")
---@field auto_enter boolean Whether to send Enter key after pasting

---@class ReviewQuickCommentsConfig
---@field keymaps ReviewQuickCommentsKeymaps
---@field panel ReviewQuickCommentsPanelConfig
---@field signs ReviewQuickCommentsSignsConfig

---@class ReviewQuickCommentsKeymaps
---@field add string|nil Keymap to add a quick comment
---@field toggle_panel string|nil Keymap to toggle the quick comments panel

---@class ReviewQuickCommentsPanelConfig
---@field width number Panel width in columns
---@field position "left"|"right" Panel position

---@class ReviewQuickCommentsSignsConfig
---@field enabled boolean Whether to show gutter signs

---@class ReviewExportConfig
---@field context_lines number Number of context lines to include around commented line

---@class ReviewAutoRefreshConfig
---@field enabled boolean Whether to auto-refresh on file changes
---@field debounce_ms number Debounce interval in milliseconds

---@class ReviewPersistenceConfig
---@field enabled boolean Whether to persist review sessions

---@class ReviewTemplate
---@field key string Single character shortcut key
---@field label string Display label
---@field text string Template text to insert

local M = {}

---@type ReviewConfig
M.defaults = {
    keymaps = {
        toggle = nil,
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
        target = "CLAUDE", -- Target window name
        auto_enter = false, -- Don't auto-submit, let user review first
    },
    quick_comments = {
        keymaps = {
            add = nil,
            toggle_panel = nil,
        },
        panel = {
            width = 65,
            position = "right",
        },
        signs = {
            enabled = true,
        },
    },
    export = {
        context_lines = 3,
    },
    auto_refresh = {
        enabled = true,
        debounce_ms = 500,
    },
    persistence = {
        enabled = true,
    },
    templates = {
        { key = "e", label = "Extract", text = "Extract this into a separate function/component" },
        { key = "r", label = "Rename", text = "Rename to: " },
        { key = "m", label = "Move", text = "Move this to a separate file" },
        { key = "t", label = "Types", text = "Add proper types" },
        { key = "h", label = "Error handling", text = "Add error handling" },
        { key = "p", label = "Performance", text = "Performance concern: " },
        { key = "s", label = "Simplify", text = "Simplify this" },
        { key = "d", label = "Delete", text = "Remove this" },
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
