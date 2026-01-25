local config = require("review.config")

local M = {}

---@class ReviewLayoutComponent
---@field bufnr number
---@field winid number

---@class ReviewLayout
---@field file_tree ReviewLayoutComponent
---@field diff_view ReviewLayoutComponent

---@type ReviewLayout|nil
M.current = nil

---@type number|nil
M.prev_tab = nil

---Create the main layout with file tree and diff view in a new tab
---@return ReviewLayout
function M.create()
    local opts = config.get()
    local file_tree_width = opts.ui.file_tree_width

    -- Save current tab
    M.prev_tab = vim.api.nvim_get_current_tabpage()

    -- Create new tab
    vim.cmd("tabnew")

    -- Create buffers for file tree and diff view
    local tree_buf = vim.api.nvim_create_buf(false, true)
    local diff_buf = vim.api.nvim_create_buf(false, true)

    -- Set buffer options for file tree
    vim.bo[tree_buf].buftype = "nofile"
    vim.bo[tree_buf].swapfile = false
    vim.bo[tree_buf].filetype = "review-tree"
    vim.bo[tree_buf].modifiable = true
    vim.bo[tree_buf].readonly = false

    -- Set buffer options for diff view
    vim.bo[diff_buf].buftype = "nofile"
    vim.bo[diff_buf].swapfile = false
    vim.bo[diff_buf].filetype = "review-diff"
    vim.bo[diff_buf].modifiable = true
    vim.bo[diff_buf].readonly = false

    -- Current window becomes diff view
    vim.api.nvim_win_set_buf(0, diff_buf)
    local diff_win = vim.api.nvim_get_current_win()

    -- Set diff view window options
    vim.api.nvim_win_set_option(diff_win, "number", true)
    vim.api.nvim_win_set_option(diff_win, "relativenumber", false)
    vim.api.nvim_win_set_option(diff_win, "cursorline", true)
    vim.api.nvim_win_set_option(diff_win, "signcolumn", "yes")
    vim.api.nvim_win_set_option(diff_win, "wrap", false)
    vim.api.nvim_win_set_option(diff_win, "winhighlight", "Normal:Normal,CursorLine:ReviewSelected")

    -- Create vertical split on left for file tree
    local width = math.floor(vim.o.columns * file_tree_width / 100)
    vim.cmd("topleft " .. width .. "vsplit")
    vim.api.nvim_win_set_buf(0, tree_buf)
    local tree_win = vim.api.nvim_get_current_win()

    -- Set file tree window options
    vim.api.nvim_win_set_option(tree_win, "number", false)
    vim.api.nvim_win_set_option(tree_win, "relativenumber", false)
    vim.api.nvim_win_set_option(tree_win, "cursorline", true)
    vim.api.nvim_win_set_option(tree_win, "signcolumn", "no")
    vim.api.nvim_win_set_option(tree_win, "wrap", false)
    vim.api.nvim_win_set_option(tree_win, "winhighlight", "Normal:Normal,CursorLine:ReviewSelected")

    M.current = {
        file_tree = { bufnr = tree_buf, winid = tree_win },
        diff_view = { bufnr = diff_buf, winid = diff_win },
    }

    return M.current
end

---Mount the layout (no-op in tab-based approach, create() does everything)
function M.mount()
    -- Layout is already mounted when create() is called
end

---Unmount the layout
function M.unmount()
    if M.current then
        -- Store buffer references before closing
        local tree_buf = M.current.file_tree.bufnr
        local diff_buf = M.current.diff_view.bufnr
        local prev_tab = M.prev_tab

        M.current = nil
        M.prev_tab = nil

        -- Close the review tab
        pcall(function()
            vim.cmd("tabclose")
        end)

        -- Return to previous tab if it exists
        if prev_tab and vim.api.nvim_tabpage_is_valid(prev_tab) then
            vim.api.nvim_set_current_tabpage(prev_tab)
        end

        -- Delete buffers asynchronously to avoid delay
        vim.schedule(function()
            pcall(function()
                if vim.api.nvim_buf_is_valid(tree_buf) then
                    vim.api.nvim_buf_delete(tree_buf, { force = true })
                end
            end)
            pcall(function()
                if vim.api.nvim_buf_is_valid(diff_buf) then
                    vim.api.nvim_buf_delete(diff_buf, { force = true })
                end
            end)
        end)
    end
end

---Check if layout is mounted
---@return boolean
function M.is_mounted()
    return M.current ~= nil
end

---Get the file tree component
---@return ReviewLayoutComponent|nil
function M.get_file_tree()
    return M.current and M.current.file_tree
end

---Get the diff view component
---@return ReviewLayoutComponent|nil
function M.get_diff_view()
    return M.current and M.current.diff_view
end

return M
