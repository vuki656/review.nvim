local format = require("review.core.format")
local git = require("review.core.git")
local state = require("review.state")
local ui_util = require("review.ui.util")

local M = {}

---@class CommitEntry
---@field is_head boolean
---@field hash string|nil
---@field short_hash string
---@field subject string
---@field date string|nil
---@field author string|nil
---@field is_unpushed boolean
---@field parent_count number

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

local COMMIT_COUNT = 30

local ICON_REGULAR = "\u{f417} "
local ICON_MERGE = "\u{f419} "
local ICON_ROOT = "\u{f444} "

---Map parent count to a Nerd Font commit type icon and highlight group
---@param parent_count number
---@return string icon, string highlight_group
local function commit_type_icon(parent_count)
    if parent_count == 0 then
        return ICON_ROOT, "ReviewCommitIconRoot"
    elseif parent_count >= 2 then
        return ICON_MERGE, "ReviewCommitIconMerge"
    end
    return ICON_REGULAR, "ReviewCommitIconRegular"
end

local date_extmark_ns = vim.api.nvim_create_namespace("review_commit_dates")
local row_hl_ns = vim.api.nvim_create_namespace("review_commit_row_hl")

local AUTHOR_COLOR_COUNT = 6

---Build a mapping from author name to color index (1-based), assigning
---sequential colors in the order authors first appear. This guarantees
---different authors get different colors (up to AUTHOR_COLOR_COUNT).
---@param commits CommitEntry[]
---@return table<string, number>
local function build_author_color_map(commits)
    local color_map = {}
    local next_index = 1

    for _, entry in ipairs(commits) do
        local author = entry.author
        if author and author ~= "" and not color_map[author] then
            color_map[author] = ((next_index - 1) % AUTHOR_COLOR_COUNT) + 1
            next_index = next_index + 1
        end
    end

    return color_map
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
            is_unpushed = false,
            parent_count = 0,
        },
    }

    local commits = git.get_recent_commits(COMMIT_COUNT)
    local unpushed = git.get_unpushed_hashes()

    for _, commit in ipairs(commits) do
        table.insert(entries, {
            is_head = false,
            hash = commit.hash,
            short_hash = commit.short_hash,
            subject = commit.subject,
            date = commit.date,
            author = commit.author,
            is_unpushed = unpushed[commit.hash] or false,
            parent_count = commit.parent_count or 1,
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
---@param _winid number|nil
local function render(bufnr, commits, selected_index, _winid)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    ui_util.with_modifiable(bufnr, function()
    local lines = {}
    local highlight_ranges = {}
    local date_entries = {}
    local author_color_map = build_author_color_map(commits)

    local render_index = 0
    for index, entry in ipairs(commits) do
        if not entry.is_head then
            local is_active = index == selected_index
            local marker = is_active and " ▎" or "  "
            local node = is_active and "● " or "○ "
            local type_icon, type_icon_highlight = commit_type_icon(entry.parent_count)
            local initials = format.author_initials(entry.author)
            local initials_segment = initials ~= "" and (initials .. " ") or ""
            local line = marker
                .. node
                .. type_icon
                .. entry.short_hash
                .. " "
                .. initials_segment
                .. " "
                .. entry.subject
            table.insert(lines, line)

            local line_index = render_index
            render_index = render_index + 1
            local offset = 0
            local marker_end = offset + #marker
            local node_start = marker_end
            local node_end = node_start + #node
            local icon_start = node_end
            local icon_end = icon_start + #type_icon
            local hash_start = icon_end
            local hash_end = hash_start + #entry.short_hash
            local initials_start = hash_end + 1
            local initials_end = initials_start + #initials
            local subject_start = initials_end + 1 + 1

            table.insert(highlight_ranges, {
                line_index = line_index,
                marker = { offset, marker_end },
                node = { node_start, node_end },
                type_icon = { icon_start, icon_end },
                type_icon_highlight = type_icon_highlight,
                hash = { hash_start, hash_end },
                initials = initials ~= "" and { initials_start, initials_end } or nil,
                author = entry.author,
                subject = { subject_start, #line },
                is_active = is_active,
                is_unpushed = entry.is_unpushed,
            })

            if entry.date then
                table.insert(date_entries, { line_index = line_index, date = format.shorten_date(entry.date) })
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

        local icon_hl = range.is_active and "ReviewCommitGraphActive" or range.type_icon_highlight
        vim.api.nvim_buf_add_highlight(
            bufnr,
            -1,
            icon_hl,
            range.line_index,
            range.type_icon[1],
            range.type_icon[2]
        )

        local hash_hl = range.is_unpushed and "ReviewCommitUnpushed" or "ReviewCommitPushed"
        vim.api.nvim_buf_add_highlight(bufnr, -1, hash_hl, range.line_index, range.hash[1], range.hash[2])

        if range.initials then
            local author_hl = "ReviewCommitAuthor" .. (author_color_map[range.author] or 1)
            vim.api.nvim_buf_add_highlight(
                bufnr,
                -1,
                author_hl,
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
            virt_text = { { date_entry.date .. " ", "ReviewCommitDate" } },
            virt_text_pos = "right_align",
        })
    end

    end)
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

local preview_timer = vim.loop.new_timer()

---Trigger a debounced commit preview for the entry at the current cursor line
local function trigger_preview()
    preview_timer:stop()
    preview_timer:start(
        150,
        0,
        vim.schedule_wrap(function()
            if not M.current then
                return
            end

            local winid = M.current.winid
            if not winid or not vim.api.nvim_win_is_valid(winid) then
                return
            end

            local line = vim.api.nvim_win_get_cursor(winid)[1]
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
    local map = ui_util.create_buffer_mapper(bufnr)

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

    local panel_keymaps = require("review.ui.panel_keymaps")
    panel_keymaps.setup(bufnr, {
        tab_target = "get_comment_list",
        h_target = "get_branch_list",
        l_target = "get_comment_list",
    }, function()
        if callbacks.on_close then
            callbacks.on_close()
        end
    end, active_timers, map, callbacks.on_escape)

    map("u", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local commit_index = line_to_commit_index(line)
        if not commit_index then
            return
        end

        local entry = M.current.commits[commit_index]
        if not entry or entry.is_head then
            return
        end

        local head_entry = M.current.commits[2]
        if not head_entry or entry.hash ~= head_entry.hash then
            vim.notify("Can only uncommit the most recent commit", vim.log.levels.WARN)
            return
        end

        ui_util.confirm("Uncommit '" .. entry.subject .. "'?", function()
            if callbacks.on_uncommit then
                callbacks.on_uncommit(entry)
            end
        end)
    end, { nowait = true, desc = "Uncommit (soft reset)" })
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

    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = layout_component.bufnr,
        callback = function()
            trigger_preview()
        end,
    })

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
    preview_timer:stop()
    ui_util.destroy_timers(active_timers)
    callbacks = {}
    M.current = nil
end

return M
