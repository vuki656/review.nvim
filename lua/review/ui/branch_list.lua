local git = require("review.core.git")
local state = require("review.state")

local M = {}

---@class BranchEntry
---@field name string
---@field is_current boolean
---@field is_working_changes boolean

---@class BranchListComponent
---@field bufnr number
---@field winid number
---@field branches BranchEntry[]
---@field selected_index number

---@type BranchListComponent|nil
M.current = nil

---@type table
local callbacks = {}

local active_timers = {
    scroll_timer = nil,
}

---Determine which branch entry is currently active based on state
---@param branches BranchEntry[]
---@return number
local function find_active_index(branches)
    local base_end = state.state.base_end

    if base_end == nil or state.state.base == "HEAD" or state.state.base == nil then
        return 1
    end

    for index, entry in ipairs(branches) do
        if not entry.is_working_changes and entry.name == base_end then
            return index
        end
    end

    return 1
end

---Render branches to buffer
---@param bufnr number
---@param branches BranchEntry[]
---@param selected_index number
---@param winid number|nil
local function render(bufnr, branches, selected_index, winid)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true

    local lines = {}
    local highlight_ranges = {}

    for index, entry in ipairs(branches) do
        local is_active = index == selected_index
        local marker = is_active and "* " or "  "
        local current_indicator = entry.is_current and " ●" or ""

        local line = "  " .. marker .. entry.name .. current_indicator
        table.insert(lines, line)

        local offset = 2
        local marker_start = offset
        local marker_end = offset + #marker
        local name_start = marker_end
        local name_end = name_start + #entry.name
        local indicator_start = name_end
        local indicator_end = #line

        table.insert(highlight_ranges, {
            line_index = index - 1,
            marker = { marker_start, marker_end },
            name = { name_start, name_end },
            indicator = current_indicator ~= "" and { indicator_start, indicator_end } or nil,
            is_active = is_active,
            is_current = entry.is_current,
            is_working_changes = entry.is_working_changes,
        })

        if entry.is_working_changes then
            local separator_width = 30
            if winid and vim.api.nvim_win_is_valid(winid) then
                separator_width = vim.api.nvim_win_get_width(winid) - 4
            end
            table.insert(lines, "  " .. string.rep("─", separator_width))
            table.insert(highlight_ranges, { line_index = #lines - 1, is_separator = true })
        end
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    for _, range in ipairs(highlight_ranges) do
        if range.is_separator then
            vim.api.nvim_buf_add_highlight(bufnr, -1, "ReviewBranchSeparator", range.line_index, 0, -1)
        else
            if range.is_active then
                vim.api.nvim_buf_add_highlight(
                    bufnr,
                    -1,
                    "ReviewBranchActive",
                    range.line_index,
                    range.marker[1],
                    range.marker[2]
                )
            end

            local name_highlight
            if range.is_active then
                name_highlight = "ReviewBranchActive"
            elseif range.is_working_changes then
                name_highlight = "ReviewBranchHead"
            else
                name_highlight = "ReviewBranchName"
            end
            vim.api.nvim_buf_add_highlight(bufnr, -1, name_highlight, range.line_index, range.name[1], range.name[2])

            if range.indicator then
                vim.api.nvim_buf_add_highlight(
                    bufnr,
                    -1,
                    "ReviewBranchCurrent",
                    range.line_index,
                    range.indicator[1],
                    range.indicator[2]
                )
            end
        end
    end

    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
end

---Convert a branch list line number (1-indexed) to a branch index
---@param line number
---@return number|nil
local function line_to_branch_index(line)
    if not M.current then
        return nil
    end

    if line <= 1 then
        return 1
    end

    local has_separator = M.current.branches[1] and M.current.branches[1].is_working_changes
    if has_separator and line == 2 then
        return nil
    end

    local branch_index = has_separator and line - 1 or line
    if branch_index > #M.current.branches then
        return nil
    end

    return branch_index
end

---Convert a branch index to a buffer line number (1-indexed)
---@param index number
---@return number
local function branch_index_to_line(index)
    if index <= 1 then
        return 1
    end
    local has_separator = M.current and M.current.branches[1] and M.current.branches[1].is_working_changes
    return has_separator and index + 1 or index
end

---Setup keymaps for the branch list buffer
---@param bufnr number
local function setup_keymaps(bufnr)
    local function map(lhs, rhs, opts)
        opts.buffer = bufnr
        vim.keymap.set("n", lhs, rhs, opts)
    end

    map("j", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local line_count = vim.api.nvim_buf_line_count(M.current.bufnr)
        local next_line = line + 1

        while next_line <= line_count do
            local branch_index = line_to_branch_index(next_line)
            if branch_index then
                break
            end
            next_line = next_line + 1
        end

        if next_line <= line_count then
            vim.api.nvim_win_set_cursor(0, { next_line, 0 })
        end
    end, { nowait = true, desc = "Next branch" })

    map("k", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local prev_line = line - 1

        while prev_line >= 1 do
            local branch_index = line_to_branch_index(prev_line)
            if branch_index then
                break
            end
            prev_line = prev_line - 1
        end

        if prev_line >= 1 then
            vim.api.nvim_win_set_cursor(0, { prev_line, 0 })
        end
    end, { nowait = true, desc = "Previous branch" })

    map("<CR>", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local branch_index = line_to_branch_index(line)
        if not branch_index then
            return
        end

        local entry = M.current.branches[branch_index]
        if not entry then
            return
        end

        if callbacks.on_branch_select then
            callbacks.on_branch_select(entry)
        end
    end, { nowait = true, desc = "Select branch" })

    local function smooth_scroll(direction)
        if active_timers.scroll_timer then
            active_timers.scroll_timer:stop()
            active_timers.scroll_timer:close()
            active_timers.scroll_timer = nil
        end

        local diff_split = require("review.ui.layout").get_diff_view()
        if not diff_split or not diff_split.winid or not vim.api.nvim_win_is_valid(diff_split.winid) then
            return
        end

        local lines = 15
        local delay = 2
        local cmd = direction == "down" and "normal! \x05" or "normal! \x19"

        local iteration = 0
        active_timers.scroll_timer = vim.loop.new_timer()
        active_timers.scroll_timer:start(
            0,
            delay,
            vim.schedule_wrap(function()
                if iteration >= lines then
                    if active_timers.scroll_timer then
                        active_timers.scroll_timer:stop()
                        active_timers.scroll_timer:close()
                        active_timers.scroll_timer = nil
                    end
                    return
                end
                if vim.api.nvim_win_is_valid(diff_split.winid) then
                    vim.api.nvim_win_call(diff_split.winid, function()
                        vim.cmd(cmd)
                    end)
                end
                iteration = iteration + 1
            end)
        )
    end

    map("<C-d>", function()
        smooth_scroll("down")
    end, { nowait = true, desc = "Scroll diff down" })

    map("<C-u>", function()
        smooth_scroll("up")
    end, { nowait = true, desc = "Scroll diff up" })

    local function close_review()
        if callbacks.on_close then
            callbacks.on_close()
        end
    end

    map("q", close_review, { nowait = true, desc = "Close review" })
    map("<Esc>", close_review, { nowait = true, desc = "Close review" })

    -- Cycle to next left pane (branch_list → file_tree)
    map("<Tab>", function()
        local current_layout = require("review.ui.layout")
        local file_tree_component = current_layout.get_file_tree()
        if
            file_tree_component
            and file_tree_component.winid
            and vim.api.nvim_win_is_valid(file_tree_component.winid)
        then
            vim.api.nvim_set_current_win(file_tree_component.winid)
        end
    end, { nowait = true, desc = "Next pane" })

    vim.keymap.set("n", "h", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "l", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Left>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Right>", "<Nop>", { buffer = bufnr, nowait = true })
end

---Create the branch list component
---@param layout_component ReviewLayoutComponent
---@param cbs table { on_branch_select: function, on_close: function }
function M.create(layout_component, cbs)
    callbacks = cbs

    M.current = {
        bufnr = layout_component.bufnr,
        winid = layout_component.winid,
        branches = {},
        selected_index = 1,
    }

    setup_keymaps(layout_component.bufnr)
    vim.wo[layout_component.winid].spell = false

    M.fetch_and_render()

    return M.current
end

---Fetch branches and render
function M.fetch_and_render()
    if not M.current then
        return
    end

    local main_branch = git.get_main_branch()

    git.get_current_branch(function(current_branch)
        if not M.current then
            return
        end

        git.get_local_branches(function(branch_names)
            if not M.current then
                return
            end

            local entries = {
                {
                    name = "Working changes",
                    is_current = false,
                    is_working_changes = true,
                },
            }

            for _, branch_name in ipairs(branch_names) do
                if branch_name ~= main_branch then
                    table.insert(entries, {
                        name = branch_name,
                        is_current = branch_name == current_branch,
                        is_working_changes = false,
                    })
                end
            end

            M.current.branches = entries
            M.current.selected_index = find_active_index(entries)

            render(M.current.bufnr, entries, M.current.selected_index, M.current.winid)

            local cursor_line = branch_index_to_line(M.current.selected_index)
            if vim.api.nvim_win_is_valid(M.current.winid) then
                vim.api.nvim_win_set_cursor(M.current.winid, { cursor_line, 0 })
            end
        end)
    end)
end

---Update the selected branch marker and re-render
---@param entry BranchEntry
function M.set_selected(entry)
    if not M.current then
        return
    end

    for index, branch in ipairs(M.current.branches) do
        if entry.is_working_changes and branch.is_working_changes then
            M.current.selected_index = index
            break
        elseif not entry.is_working_changes and not branch.is_working_changes and entry.name == branch.name then
            M.current.selected_index = index
            break
        end
    end

    render(M.current.bufnr, M.current.branches, M.current.selected_index, M.current.winid)
end

---Refresh the branch list (re-fetch and re-render)
function M.refresh()
    if not M.current then
        return
    end
    M.fetch_and_render()
end

---Destroy the component
function M.destroy()
    for name, timer in pairs(active_timers) do
        if timer then
            timer:stop()
            timer:close()
            active_timers[name] = nil
        end
    end
    callbacks = {}
    M.current = nil
end

return M
