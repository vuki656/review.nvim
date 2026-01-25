local layout = require("review.ui.layout")
local file_tree = require("review.ui.file_tree")
local highlights = require("review.ui.highlights")
local state = require("review.state")

local M = {}

---@type table|nil
M.diff_view_component = nil

---Initialize the UI
function M.setup()
    highlights.setup()
end

---Open the review UI
function M.open()
    if state.state.is_open then
        return
    end

    -- Create and mount layout
    local l = layout.create()
    layout.mount()

    state.state.is_open = true

    -- Initialize file tree
    file_tree.create(l.file_tree, {
        on_file_select = function(path)
            M.show_diff(path)
        end,
        on_close = function()
            M.close()
        end,
        on_refresh = function()
            -- Refresh diff view if a file is selected
            if state.state.current_file then
                M.show_diff(state.state.current_file)
            end
        end,
    })

    -- Show welcome message in diff view
    M.show_welcome()

    -- Focus file tree
    local file_tree_split = layout.get_file_tree()
    if file_tree_split and file_tree_split.winid then
        vim.api.nvim_set_current_win(file_tree_split.winid)
    end
end

---Show welcome message in diff view
function M.show_welcome()
    local diff_split = layout.get_diff_view()
    if not diff_split then
        return
    end

    local bufnr = diff_split.bufnr
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true

    local welcome = {
        "",
        "  Review Mode",
        "",
        "  Select a file from the left panel to view changes.",
        "",
        "  Keybindings:",
        "    <CR>  - Select file / toggle directory",
        "    <Tab> - Toggle tree/flat view",
        "    r     - Mark as reviewed (stage)",
        "    u     - Unmark (unstage)",
        "    R     - Refresh file list",
        "    q     - Close review UI",
        "",
        "  In diff view:",
        "    c     - Add comment",
        "    dc    - Delete comment",
        "    ]c/[c - Next/prev hunk",
        "    ]f/[f - Next/prev file",
        "",
    }

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, welcome)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true

    -- Apply title highlight
    vim.api.nvim_buf_add_highlight(bufnr, -1, "ReviewTitle", 1, 0, -1)
end

---Show diff for a file
---@param path string
function M.show_diff(path)
    state.state.current_file = path

    -- Lazy load diff view module
    local diff_view = require("review.ui.diff_view")

    local diff_split = layout.get_diff_view()
    if not diff_split then
        return
    end

    -- Create or update diff view
    M.diff_view_component = diff_view.create(diff_split, path, {
        on_close = function()
            M.close()
        end,
    })
end

---Close the review UI
function M.close()
    if not state.state.is_open then
        return
    end

    -- Destroy components
    file_tree.destroy()

    if M.diff_view_component then
        local diff_view = require("review.ui.diff_view")
        diff_view.destroy()
        M.diff_view_component = nil
    end

    -- Unmount layout
    layout.unmount()

    state.state.is_open = false
end

---Toggle the review UI
function M.toggle()
    if state.state.is_open then
        M.close()
    else
        M.open()
    end
end

---Check if UI is open
---@return boolean
function M.is_open()
    return state.state.is_open
end

return M
