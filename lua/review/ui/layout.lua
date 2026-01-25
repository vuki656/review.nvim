local Split = require("nui.split")
local config = require("review.config")

local M = {}

---@class ReviewLayout
---@field file_tree NuiSplit
---@field diff_view NuiSplit

---@type ReviewLayout|nil
M.current = nil

---Create the main layout with file tree and diff view
---@return ReviewLayout
function M.create()
    local opts = config.get()
    local file_tree_width = opts.ui.file_tree_width

    -- Calculate width in columns
    local editor_width = vim.o.columns
    local tree_width = math.floor(editor_width * file_tree_width / 100)

    -- Create file tree split (left panel)
    local file_tree = Split({
        relative = "editor",
        position = "left",
        size = tree_width,
        enter = true,
        buf_options = {
            modifiable = false,
            readonly = true,
            buftype = "nofile",
            swapfile = false,
            filetype = "review-tree",
        },
        win_options = {
            number = false,
            relativenumber = false,
            cursorline = true,
            signcolumn = "no",
            wrap = false,
            winhighlight = "Normal:Normal,CursorLine:ReviewSelected",
        },
    })

    -- Create diff view split (main panel, relative to file tree)
    local diff_view = Split({
        relative = "editor",
        position = "right",
        size = editor_width - tree_width,
        enter = false,
        buf_options = {
            modifiable = false,
            readonly = true,
            buftype = "nofile",
            swapfile = false,
            filetype = "review-diff",
        },
        win_options = {
            number = true,
            relativenumber = false,
            cursorline = true,
            signcolumn = "yes",
            wrap = false,
            winhighlight = "Normal:Normal,CursorLine:ReviewSelected",
        },
    })

    M.current = {
        file_tree = file_tree,
        diff_view = diff_view,
    }

    return M.current
end

---Mount the layout
function M.mount()
    if M.current then
        -- Mount file tree first (left)
        M.current.file_tree:mount()
        -- Then mount diff view (takes remaining space)
        M.current.diff_view:mount()
    end
end

---Unmount the layout
function M.unmount()
    if M.current then
        pcall(function()
            M.current.diff_view:unmount()
        end)
        pcall(function()
            M.current.file_tree:unmount()
        end)
        M.current = nil
    end
end

---Check if layout is mounted
---@return boolean
function M.is_mounted()
    return M.current ~= nil
end

---Get the file tree split
---@return NuiSplit|nil
function M.get_file_tree()
    return M.current and M.current.file_tree
end

---Get the diff view split
---@return NuiSplit|nil
function M.get_diff_view()
    return M.current and M.current.diff_view
end

return M
