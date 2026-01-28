local config = require("review.config")
local persistence = require("review.quick_comments.persistence")
local qc_state = require("review.quick_comments.state")
local signs = require("review.quick_comments.signs")

local M = {}

---@class QuickCommentsPanelState
---@field bufnr number|nil
---@field winid number|nil
---@field line_to_comment table<number, QuickComment>
---@field prev_winid number|nil

---@type QuickCommentsPanelState
local panel = {
    bufnr = nil,
    winid = nil,
    line_to_comment = {},
    prev_winid = nil,
}

local ns_panel = vim.api.nvim_create_namespace("review_qc_panel")

---Comment type info
local comment_types = {
    note = { label = "Note", icon = "󰍩", hl = "ReviewCommentNote" },
    fix = { label = "Fix", icon = "󰁨", hl = "ReviewCommentFix" },
    question = { label = "Question", icon = "󰋗", hl = "ReviewCommentQuestion" },
}

---Get relative path from cwd
---@param path string
---@return string
local function get_relative_path(path)
    local cwd = vim.fn.getcwd()
    if path:sub(1, #cwd) == cwd then
        return path:sub(#cwd + 2)
    end
    return path
end

---Render the panel content
function M.render()
    if not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
        return
    end

    vim.bo[panel.bufnr].modifiable = true
    vim.api.nvim_buf_clear_namespace(panel.bufnr, ns_panel, 0, -1)

    local panel_width = 48
    if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
        panel_width = vim.api.nvim_win_get_width(panel.winid)
    end

    local lines = {}
    local highlights = {}
    panel.line_to_comment = {}

    local count = qc_state.count()

    -- Header
    table.insert(lines, " Quick Comments (" .. count .. ")")
    table.insert(highlights, { line = 0, col = 0, end_col = #lines[1], hl = "ReviewTitle" })
    table.insert(lines, string.rep("─", panel_width))
    table.insert(highlights, { line = 1, col = 0, end_col = #lines[2], hl = "ReviewBorder" })

    if count == 0 then
        table.insert(lines, "")
        table.insert(lines, "  No comments yet")
        table.insert(lines, "")
        table.insert(lines, "  Press <leader>qc to add a comment")
        table.insert(highlights, { line = 3, col = 0, end_col = #lines[4], hl = "Comment" })
        table.insert(lines, "  at the current cursor position")
        table.insert(highlights, { line = 4, col = 0, end_col = #lines[5], hl = "Comment" })
    else
        local comments_by_file = qc_state.get_all()
        local files = qc_state.get_files()

        local type_order = { "fix", "note", "question" }

        for _, file in ipairs(files) do
            local comments = comments_by_file[file]
            local rel_path = get_relative_path(file)

            -- File header
            table.insert(lines, "")
            local filename = vim.fn.fnamemodify(rel_path, ":t")
            local dir_path = vim.fn.fnamemodify(rel_path, ":h")
            if dir_path == "." then
                dir_path = ""
            else
                dir_path = dir_path .. "/"
            end

            local max_width = panel_width
            local file_line = " " .. filename
            if #dir_path > 0 then
                local separator = " │ "
                local remaining = max_width - #file_line - #separator
                if remaining >= #dir_path then
                    file_line = file_line .. separator .. dir_path
                elseif remaining > 3 then
                    file_line = file_line .. separator .. dir_path:sub(1, remaining - 3) .. "..."
                end
            end

            table.insert(lines, file_line)
            local line_idx = #lines - 1
            local name_end = #filename + 1
            table.insert(highlights, { line = line_idx, col = 0, end_col = name_end, hl = "ReviewFilePath" })
            if #file_line > name_end then
                table.insert(highlights, { line = line_idx, col = name_end, end_col = #file_line, hl = "Comment" })
            end

            -- Group comments by type
            local grouped = {}
            for _, comment in ipairs(comments) do
                local comment_type = comment.type
                if not grouped[comment_type] then
                    grouped[comment_type] = {}
                end
                table.insert(grouped[comment_type], comment)
            end

            -- Render each type group
            for _, type_key in ipairs(type_order) do
                local group = grouped[type_key]
                if group then
                    table.insert(lines, "")
                    local type_info = comment_types[type_key]
                    local subheader = "  " .. type_info.icon .. " " .. type_info.label
                    table.insert(lines, subheader)
                    line_idx = #lines - 1
                    table.insert(
                        highlights,
                        { line = line_idx, col = 0, end_col = #subheader, hl = type_info.hl }
                    )

                    for _, comment in ipairs(group) do
                        local line_prefix = string.format("  L%-4d ", comment.line)
                        local text = comment.text:gsub("\n", " ")
                        local comment_line = line_prefix .. text
                        if #comment_line > panel_width then
                            comment_line = comment_line:sub(1, panel_width - 3) .. "..."
                        end
                        table.insert(lines, comment_line)
                        line_idx = #lines - 1
                        table.insert(highlights, {
                            line = line_idx,
                            col = 0,
                            end_col = #line_prefix,
                            hl = "ReviewFooterText",
                        })
                        panel.line_to_comment[line_idx + 1] = comment
                    end
                end
            end

            table.insert(lines, "")
        end
    end

    -- Footer with keymaps
    table.insert(lines, string.rep("─", panel_width))
    table.insert(highlights, { line = #lines - 1, col = 0, end_col = panel_width * 3, hl = "ReviewBorder" })
    table.insert(lines, " ⏎ jump  L preview  d delete  e edit  c copy  q close")
    table.insert(highlights, { line = #lines - 1, col = 0, end_col = #lines[#lines], hl = "ReviewFooterText" })

    vim.api.nvim_buf_set_lines(panel.bufnr, 0, -1, false, lines)

    -- Apply highlights
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(panel.bufnr, ns_panel, hl.hl, hl.line, hl.col, hl.end_col)
    end

    vim.bo[panel.bufnr].modifiable = false
end

---Create the panel buffer
---@return number bufnr
local function create_buffer()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "review-quick-comments"

    return bufnr
end

---Set up panel keymaps
---@param bufnr number
local function setup_keymaps(bufnr)
    local opts = { buffer = bufnr, nowait = true, silent = true }

    -- Close panel
    vim.keymap.set("n", "q", function()
        M.close()
    end, opts)

    vim.keymap.set("n", "<Esc>", function()
        M.close()
    end, opts)

    -- Jump to comment location
    vim.keymap.set("n", "<CR>", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local comment = panel.line_to_comment[cursor[1]]
        if comment and panel.prev_winid and vim.api.nvim_win_is_valid(panel.prev_winid) then
            -- Jump in the previous window without closing the panel
            vim.api.nvim_set_current_win(panel.prev_winid)
            vim.cmd("edit " .. vim.fn.fnameescape(comment.file))
            vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
            vim.cmd("normal! zz")
        end
    end, opts)

    -- Preview full comment in popup
    vim.keymap.set("n", "L", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local comment = panel.line_to_comment[cursor[1]]
        if not comment then
            return
        end

        local type_info = comment_types[comment.type]
        local header = type_info.icon .. " " .. type_info.label .. "  (L" .. comment.line .. ")"
        local popup_lines = { header, string.rep("─", #header + 2), "" }
        for _, text_line in ipairs(vim.split(comment.text, "\n")) do
            table.insert(popup_lines, text_line)
        end

        local max_width = 0
        for _, popup_line in ipairs(popup_lines) do
            max_width = math.max(max_width, vim.fn.strdisplaywidth(popup_line))
        end

        local popup_bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(popup_bufnr, 0, -1, false, popup_lines)
        vim.bo[popup_bufnr].modifiable = false

        vim.api.nvim_buf_add_highlight(popup_bufnr, ns_panel, type_info.hl, 0, 0, -1)
        vim.api.nvim_buf_add_highlight(popup_bufnr, ns_panel, "ReviewBorder", 1, 0, -1)

        local popup_winid = vim.api.nvim_open_win(popup_bufnr, false, {
            relative = "cursor",
            row = 1,
            col = 0,
            width = math.max(max_width + 2, 20),
            height = #popup_lines,
            style = "minimal",
            border = "rounded",
        })
        vim.wo[popup_winid].wrap = true

        vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
            buffer = panel.bufnr,
            once = true,
            callback = function()
                if vim.api.nvim_win_is_valid(popup_winid) then
                    vim.api.nvim_win_close(popup_winid, true)
                end
            end,
        })
    end, opts)

    -- Delete comment
    vim.keymap.set("n", "d", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local comment = panel.line_to_comment[cursor[1]]
        if comment then
            qc_state.remove(comment.file, comment.id)
            persistence.save()
            signs.update_file(comment.file)
            M.render()
        end
    end, opts)

    -- Edit comment
    vim.keymap.set("n", "e", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local comment = panel.line_to_comment[cursor[1]]
        if comment then
            -- Close panel first
            local file = comment.file
            local id = comment.id
            local current_text = comment.text
            M.close()

            -- Open edit input
            vim.ui.input({
                prompt = "Edit comment: ",
                default = current_text,
            }, function(new_text)
                if new_text and new_text ~= "" then
                    qc_state.update(file, id, new_text)
                    persistence.save()
                    M.open()
                else
                    M.open()
                end
            end)
        end
    end, opts)

    -- Copy all to clipboard
    vim.keymap.set("n", "c", function()
        local comments = qc_state.get_all_flat()
        if #comments == 0 then
            vim.notify("No comments to copy", vim.log.levels.INFO)
            return
        end

        local lines = {}
        local current_file = nil

        for _, comment in ipairs(comments) do
            if comment.file ~= current_file then
                current_file = comment.file
                table.insert(lines, "")
                table.insert(lines, "## " .. get_relative_path(comment.file))
            end

            local type_info = comment_types[comment.type]
            table.insert(lines, "")
            table.insert(lines, string.format("**Line %d** - %s %s", comment.line, type_info.icon, type_info.label))
            if comment.context then
                table.insert(lines, "```")
                table.insert(lines, comment.context)
                table.insert(lines, "```")
            end
            table.insert(lines, comment.text)
        end

        local content = table.concat(lines, "\n")
        vim.fn.setreg("+", content)
        vim.notify("Copied " .. #comments .. " comment(s) to clipboard", vim.log.levels.INFO)
    end, opts)
end

---Open the panel
function M.open()
    if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
        -- Already open, just focus
        vim.api.nvim_set_current_win(panel.winid)
        return
    end

    -- Remember the current window
    panel.prev_winid = vim.api.nvim_get_current_win()

    -- Create buffer
    panel.bufnr = create_buffer()

    -- Get config
    local cfg = config.get()
    local width = cfg.quick_comments and cfg.quick_comments.panel and cfg.quick_comments.panel.width or 50
    local position = cfg.quick_comments and cfg.quick_comments.panel and cfg.quick_comments.panel.position or "right"

    -- Create window
    local cmd = position == "right" and "botright vsplit" or "topleft vsplit"
    vim.cmd(cmd)
    panel.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(panel.winid, panel.bufnr)
    vim.api.nvim_win_set_width(panel.winid, width)

    -- Window options
    vim.wo[panel.winid].number = false
    vim.wo[panel.winid].relativenumber = false
    vim.wo[panel.winid].signcolumn = "no"
    vim.wo[panel.winid].foldcolumn = "0"
    vim.wo[panel.winid].wrap = true
    vim.wo[panel.winid].linebreak = true
    vim.wo[panel.winid].cursorline = true
    vim.wo[panel.winid].winfixwidth = true

    -- Set up keymaps
    setup_keymaps(panel.bufnr)

    -- Render content
    M.render()

    -- Update state
    qc_state.state.panel_open = true

    -- Return focus to previous window if it exists
    if panel.prev_winid and vim.api.nvim_win_is_valid(panel.prev_winid) then
        vim.api.nvim_set_current_win(panel.prev_winid)
    end
end

---Close the panel
function M.close()
    if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
        vim.api.nvim_win_close(panel.winid, true)
    end
    panel.winid = nil
    panel.bufnr = nil
    panel.line_to_comment = {}
    qc_state.state.panel_open = false
end

---Toggle the panel
function M.toggle()
    if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
        M.close()
    else
        M.open()
    end
end

---Check if panel is open
---@return boolean
function M.is_open()
    return panel.winid ~= nil and vim.api.nvim_win_is_valid(panel.winid)
end

return M
