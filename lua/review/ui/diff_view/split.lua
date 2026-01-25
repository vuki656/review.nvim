local git = require("review.core.git")
local state = require("review.state")

local M = {}

---@class SplitDiffState
---@field file string
---@field old_bufnr number
---@field new_bufnr number
---@field old_winid number
---@field new_winid number

---@type SplitDiffState|nil
M.state = nil

---Create a split diff view using native Vim diff mode
---@param split NuiSplit The main split to use
---@param file string File path
---@return SplitDiffState|nil
function M.render(split, file)
    local winid = split.winid
    local bufnr = split.bufnr

    -- Get old and new content
    local old_content, err = git.get_file_at_rev(file, state.state.base)
    if not old_content then
        vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "",
            "  Error getting old file content:",
            "  " .. (err or "Unknown error"),
        })
        vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
        return nil
    end

    -- Get new content from working directory
    local git_root = git.get_root()
    if not git_root then
        return nil
    end

    local full_path = git_root .. "/" .. file
    local new_content = vim.fn.readfile(full_path)
    if not new_content then
        new_content = {}
    end

    -- Create scratch buffer for old content
    local old_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(old_bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(old_bufnr, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(old_bufnr, "swapfile", false)
    vim.api.nvim_buf_set_name(old_bufnr, "review://old/" .. file)

    local old_lines = vim.split(old_content, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(old_bufnr, 0, -1, false, old_lines)
    vim.api.nvim_buf_set_option(old_bufnr, "modifiable", false)

    -- Detect filetype for syntax highlighting
    local ft = vim.filetype.match({ filename = file })
    if ft then
        vim.api.nvim_buf_set_option(old_bufnr, "filetype", ft)
    end

    -- Create scratch buffer for new content
    local new_bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(new_bufnr, "buftype", "nofile")
    vim.api.nvim_buf_set_option(new_bufnr, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(new_bufnr, "swapfile", false)
    vim.api.nvim_buf_set_name(new_bufnr, "review://new/" .. file)

    vim.api.nvim_buf_set_lines(new_bufnr, 0, -1, false, new_content)
    vim.api.nvim_buf_set_option(new_bufnr, "modifiable", false)

    if ft then
        vim.api.nvim_buf_set_option(new_bufnr, "filetype", ft)
    end

    -- Set up split view
    -- First, show old buffer in current window
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_buf(winid, old_bufnr)
    vim.cmd("diffthis")

    -- Create vertical split for new content
    vim.cmd("vsplit")
    local new_winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(new_winid, new_bufnr)
    vim.cmd("diffthis")

    -- Set window options for both
    for _, w in ipairs({ winid, new_winid }) do
        vim.api.nvim_win_set_option(w, "number", true)
        vim.api.nvim_win_set_option(w, "relativenumber", false)
        vim.api.nvim_win_set_option(w, "cursorline", true)
        vim.api.nvim_win_set_option(w, "foldmethod", "diff")
        vim.api.nvim_win_set_option(w, "foldlevel", 99)
        vim.api.nvim_win_set_option(w, "scrollbind", true)
        vim.api.nvim_win_set_option(w, "cursorbind", true)
    end

    M.state = {
        file = file,
        old_bufnr = old_bufnr,
        new_bufnr = new_bufnr,
        old_winid = winid,
        new_winid = new_winid,
    }

    return M.state
end

---Close split diff view
function M.close()
    if not M.state then
        return
    end

    -- Turn off diff mode
    if vim.api.nvim_win_is_valid(M.state.old_winid) then
        vim.api.nvim_set_current_win(M.state.old_winid)
        vim.cmd("diffoff")
    end

    if vim.api.nvim_win_is_valid(M.state.new_winid) then
        vim.api.nvim_win_close(M.state.new_winid, true)
    end

    -- Clean up buffers
    if vim.api.nvim_buf_is_valid(M.state.old_bufnr) then
        vim.api.nvim_buf_delete(M.state.old_bufnr, { force = true })
    end
    if vim.api.nvim_buf_is_valid(M.state.new_bufnr) then
        vim.api.nvim_buf_delete(M.state.new_bufnr, { force = true })
    end

    M.state = nil
end

---Navigate to next diff
function M.goto_next_hunk()
    vim.cmd("normal! ]c")
end

---Navigate to previous diff
function M.goto_prev_hunk()
    vim.cmd("normal! [c")
end

---Get the current state
---@return SplitDiffState|nil
function M.get_state()
    return M.state
end

return M
