local Split = require("nui.split")
local Layout = require("nui.layout")
local config = require("review.config")

local M = {}

---@class ReviewLayout
---@field layout NuiLayout
---@field file_tree NuiSplit
---@field diff_view NuiSplit

---@type ReviewLayout|nil
M.current = nil

---Create the main layout with file tree and diff view
---@return ReviewLayout
function M.create()
    local opts = config.get()
    local file_tree_width = opts.ui.file_tree_width

    -- Create file tree split (left panel)
    local file_tree = Split({
        relative = "editor",
        position = "left",
        size = file_tree_width .. "%",
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

    -- Create diff view split (main panel)
    local diff_view = Split({
        relative = "editor",
        position = "right",
        size = (100 - file_tree_width) .. "%",
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

    -- Create the layout
    local layout = Layout(
        {
            relative = "editor",
            position = "50%",
            size = {
                width = "100%",
                height = "100%",
            },
        },
        Layout.Box({
            Layout.Box(file_tree, { size = file_tree_width .. "%" }),
            Layout.Box(diff_view, { size = (100 - file_tree_width) .. "%" }),
        }, { dir = "row" })
    )

    M.current = {
        layout = layout,
        file_tree = file_tree,
        diff_view = diff_view,
    }

    return M.current
end

---Mount the layout
function M.mount()
    if M.current then
        M.current.layout:mount()
    end
end

---Unmount the layout
function M.unmount()
    if M.current then
        M.current.layout:unmount()
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
