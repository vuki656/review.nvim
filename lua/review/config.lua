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
---@field log_level string Log level: DEBUG, INFO, WARN, ERROR
---@field log_file string|nil Override the log file path (defaults to a file under the system temp dir)

---@class ReviewKeymaps
---@field toggle string

---@class ReviewDiffConfig
---@field base string Default base for diff comparison

---@class ReviewUIConfig
---@field file_tree_width number Width of file tree panel (percentage)
---@field diff_view_mode "unified"|"split" Default diff view mode
---@field number_navigation boolean Whether to enable numeric section navigation
---@field panels (string[]|table<string, boolean>)|nil Panels to show in sidebar

---@class ReviewTmuxConfig
---@field target string Target window/pane (e.g., "!" for last active pane, or a window name)
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
---@field on_export fun(content: string, comments: table[]): boolean|nil User delivery callback

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

local PANEL_ALIASES = {
    branch_info = "branch_info",
    branch = "branch_info",
    file_tree = "file_tree",
    files = "file_tree",
    tree = "file_tree",
    branch_list = "branch_list",
    branches = "branch_list",
    commit_list = "commit_list",
    commits = "commit_list",
    comment_list = "comment_list",
    comments = "comment_list",
}

local CANONICAL_PANEL_ORDER = { "branch_info", "file_tree", "branch_list", "commit_list", "comment_list" }
local DEFAULT_PANEL_ORDER = { "branch_info", "file_tree", "branch_list", "commit_list", "comment_list" }

---Resolve configured panels option into an ordered list of canonical panel names
---@param panels? string[]|table<string, boolean>
---@return string[]
function M.get_enabled_panels(panels)
    if panels == nil or (type(panels) == "table" and next(panels) == nil) then
        return vim.deepcopy(DEFAULT_PANEL_ORDER)
    end

    local result = {}
    local seen = {}

    if type(panels) == "table" then
        local is_array = false
        if vim.isarray then
            is_array = vim.isarray(panels)
        else
            is_array = (#panels > 0)
        end

        if is_array then
            for _, name in ipairs(panels) do
                local canonical = PANEL_ALIASES[name]
                if canonical and not seen[canonical] then
                    seen[canonical] = true
                    table.insert(result, canonical)
                end
            end
        else
            for _, canonical in ipairs(CANONICAL_PANEL_ORDER) do
                local enabled = true
                for k, v in pairs(panels) do
                    if PANEL_ALIASES[k] == canonical and v == false then
                        enabled = false
                        break
                    end
                end
                if enabled then
                    seen[canonical] = true
                    table.insert(result, canonical)
                end
            end
        end
    end

    if #result == 0 or not seen["file_tree"] then
        if not seen["file_tree"] then
            table.insert(result, 1, "file_tree")
        end
    end

    return result
end

---@type ReviewConfig
M.defaults = {
    keymaps = {
        toggle = nil,
    },
    diff = {
        base = "HEAD", -- Compare against HEAD (unstaged changes)
    },
    ui = {
        file_tree_width = 33,
        diff_view_mode = "unified",
        number_navigation = false,
        panels = { "branch_info", "file_tree", "branch_list", "commit_list", "comment_list" },
    },
    tmux = {
        target = "!",
        auto_enter = false,
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
        on_export = nil,
    },
    auto_refresh = {
        enabled = true,
        debounce_ms = 500,
    },
    persistence = {
        enabled = true,
    },
    log_level = "WARN",
    log_file = nil,
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
M.options = vim.deepcopy(M.defaults)

M.did_setup = false

---@param opts? ReviewConfig
function M.setup(opts)
    if opts ~= nil and type(opts) ~= "table" then
        vim.notify("review.nvim: setup() expects a table, got " .. type(opts), vim.log.levels.ERROR)
        opts = nil
    end
    M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
    M.did_setup = true
end

---@return ReviewConfig
function M.get()
    return M.options
end

return M
