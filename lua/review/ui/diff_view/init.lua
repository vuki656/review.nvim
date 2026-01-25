local unified = require("review.ui.diff_view.unified")
local split = require("review.ui.diff_view.split")
local keymaps = require("review.ui.diff_view.keymaps")
local state = require("review.state")
local git = require("review.core.git")

local M = {}

---@class DiffViewComponent
---@field split NuiSplit
---@field bufnr number
---@field file string
---@field mode "unified"|"split"

---@type DiffViewComponent|nil
M.current = nil

---Create the diff view component
---@param split_component NuiSplit
---@param file string
---@param callbacks table
---@return DiffViewComponent
function M.create(split_component, file, callbacks)
    local bufnr = split_component.bufnr

    M.current = {
        split = split_component,
        bufnr = bufnr,
        file = file,
        mode = state.state.diff_mode,
    }

    -- Render based on mode
    M.render()

    -- Set up keymaps
    keymaps.setup(M.current, {
        on_add_comment = function()
            M.add_comment()
        end,
        on_delete_comment = function()
            M.delete_comment()
        end,
        on_toggle_mode = function()
            M.toggle_mode()
        end,
        on_next_hunk = function()
            M.goto_next_hunk()
        end,
        on_prev_hunk = function()
            M.goto_prev_hunk()
        end,
        on_next_file = function()
            M.goto_next_file()
        end,
        on_prev_file = function()
            M.goto_prev_file()
        end,
        on_close = callbacks.on_close,
    })

    -- Set buffer name
    vim.api.nvim_buf_set_name(bufnr, "Review: " .. file)

    return M.current
end

---Render the diff view
function M.render()
    if not M.current then
        return
    end

    -- Close split mode if active
    split.close()

    if M.current.mode == "unified" then
        unified.render(M.current.bufnr, M.current.file)
    else
        split.render(M.current.split, M.current.file)
    end

    -- Render comments
    M.render_comments()
end

---Render comment markers
function M.render_comments()
    if not M.current or M.current.mode ~= "unified" then
        return
    end

    -- Lazy load comment markers
    local markers = require("review.ui.comment.markers")
    markers.render(M.current.bufnr, M.current.file)
end

---Toggle between unified and split mode
function M.toggle_mode()
    if not M.current then
        return
    end

    if M.current.mode == "unified" then
        M.current.mode = "split"
        state.state.diff_mode = "split"
    else
        M.current.mode = "unified"
        state.state.diff_mode = "unified"
    end

    M.render()
end

---Add a comment at the current cursor position
function M.add_comment()
    if not M.current then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]

    -- Get original line number
    local original_line = nil
    if M.current.mode == "unified" then
        original_line = unified.get_current_source_line()
    end

    -- Open comment input
    local comment_input = require("review.ui.comment.input")
    comment_input.open(M.current.file, line_num, original_line, function()
        M.render_comments()
    end)
end

---Delete comment at the current cursor position
function M.delete_comment()
    if not M.current then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]

    local comment = state.get_comment_at_line(M.current.file, line_num)
    if comment then
        state.remove_comment(M.current.file, comment.id)
        M.render_comments()
        vim.notify("Comment deleted", vim.log.levels.INFO)
    else
        vim.notify("No comment at this line", vim.log.levels.WARN)
    end
end

---Navigate to next hunk
function M.goto_next_hunk()
    if not M.current then
        return
    end

    if M.current.mode == "unified" then
        unified.goto_next_hunk()
    else
        split.goto_next_hunk()
    end
end

---Navigate to previous hunk
function M.goto_prev_hunk()
    if not M.current then
        return
    end

    if M.current.mode == "unified" then
        unified.goto_prev_hunk()
    else
        split.goto_prev_hunk()
    end
end

---Navigate to next file
function M.goto_next_file()
    local files = git.get_changed_files(state.state.base)
    if #files == 0 then
        return
    end

    local current_idx = nil
    for i, f in ipairs(files) do
        if f == state.state.current_file then
            current_idx = i
            break
        end
    end

    if not current_idx then
        return
    end

    local next_idx = current_idx + 1
    if next_idx > #files then
        next_idx = 1
    end

    -- Update and render new file
    local ui = require("review.ui")
    ui.show_diff(files[next_idx])
end

---Navigate to previous file
function M.goto_prev_file()
    local files = git.get_changed_files(state.state.base)
    if #files == 0 then
        return
    end

    local current_idx = nil
    for i, f in ipairs(files) do
        if f == state.state.current_file then
            current_idx = i
            break
        end
    end

    if not current_idx then
        return
    end

    local prev_idx = current_idx - 1
    if prev_idx < 1 then
        prev_idx = #files
    end

    -- Update and render new file
    local ui = require("review.ui")
    ui.show_diff(files[prev_idx])
end

---Get the current component
---@return DiffViewComponent|nil
function M.get()
    return M.current
end

---Destroy the component
function M.destroy()
    split.close()
    unified.clear()
    M.current = nil
end

return M
