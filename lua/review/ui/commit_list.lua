local git = require("review.core.git")
local state = require("review.state")

local M = {}

---@class CommitEntry
---@field is_head boolean
---@field hash string|nil
---@field short_hash string
---@field subject string
---@field date string|nil
---@field author string|nil

---@class CommitListComponent
---@field bufnr number
---@field winid number
---@field commits CommitEntry[]
---@field selected_index number

---@type CommitListComponent|nil
M.current = nil

---@type table
local callbacks = {}

local active_timers = {
    preview_timer = nil,
    scroll_timer = nil,
}

local COMMIT_COUNT = 6

local date_extmark_ns = vim.api.nvim_create_namespace("review_commit_dates")
local row_hl_ns = vim.api.nvim_create_namespace("review_commit_row_hl")

---Shorten a git relative date string
---@param date string
---@return string
local function shorten_date(date)
    local number, unit = date:match("^(%d+) (%a+) ago$")
    if not number then
        return date
    end

    local short_units = {
        second = "s",
        seconds = "s",
        minute = "m",
        minutes = "m",
        hour = "h",
        hours = "h",
        day = "d",
        days = "d",
        week = "w",
        weeks = "w",
        month = "mo",
        months = "mo",
        year = "y",
        years = "y",
    }

    local short = short_units[unit]
    if short then
        return number .. short
    end

    return date
end

---Extract author initials from a name (e.g. "John Doe" → "JD", "vuki" → "VU")
---@param author string|nil
---@return string
local function author_initials(author)
    if not author or author == "" then
        return ""
    end

    local words = {}
    for word in author:gmatch("%S+") do
        table.insert(words, word)
    end

    if #words == 0 then
        return ""
    end

    if #words == 1 then
        return words[1]:sub(1, 2):upper()
    end

    return (words[1]:sub(1, 1) .. words[2]:sub(1, 1)):upper()
end

---Build the list of commit entries (HEAD + recent commits)
---@return CommitEntry[]
local function fetch_commits()
    local entries = {
        {
            is_head = true,
            hash = nil,
            short_hash = "HEAD",
            subject = "Working changes",
            date = nil,
            author = nil,
        },
    }

    local commits = git.get_recent_commits(COMMIT_COUNT)
    for _, commit in ipairs(commits) do
        table.insert(entries, {
            is_head = false,
            hash = commit.hash,
            short_hash = commit.short_hash,
            subject = commit.subject,
            date = commit.date,
            author = commit.author,
        })
    end

    return entries
end

---Determine which commit entry is currently active based on state
---@param commits CommitEntry[]
---@return number
local function find_active_index(commits)
    local base = state.state.base
    local base_end = state.state.base_end

    if base == nil or base == "HEAD" then
        return 1
    end

    for index, entry in ipairs(commits) do
        if entry.hash and base_end == entry.hash then
            return index
        end
    end

    return 1
end

---Render commits to buffer
---@param bufnr number
---@param commits CommitEntry[]
---@param selected_index number
---@param winid number|nil
local function render(bufnr, commits, selected_index, winid)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true

    local lines = {}
    local highlight_ranges = {}
    local date_entries = {}

    local render_index = 0
    for index, entry in ipairs(commits) do
        if not entry.is_head then
            local is_active = index == selected_index
            local marker = is_active and " ▎" or "  "
            local node = is_active and "● " or "○ "
            local initials = author_initials(entry.author)
            local initials_segment = initials ~= "" and (initials .. " ") or ""
            local line = marker .. node .. entry.short_hash .. " " .. initials_segment .. " " .. entry.subject
            table.insert(lines, line)

            local line_index = render_index
            render_index = render_index + 1
            local offset = 0
            local marker_end = offset + #marker
            local node_start = marker_end
            local node_end = node_start + #node
            local hash_start = node_end
            local hash_end = hash_start + #entry.short_hash
            local initials_start = hash_end + 1
            local initials_end = initials_start + #initials
            local subject_start = initials_end + 1 + 1

            table.insert(highlight_ranges, {
                line_index = line_index,
                marker = { offset, marker_end },
                node = { node_start, node_end },
                hash = { hash_start, hash_end },
                initials = initials ~= "" and { initials_start, initials_end } or nil,
                subject = { subject_start, #line },
                is_active = is_active,
            })

            if entry.date then
                table.insert(date_entries, { line_index = line_index, date = shorten_date(entry.date) })
            end
        end
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(bufnr, date_extmark_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, row_hl_ns, 0, -1)

    for _, range in ipairs(highlight_ranges) do
        if range.is_active then
            vim.api.nvim_buf_add_highlight(
                bufnr,
                -1,
                "ReviewCommitActive",
                range.line_index,
                range.marker[1],
                range.marker[2]
            )
            vim.api.nvim_buf_set_extmark(bufnr, row_hl_ns, range.line_index, 0, {
                line_hl_group = "ReviewActiveRow",
            })
        end

        local node_hl = range.is_active and "ReviewCommitGraphActive" or "ReviewCommitGraph"
        vim.api.nvim_buf_add_highlight(bufnr, -1, node_hl, range.line_index, range.node[1], range.node[2])
        vim.api.nvim_buf_add_highlight(bufnr, -1, "ReviewCommitHash", range.line_index, range.hash[1], range.hash[2])

        if range.initials then
            vim.api.nvim_buf_add_highlight(
                bufnr,
                -1,
                "ReviewCommitAuthor",
                range.line_index,
                range.initials[1],
                range.initials[2]
            )
        end

        local subject_hl = range.is_active and "ReviewCommitActive" or "ReviewFilePath"
        vim.api.nvim_buf_add_highlight(bufnr, -1, subject_hl, range.line_index, range.subject[1], range.subject[2])
    end

    for _, date_entry in ipairs(date_entries) do
        vim.api.nvim_buf_set_extmark(bufnr, date_extmark_ns, date_entry.line_index, 0, {
            virt_text = { { date_entry.date, "ReviewCommitDate" } },
            virt_text_pos = "right_align",
        })
    end

    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
end

---Convert a commit list line number (1-indexed) to a commit index
---Line N maps to commit index N+1 (index 1 is hidden HEAD)
---@param line number
---@return number|nil
local function line_to_commit_index(line)
    if not M.current then
        return nil
    end

    local commit_index = line + 1
    if commit_index < 2 or commit_index > #M.current.commits then
        return nil
    end

    return commit_index
end

---Convert a commit index to a buffer line number (1-indexed)
---Index 1 is hidden HEAD, index 2+ maps to line index-1
---@param index number
---@return number
local function commit_index_to_line(index)
    return math.max(1, index - 1)
end

---Trigger a debounced commit preview for the entry at the current cursor line
local function trigger_preview()
    if active_timers.preview_timer then
        active_timers.preview_timer:stop()
        active_timers.preview_timer:close()
        active_timers.preview_timer = nil
    end

    active_timers.preview_timer = vim.loop.new_timer()
    active_timers.preview_timer:start(
        100,
        0,
        vim.schedule_wrap(function()
            if active_timers.preview_timer then
                active_timers.preview_timer:stop()
                active_timers.preview_timer:close()
                active_timers.preview_timer = nil
            end

            if not M.current then
                return
            end

            local line = vim.api.nvim_win_get_cursor(0)[1]
            local commit_index = line_to_commit_index(line)
            if not commit_index then
                return
            end

            local entry = M.current.commits[commit_index]
            if entry and callbacks.on_commit_preview then
                callbacks.on_commit_preview(entry)
            end
        end)
    )
end

---Setup keymaps for the commit list buffer
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
            local commit_index = line_to_commit_index(next_line)
            if commit_index then
                break
            end
            next_line = next_line + 1
        end

        if next_line <= line_count then
            vim.api.nvim_win_set_cursor(0, { next_line, 0 })
            trigger_preview()
        end
    end, { nowait = true, desc = "Next commit" })

    map("k", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local prev_line = line - 1

        while prev_line >= 1 do
            local commit_index = line_to_commit_index(prev_line)
            if commit_index then
                break
            end
            prev_line = prev_line - 1
        end

        if prev_line >= 1 then
            vim.api.nvim_win_set_cursor(0, { prev_line, 0 })
            trigger_preview()
        end
    end, { nowait = true, desc = "Previous commit" })

    map("<CR>", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local commit_index = line_to_commit_index(line)
        if not commit_index then
            return
        end

        local entry = M.current.commits[commit_index]
        if not entry then
            return
        end

        if callbacks.on_commit_select then
            callbacks.on_commit_select(entry)
        end
    end, { nowait = true, desc = "Select commit" })

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

    -- Cycle to next left pane (commit_list → branch_list)
    map("<Tab>", function()
        local current_layout = require("review.ui.layout")
        local branch_list_component = current_layout.get_branch_list()
        if
            branch_list_component
            and branch_list_component.winid
            and vim.api.nvim_win_is_valid(branch_list_component.winid)
        then
            vim.api.nvim_set_current_win(branch_list_component.winid)
        end
    end, { nowait = true, desc = "Next pane" })

    map("h", function()
        local current_layout = require("review.ui.layout")
        local file_tree_component = current_layout.get_file_tree()
        if
            file_tree_component
            and file_tree_component.winid
            and vim.api.nvim_win_is_valid(file_tree_component.winid)
        then
            vim.api.nvim_set_current_win(file_tree_component.winid)
        end
    end, { nowait = true, desc = "Previous panel" })
    map("l", function()
        local current_layout = require("review.ui.layout")
        local branch_list_component = current_layout.get_branch_list()
        if
            branch_list_component
            and branch_list_component.winid
            and vim.api.nvim_win_is_valid(branch_list_component.winid)
        then
            vim.api.nvim_set_current_win(branch_list_component.winid)
        end
    end, { nowait = true, desc = "Next panel" })
    vim.keymap.set("n", "<Left>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Right>", "<Nop>", { buffer = bufnr, nowait = true })
end

---Create the commit list component
---@param layout_component ReviewLayoutComponent
---@param cbs table { on_commit_select: function, on_close: function }
---@return CommitListComponent
function M.create(layout_component, cbs)
    callbacks = cbs

    local commits = fetch_commits()
    local selected_index = find_active_index(commits)

    M.current = {
        bufnr = layout_component.bufnr,
        winid = layout_component.winid,
        commits = commits,
        selected_index = selected_index,
    }

    render(layout_component.bufnr, commits, selected_index, layout_component.winid)
    setup_keymaps(layout_component.bufnr)

    vim.wo[layout_component.winid].spell = false

    local cursor_line = commit_index_to_line(selected_index)
    if vim.api.nvim_win_is_valid(layout_component.winid) then
        vim.api.nvim_win_set_cursor(layout_component.winid, { cursor_line, 0 })
    end

    return M.current
end

---Refresh the commit list (re-fetch and re-render)
function M.refresh()
    if not M.current then
        return
    end

    M.current.commits = fetch_commits()
    M.current.selected_index = find_active_index(M.current.commits)
    render(M.current.bufnr, M.current.commits, M.current.selected_index, M.current.winid)
end

---Update the selected commit marker and re-render
---@param entry CommitEntry
function M.set_selected(entry)
    if not M.current then
        return
    end

    for index, commit in ipairs(M.current.commits) do
        if entry.is_head and commit.is_head then
            M.current.selected_index = index
            break
        elseif not entry.is_head and not commit.is_head and entry.hash == commit.hash then
            M.current.selected_index = index
            break
        end
    end

    render(M.current.bufnr, M.current.commits, M.current.selected_index, M.current.winid)
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
