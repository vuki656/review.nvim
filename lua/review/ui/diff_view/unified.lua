local diff_parser = require("review.core.diff")
local git = require("review.core.git")
local state = require("review.state")

local M = {}

---@class UnifiedDiffState
---@field bufnr number
---@field file string
---@field parsed_diff ParsedDiff
---@field render_lines DiffLine[]
---@field ns_id number Namespace for extmarks

---@type UnifiedDiffState|nil
M.state = nil

---Create namespace for highlights
local ns_id = vim.api.nvim_create_namespace("review_unified_diff")

---Render a unified diff in the buffer
---@param bufnr number
---@param file string
---@return UnifiedDiffState|nil
function M.render(bufnr, file)
    -- Get diff
    local result = git.get_diff(file, state.state.base)
    if not result.success then
        vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "",
            "  Error getting diff:",
            "  " .. (result.error or "Unknown error"),
        })
        vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
        return nil
    end

    if result.output == "" then
        vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "",
            "  No changes in this file.",
        })
        vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
        return nil
    end

    -- Parse diff
    local parsed = diff_parser.parse(result.output)
    local render_lines = diff_parser.get_render_lines(parsed)

    -- Build display lines
    local display_lines = {}
    for _, line in ipairs(render_lines) do
        table.insert(display_lines, line.raw)
    end

    -- Set buffer content
    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, display_lines)
    vim.api.nvim_buf_set_option(bufnr, "modifiable", false)

    -- Apply highlights
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

    for i, line in ipairs(render_lines) do
        local hl_group = nil
        if line.type == "add" then
            hl_group = "ReviewDiffAdd"
        elseif line.type == "delete" then
            hl_group = "ReviewDiffDelete"
        elseif line.type == "header" then
            hl_group = "ReviewDiffHeader"
        end

        if hl_group then
            vim.api.nvim_buf_add_highlight(bufnr, ns_id, hl_group, i - 1, 0, -1)
        end
    end

    M.state = {
        bufnr = bufnr,
        file = file,
        parsed_diff = parsed,
        render_lines = render_lines,
        ns_id = ns_id,
    }

    return M.state
end

---Get the source line number for the current cursor position
---@return number|nil line, "old"|"new"|nil side
function M.get_current_source_line()
    if not M.state then
        return nil, nil
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]

    return diff_parser.get_source_line(line_num, M.state.render_lines)
end

---Navigate to next hunk
function M.goto_next_hunk()
    if not M.state then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]

    for i, line in ipairs(M.state.render_lines) do
        if i > current_line and line.type == "header" then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            return
        end
    end

    -- Wrap to beginning
    for i, line in ipairs(M.state.render_lines) do
        if line.type == "header" then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            return
        end
    end
end

---Navigate to previous hunk
function M.goto_prev_hunk()
    if not M.state then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]
    local last_header = nil

    for i, line in ipairs(M.state.render_lines) do
        if i >= current_line then
            break
        end
        if line.type == "header" then
            last_header = i
        end
    end

    if last_header then
        vim.api.nvim_win_set_cursor(0, { last_header, 0 })
        return
    end

    -- Wrap to end
    for i = #M.state.render_lines, 1, -1 do
        if M.state.render_lines[i].type == "header" then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            return
        end
    end
end

---Get the current state
---@return UnifiedDiffState|nil
function M.get_state()
    return M.state
end

---Clear state
function M.clear()
    M.state = nil
end

return M
