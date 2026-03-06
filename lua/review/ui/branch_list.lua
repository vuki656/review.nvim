local git = require("review.core.git")
local state = require("review.state")
local ui_util = require("review.ui.util")

local M = {}

---@class BranchEntry
---@field name string
---@field is_current boolean
---@field is_main boolean

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

local row_hl_ns = vim.api.nvim_create_namespace("review_branch_row_hl")
local pull_ns = vim.api.nvim_create_namespace("review_branch_pull")
local checkout_ns = vim.api.nvim_create_namespace("review_branch_checkout")

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@type uv_timer_t|nil
local pull_spinner_timer = nil

---@type number|nil
local pull_line_index = nil

---@type uv_timer_t|nil
local checkout_spinner_timer = nil

---@type number|nil
local checkout_line_index = nil

---Determine which branch entry is currently active based on state
---@param branches BranchEntry[]
---@return number|nil
local function find_active_index(branches)
    local base_end = state.state.base_end

    if base_end == nil or state.state.base == "HEAD" or state.state.base == nil then
        return nil
    end

    for index, entry in ipairs(branches) do
        if entry.name == base_end then
            return index
        end
    end

    return nil
end

---Build sync count suffix string
---@param sync_counts table<string, {ahead: number, behind: number}>
---@param branch_name string
---@return string suffix, string|nil ahead_segment, string|nil behind_segment
local function build_sync_suffix(sync_counts, branch_name)
    local counts = sync_counts[branch_name]
    if not counts then
        return "", nil, nil
    end

    local ahead_str = counts.ahead > 0 and (" ↑" .. counts.ahead) or ""
    local behind_str = counts.behind > 0 and (" ↓" .. counts.behind) or ""

    return ahead_str .. behind_str, ahead_str, behind_str
end

---Render branches to buffer
---@param bufnr number
---@param branches BranchEntry[]
---@param selected_index number
---@param _winid number|nil
---@param sync_counts table<string, {ahead: number, behind: number}>|nil
local function render(bufnr, branches, selected_index, _winid, sync_counts)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    sync_counts = sync_counts or {}

    ui_util.with_modifiable(bufnr, function()
    local lines = {}
    local highlight_ranges = {}

    for index, entry in ipairs(branches) do
        local is_active = index == selected_index
        local marker = is_active and " ▎" or "  "
        local node = is_active and "● " or "○ "
        local head_suffix = entry.is_current and " HEAD" or ""
        local sync_suffix, ahead_str, behind_str = build_sync_suffix(sync_counts, entry.name)

        local line = marker .. node .. entry.name .. head_suffix .. sync_suffix
        table.insert(lines, line)

        local offset = 0
        local marker_end = offset + #marker
        local node_start = marker_end
        local node_end = node_start + #node
        local name_start = node_end
        local name_end = name_start + #entry.name
        local head_label_start = name_end
        local head_label_end = head_label_start + #head_suffix
        local ahead_start = head_label_end
        local ahead_end = ahead_start + (ahead_str and #ahead_str or 0)
        local behind_start = ahead_end
        local behind_end = behind_start + (behind_str and #behind_str or 0)

        table.insert(highlight_ranges, {
            line_index = index - 1,
            marker = { offset, marker_end },
            node = { node_start, node_end },
            name = { name_start, name_end },
            head_label = entry.is_current and { head_label_start, head_label_end } or nil,
            ahead = (ahead_str and #ahead_str > 0) and { ahead_start, ahead_end } or nil,
            behind = (behind_str and #behind_str > 0) and { behind_start, behind_end } or nil,
            is_active = is_active,
            is_current = entry.is_current,
            is_main = entry.is_main,
        })
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(bufnr, row_hl_ns, 0, -1)

    for _, range in ipairs(highlight_ranges) do
        if range.is_active then
            vim.api.nvim_buf_add_highlight(
                bufnr,
                -1,
                "ReviewBranchActive",
                range.line_index,
                range.marker[1],
                range.marker[2]
            )
            vim.api.nvim_buf_set_extmark(bufnr, row_hl_ns, range.line_index, 0, {
                line_hl_group = "ReviewActiveRow",
            })
        end

        local node_hl = range.is_active and "ReviewBranchActive" or "ReviewBranchCurrent"
        vim.api.nvim_buf_add_highlight(bufnr, -1, node_hl, range.line_index, range.node[1], range.node[2])

        local name_highlight
        if range.is_active then
            name_highlight = "ReviewBranchActive"
        elseif range.is_current then
            name_highlight = "ReviewBranchCurrent"
        elseif range.is_main then
            name_highlight = "ReviewBranchMain"
        else
            name_highlight = "ReviewBranchName"
        end
        vim.api.nvim_buf_add_highlight(bufnr, -1, name_highlight, range.line_index, range.name[1], range.name[2])

        if range.head_label then
            vim.api.nvim_buf_add_highlight(
                bufnr,
                -1,
                "ReviewHeadLabel",
                range.line_index,
                range.head_label[1],
                range.head_label[2]
            )
        end

        if range.ahead then
            vim.api.nvim_buf_add_highlight(
                bufnr, -1, "ReviewBranchAhead", range.line_index, range.ahead[1], range.ahead[2]
            )
        end

        if range.behind then
            vim.api.nvim_buf_add_highlight(
                bufnr, -1, "ReviewBranchBehind", range.line_index, range.behind[1], range.behind[2]
            )
        end
    end

    end)
end

---Convert a branch list line number (1-indexed) to a branch index
---@param line number
---@return number|nil
local function line_to_branch_index(line)
    if not M.current then
        return nil
    end

    if line < 1 or line > #M.current.branches then
        return nil
    end

    return line
end

---Convert a branch index to a buffer line number (1-indexed)
---@param index number
---@return number
local function branch_index_to_line(index)
    return math.max(1, index)
end

---Setup keymaps for the branch list buffer
---@param bufnr number
local function setup_keymaps(bufnr)
    local map = ui_util.create_buffer_mapper(bufnr)

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

    map("p", function()
        if not M.current then
            return
        end

        if pull_spinner_timer then
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

        pull_line_index = line - 1
        local saved_cursor_line = line
        local frame = 0

        pull_spinner_timer = vim.uv.new_timer()
        pull_spinner_timer:start(0, 80, vim.schedule_wrap(function()
            if not M.current or not vim.api.nvim_buf_is_valid(M.current.bufnr) then
                if pull_spinner_timer then
                    pull_spinner_timer:stop()
                    pull_spinner_timer:close()
                    pull_spinner_timer = nil
                end
                return
            end

            frame = (frame % #SPINNER_FRAMES) + 1

            vim.api.nvim_buf_clear_namespace(M.current.bufnr, pull_ns, pull_line_index, pull_line_index + 1)
            vim.api.nvim_buf_set_extmark(M.current.bufnr, pull_ns, pull_line_index, 0, {
                virt_text = { { " " .. SPINNER_FRAMES[frame], "ReviewBranchSpinner" } },
                virt_text_pos = "eol",
            })
        end))

        git.pull(function(success, err)
            if pull_spinner_timer then
                pull_spinner_timer:stop()
                pull_spinner_timer:close()
                pull_spinner_timer = nil
            end

            if M.current and vim.api.nvim_buf_is_valid(M.current.bufnr) then
                vim.api.nvim_buf_clear_namespace(M.current.bufnr, pull_ns, 0, -1)
            end

            pull_line_index = nil

            if success then
                M.fetch_and_render(saved_cursor_line)
            else
                vim.notify("Pull failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
            end
        end)
    end, { nowait = true, desc = "Pull from remote" })

    map("<Space>", function()
        if not M.current then
            return
        end

        if checkout_spinner_timer then
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

        if entry.is_current then
            return
        end

        checkout_line_index = line - 1
        local frame = 0

        checkout_spinner_timer = vim.uv.new_timer()
        checkout_spinner_timer:start(0, 80, vim.schedule_wrap(function()
            if not M.current or not vim.api.nvim_buf_is_valid(M.current.bufnr) then
                if checkout_spinner_timer then
                    checkout_spinner_timer:stop()
                    checkout_spinner_timer:close()
                    checkout_spinner_timer = nil
                end
                return
            end

            frame = (frame % #SPINNER_FRAMES) + 1

            vim.api.nvim_buf_clear_namespace(M.current.bufnr, checkout_ns, checkout_line_index, checkout_line_index + 1)
            vim.api.nvim_buf_set_extmark(M.current.bufnr, checkout_ns, checkout_line_index, 0, {
                virt_text = { { " " .. SPINNER_FRAMES[frame], "ReviewBranchSpinner" } },
                virt_text_pos = "eol",
            })
        end))

        git.has_dirty_worktree(function(is_dirty)
            if is_dirty then
                if checkout_spinner_timer then
                    checkout_spinner_timer:stop()
                    checkout_spinner_timer:close()
                    checkout_spinner_timer = nil
                end

                if M.current and vim.api.nvim_buf_is_valid(M.current.bufnr) then
                    vim.api.nvim_buf_clear_namespace(M.current.bufnr, checkout_ns, 0, -1)
                end

                checkout_line_index = nil
                local message = "Checkout failed: you have uncommitted changes. Stash or commit them first."
                vim.notify(message, vim.log.levels.ERROR)
                return
            end

            git.checkout(entry.name, function(success, err)
                if checkout_spinner_timer then
                    checkout_spinner_timer:stop()
                    checkout_spinner_timer:close()
                    checkout_spinner_timer = nil
                end

                if M.current and vim.api.nvim_buf_is_valid(M.current.bufnr) then
                    vim.api.nvim_buf_clear_namespace(M.current.bufnr, checkout_ns, 0, -1)
                end

                checkout_line_index = nil

                if success then
                    M.fetch_and_render(line)
                else
                    vim.notify("Checkout failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
                end
            end)
        end)
    end, { nowait = true, desc = "Checkout branch" })

    local panel_keymaps = require("review.ui.panel_keymaps")
    panel_keymaps.setup(bufnr, {
        tab_target = "get_commit_list",
        h_target = "get_file_tree",
        l_target = "get_commit_list",
    }, function()
        if callbacks.on_close then
            callbacks.on_close()
        end
    end, active_timers, map)
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
---@param restore_cursor_line? number If provided, restore cursor to this line instead of selected_index
function M.fetch_and_render(restore_cursor_line)
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

            local entries = {}

            for _, branch_name in ipairs(branch_names) do
                table.insert(entries, {
                    name = branch_name,
                    is_current = branch_name == current_branch,
                    is_main = branch_name == main_branch,
                })
            end

            M.current.branches = entries
            M.current.selected_index = find_active_index(entries)

            render(M.current.bufnr, entries, M.current.selected_index, M.current.winid)

            local line_count = vim.api.nvim_buf_line_count(M.current.bufnr)
            local cursor_line
            if restore_cursor_line then
                cursor_line = math.min(restore_cursor_line, line_count)
            else
                cursor_line = M.current.selected_index and branch_index_to_line(M.current.selected_index) or 1
            end
            if vim.api.nvim_win_is_valid(M.current.winid) then
                vim.api.nvim_win_set_cursor(M.current.winid, { cursor_line, 0 })
            end

            git.get_branch_sync_counts(function(sync_counts)
                if not M.current or not vim.api.nvim_buf_is_valid(M.current.bufnr) then
                    return
                end
                M.current.sync_counts = sync_counts
                render(M.current.bufnr, M.current.branches, M.current.selected_index, M.current.winid, sync_counts)
            end)
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
        if entry.name == branch.name then
            M.current.selected_index = index
            break
        end
    end

    render(M.current.bufnr, M.current.branches, M.current.selected_index, M.current.winid, M.current.sync_counts)
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
    if pull_spinner_timer then
        pull_spinner_timer:stop()
        pull_spinner_timer:close()
        pull_spinner_timer = nil
    end
    pull_line_index = nil
    if checkout_spinner_timer then
        checkout_spinner_timer:stop()
        checkout_spinner_timer:close()
        checkout_spinner_timer = nil
    end
    checkout_line_index = nil
    ui_util.destroy_timers(active_timers)
    callbacks = {}
    M.current = nil
end

return M
