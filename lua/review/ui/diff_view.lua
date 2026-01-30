local diff_parser = require("review.core.diff")
local git = require("review.core.git")
local state = require("review.state")

local M = {}

---@class DiffViewComponent
---@field bufnr number
---@field winid number
---@field file string
---@field render_lines table[]
---@field ns_id number

---@type DiffViewComponent|nil
M.current = nil

---Namespace for diff highlights
local ns_diff = vim.api.nvim_create_namespace("review_diff")

---Namespace for comment markers
local ns_comments = vim.api.nvim_create_namespace("review_comments")

---Split string into tokens (words, punctuation, whitespace)
---@param str string
---@return table[] tokens with {text, start, end}
local function tokenize(str)
    local tokens = {}
    local i = 1
    local len = #str

    while i <= len do
        local start = i
        local char = str:sub(i, i)

        if char:match("%s") then
            -- Whitespace
            while i <= len and str:sub(i, i):match("%s") do
                i = i + 1
            end
        elseif char:match("[%w_]") then
            -- Word (alphanumeric + underscore)
            while i <= len and str:sub(i, i):match("[%w_]") do
                i = i + 1
            end
        else
            -- Punctuation/symbol - single char
            i = i + 1
        end

        table.insert(tokens, {
            text = str:sub(start, i - 1),
            start = start - 1, -- 0-indexed for nvim
            finish = i - 1, -- 0-indexed for nvim
        })
    end

    return tokens
end

---Compute word-level diff between two strings
---Returns list of {start, end} ranges that are different in new_str
---@param old_str string
---@param new_str string
---@return table[] ranges of changed characters in new_str
local function compute_inline_diff(old_str, new_str)
    if not old_str or not new_str then
        return {}
    end

    local old_tokens = tokenize(old_str)
    local new_tokens = tokenize(new_str)

    -- Find common prefix tokens
    local prefix_count = 0
    while prefix_count < #old_tokens and prefix_count < #new_tokens do
        if old_tokens[prefix_count + 1].text == new_tokens[prefix_count + 1].text then
            prefix_count = prefix_count + 1
        else
            break
        end
    end

    -- Find common suffix tokens (don't overlap with prefix)
    local suffix_count = 0
    while suffix_count < (#old_tokens - prefix_count) and suffix_count < (#new_tokens - prefix_count) do
        local old_idx = #old_tokens - suffix_count
        local new_idx = #new_tokens - suffix_count
        if old_tokens[old_idx].text == new_tokens[new_idx].text then
            suffix_count = suffix_count + 1
        else
            break
        end
    end

    -- The changed tokens in new_str
    local first_changed = prefix_count + 1
    local last_changed = #new_tokens - suffix_count

    if first_changed <= last_changed then
        local start_pos = new_tokens[first_changed].start
        local end_pos = new_tokens[last_changed].finish
        return { { start_pos, end_pos } }
    end

    return {}
end

---Find matching delete/add pairs for word-level diff
---@param render_lines table[]
---@return table<number, string> map of add line index to corresponding delete content
local function find_line_pairs(render_lines)
    local pairs = {}
    local i = 1

    while i <= #render_lines do
        local line = render_lines[i]

        -- Look for delete followed by add (modified line)
        if line.type == "delete" then
            -- Collect consecutive deletes
            local deletes = {}
            local j = i
            while j <= #render_lines and render_lines[j].type == "delete" do
                table.insert(deletes, { idx = j, content = render_lines[j].content })
                j = j + 1
            end

            -- Collect consecutive adds
            local adds = {}
            while j <= #render_lines and render_lines[j].type == "add" do
                table.insert(adds, { idx = j, content = render_lines[j].content })
                j = j + 1
            end

            -- Match deletes with adds (simple 1:1 matching)
            local match_count = math.min(#deletes, #adds)
            for k = 1, match_count do
                pairs[adds[k].idx] = deletes[k].content
                pairs[deletes[k].idx] = adds[k].content
            end

            i = j
        else
            i = i + 1
        end
    end

    return pairs
end

---Wrap a single line of text to fit within max_width (by display width)
---@param line string
---@param max_width number
---@return string[]
local function wrap_line(line, max_width)
    if max_width <= 0 or vim.api.nvim_strwidth(line) <= max_width then
        return { line }
    end

    local result = {}
    local current_line = ""

    for word in line:gmatch("%S+") do
        if current_line == "" then
            current_line = word
        elseif vim.api.nvim_strwidth(current_line .. " " .. word) <= max_width then
            current_line = current_line .. " " .. word
        else
            table.insert(result, current_line)
            current_line = word
        end
    end

    if current_line ~= "" then
        table.insert(result, current_line)
    end

    return #result > 0 and result or { line }
end

---Wrap text to fit within max_width (by display width), handling newlines
---@param text string
---@param max_width number
---@return string[]
local function wrap_text(text, max_width)
    local lines = {}

    for segment in vim.gsplit(text, "\n", { plain = true }) do
        local wrapped = wrap_line(segment, max_width)
        for _, wl in ipairs(wrapped) do
            table.insert(lines, wl)
        end
    end

    return #lines > 0 and lines or { text }
end

---Comment type info
local comment_types = {
    note = {
        label = "Note",
        highlight = "ReviewCommentNote",
        icon = "󰍩",
        border_hl = "ReviewInputBorderNote",
        title_hl = "ReviewInputTitleNote",
    },
    fix = {
        label = "Fix",
        highlight = "ReviewCommentFix",
        icon = "󰁨",
        border_hl = "ReviewInputBorderFix",
        title_hl = "ReviewInputTitleFix",
    },
    question = {
        label = "Question",
        highlight = "ReviewCommentQuestion",
        icon = "󰋗",
        border_hl = "ReviewInputBorderQuestion",
        title_hl = "ReviewInputTitleQuestion",
    },
}

---Render diff to buffer
---@param bufnr number
---@param file string
---@return table[]|nil render_lines
local function render_diff(bufnr, file)
    local result = git.get_diff(file, state.state.base)
    if not result.success then
        vim.bo[bufnr].readonly = false
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "",
            "  Error getting diff:",
            "  " .. (result.error or "Unknown error"),
        })
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true
        return nil
    end

    if result.output == "" then
        vim.bo[bufnr].readonly = false
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "",
            "  No changes in this file.",
        })
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true
        return nil
    end

    -- Parse diff
    local parsed = diff_parser.parse(result.output)
    local raw_lines = diff_parser.get_render_lines(parsed)

    -- Build clean display lines (no +/-, no @@ headers)
    local display_lines = { file, "" }
    local render_lines = {
        { type = "filepath", content = file },
        { type = "filepath", content = "" },
    }

    for _, line in ipairs(raw_lines) do
        if line.type ~= "header" then
            -- Strip the +/- prefix, show just content
            local content = line.content or ""
            table.insert(display_lines, content)
            table.insert(render_lines, line)
        end
    end

    -- Set buffer content
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, display_lines)

    -- Set filetype for treesitter syntax highlighting
    local ext = vim.fn.fnamemodify(file, ":e")
    local ft = vim.filetype.match({ filename = file }) or ext
    if ft and ft ~= "" then
        vim.bo[bufnr].filetype = ft
    end

    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true

    -- Find line pairs for word-level diff
    local line_pairs = find_line_pairs(render_lines)

    -- Check if file is entirely new (all adds) or entirely deleted (all deletes)
    local has_adds = false
    local has_deletes = false
    for _, line in ipairs(render_lines) do
        if line.type == "add" then
            has_adds = true
        end
        if line.type == "delete" then
            has_deletes = true
        end
    end
    local is_new_file = has_adds and not has_deletes
    local is_deleted_file = has_deletes and not has_adds

    -- Apply highlights and colored border
    vim.api.nvim_buf_clear_namespace(bufnr, ns_diff, 0, -1)

    for i, line in ipairs(render_lines) do
        local sign_hl = nil
        local sign_text = "▌"
        local inline_hl = nil

        local line_hl = nil

        if line.type == "filepath" then
            local line_text = display_lines[i] or ""
            if #line_text > 0 then
                vim.api.nvim_buf_set_extmark(bufnr, ns_diff, i - 1, 0, {
                    end_col = #line_text,
                    hl_group = "ReviewDiffFilePath",
                    priority = 10000,
                })
            end
        elseif line.type == "add" then
            line_hl = "ReviewDiffAdd"
            sign_hl = "ReviewDiffSignAdd"
            inline_hl = "ReviewDiffAddInline"
        elseif line.type == "delete" then
            line_hl = "ReviewDiffDelete"
            sign_hl = "ReviewDiffSignDelete"
            inline_hl = "ReviewDiffDeleteInline"
        elseif line.type == "context" then
            sign_hl = "ReviewDiffSignContext"
            sign_text = " "
        end

        -- Add colored border in sign column and line background
        if sign_hl then
            local extmark_opts = {
                sign_text = sign_text,
                sign_hl_group = sign_hl,
            }
            -- Apply line background (skip for new/deleted files - just use sign column)
            if line_hl and not is_new_file and not is_deleted_file then
                extmark_opts.line_hl_group = line_hl
            end
            vim.api.nvim_buf_set_extmark(bufnr, ns_diff, i - 1, 0, extmark_opts)
        end

        -- Apply word-level diff highlighting on top (overwrites line bg for changed parts)
        if inline_hl and line_pairs[i] then
            local old_content = line_pairs[i]
            local new_content = line.content or ""
            local inline_ranges = compute_inline_diff(old_content, new_content)

            for _, range in ipairs(inline_ranges) do
                if range[1] < range[2] then
                    vim.api.nvim_buf_add_highlight(bufnr, ns_diff, inline_hl, i - 1, range[1], range[2])
                end
            end
        end
    end

    return render_lines
end

---Render comment markers
---@param bufnr number
---@param file string
local function render_comments(bufnr, file)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_comments, 0, -1)

    local comments = state.get_comments_for_file(file)

    -- Calculate available width for comment box
    local max_box_width = nil
    if M.current and M.current.winid and vim.api.nvim_win_is_valid(M.current.winid) then
        local win_width = vim.api.nvim_win_get_width(M.current.winid)
        local win_info = vim.fn.getwininfo(M.current.winid)
        local text_off = win_info[1] and win_info[1].textoff or 0
        -- Available width minus border chars ("  ╭"/"  │" = 3, "╮"/"│" = 1)
        max_box_width = win_width - text_off - 4
    end

    for _, comment in ipairs(comments) do
        local type_info = comment_types[comment.type]
        if type_info then
            local header = string.format(" %s %s ", type_info.icon, type_info.label)
            -- Use display width (not byte length) for proper alignment with multi-byte icons
            local header_width = vim.api.nvim_strwidth(header)

            -- Wrap text to fit within the box
            local max_text_width = max_box_width and (max_box_width - 2) or nil -- -2 for " " padding each side
            local text_lines = wrap_text(comment.text, max_text_width or 9999)

            -- Calculate box width from widest wrapped line
            local max_line_width = 0
            for _, line in ipairs(text_lines) do
                max_line_width = math.max(max_line_width, vim.api.nvim_strwidth(line))
            end
            local box_width = math.max(header_width, max_line_width + 2) -- +2 for " " padding
            if max_box_width then
                box_width = math.min(box_width, max_box_width)
            end

            local header_padding = string.rep(" ", math.max(0, box_width - header_width))

            local virt_lines = {
                {
                    { "  ╭", "ReviewCommentBorder" },
                    { string.rep("─", box_width), "ReviewCommentBorder" },
                    { "╮", "ReviewCommentBorder" },
                },
                {
                    { "  │", "ReviewCommentBorder" },
                    { header .. header_padding, type_info.highlight },
                    { "│", "ReviewCommentBorder" },
                },
            }

            -- Add wrapped text lines
            for _, line in ipairs(text_lines) do
                local text_content = " " .. line .. " "
                local text_width = vim.api.nvim_strwidth(text_content)
                local text_padding = string.rep(" ", math.max(0, box_width - text_width))
                table.insert(virt_lines, {
                    { "  │", "ReviewCommentBorder" },
                    { text_content .. text_padding, "ReviewCommentText" },
                    { "│", "ReviewCommentBorder" },
                })
            end

            -- Bottom border
            table.insert(virt_lines, {
                { "  ╰", "ReviewCommentBorder" },
                { string.rep("─", box_width), "ReviewCommentBorder" },
                { "╯", "ReviewCommentBorder" },
            })

            pcall(function()
                -- Show comment as boxed virtual lines below
                -- Each segment has its own highlight
                vim.api.nvim_buf_set_extmark(bufnr, ns_comments, comment.line - 1, 0, {
                    virt_lines = virt_lines,
                    virt_lines_above = false,
                })

                -- Add sign in gutter
                vim.api.nvim_buf_set_extmark(bufnr, ns_comments, comment.line - 1, 0, {
                    sign_text = type_info.icon,
                    sign_hl_group = type_info.highlight,
                })
            end)
        end
    end
end

---Get the source line for current cursor position
---@return number|nil line, string|nil side
local function get_current_source_line()
    if not M.current or not M.current.render_lines then
        return nil, nil
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]

    return diff_parser.get_source_line(line_num, M.current.render_lines)
end

---Navigate to next change (add/delete block)
local function goto_next_hunk()
    if not M.current or not M.current.render_lines then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]
    local lines = M.current.render_lines

    -- Find next line that starts a change block (after context)
    local in_change = lines[current_line]
        and (lines[current_line].type == "add" or lines[current_line].type == "delete")

    for i = current_line + 1, #lines do
        local line = lines[i]
        local is_change = line.type == "add" or line.type == "delete"

        if is_change and not in_change then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            return
        end
        in_change = is_change
    end

    -- Wrap to beginning
    in_change = false
    for i, line in ipairs(lines) do
        local is_change = line.type == "add" or line.type == "delete"
        if is_change and not in_change then
            vim.api.nvim_win_set_cursor(0, { i, 0 })
            return
        end
        in_change = is_change
    end
end

---Navigate to previous change (add/delete block)
local function goto_prev_hunk()
    if not M.current or not M.current.render_lines then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]
    local lines = M.current.render_lines

    -- Find the start of previous change block
    local found_start = nil

    -- First, skip back through current change block if we're in one
    local i = current_line - 1
    while i >= 1 and (lines[i].type == "add" or lines[i].type == "delete") do
        i = i - 1
    end

    -- Now find previous change block
    local in_change = false
    for j = i, 1, -1 do
        local line = lines[j]
        local is_change = line.type == "add" or line.type == "delete"

        if is_change then
            found_start = j
            in_change = true
        elseif in_change then
            -- We found start of a change block
            break
        end
    end

    if found_start then
        vim.api.nvim_win_set_cursor(0, { found_start, 0 })
        return
    end

    -- Wrap to end
    in_change = false
    for j = #lines, 1, -1 do
        local line = lines[j]
        local is_change = line.type == "add" or line.type == "delete"

        if is_change then
            found_start = j
            in_change = true
        elseif in_change then
            break
        end
    end

    if found_start then
        vim.api.nvim_win_set_cursor(0, { found_start, 0 })
    end
end

---Get the current file's index in the changed files list
---@return number|nil current_idx, string[] files
local function get_current_file_index()
    local files = git.get_changed_files(state.state.base)
    if #files == 0 then
        return nil, files
    end

    for i, f in ipairs(files) do
        if f == state.state.current_file then
            return i, files
        end
    end
    return nil, files
end

---Navigate to next file
local function goto_next_file()
    local current_idx, files = get_current_file_index()
    if not current_idx then
        return
    end

    local next_idx = current_idx + 1
    if next_idx > #files then
        next_idx = 1
    end

    local ui = require("review.ui")
    ui.show_diff(files[next_idx])
end

---Navigate to previous file
local function goto_prev_file()
    local current_idx, files = get_current_file_index()
    if not current_idx then
        return
    end

    local prev_idx = current_idx - 1
    if prev_idx < 1 then
        prev_idx = #files
    end

    local ui = require("review.ui")
    ui.show_diff(files[prev_idx])
end

---Comment type order for cycling
local comment_type_order = { "fix", "note", "question" }

---Add comment with inline input (Tab to cycle type)
local function add_comment()
    if not M.current then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]
    local original_line = get_current_source_line()
    local file = M.current.file
    local bufnr = M.current.bufnr

    -- Current type index (default to note)
    local type_idx = 1
    local current_type = comment_type_order[type_idx]

    local type_info = comment_types[current_type]

    -- Create floating input window
    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[input_buf].buftype = "nofile"
    vim.bo[input_buf].filetype = "markdown"
    vim.bo[input_buf].completefunc = ""
    vim.bo[input_buf].omnifunc = ""

    vim.b[input_buf].copilot_enabled = false

    -- Calculate window position (below current line, at the start of the line)
    local win_width = 60
    local win_row = vim.fn.winline()
    local win_opts = {
        relative = "win",
        win = M.current.winid,
        row = win_row,
        col = 0,
        width = win_width,
        height = 5,
        style = "minimal",
        border = { "┏", "━", "┓", "┃", "┛", "━", "┗", "┃" },
        title = " " .. type_info.icon .. " " .. type_info.label .. " ",
        title_pos = "left",
    }

    local input_win = vim.api.nvim_open_win(input_buf, true, win_opts)

    -- Disable cmp after entering the input buffer (cmp.setup.buffer targets current buffer)
    local ok_cmp, cmp = pcall(require, "cmp")
    if ok_cmp then
        cmp.setup.buffer({ enabled = false })
    end

    -- Set window options
    vim.api.nvim_set_option_value(
        "winhighlight",
        "FloatBorder:" .. type_info.border_hl .. ",FloatTitle:" .. type_info.title_hl,
        { win = input_win }
    )
    vim.wo[input_win].wrap = true
    vim.wo[input_win].linebreak = true

    -- Function to close the input window
    local function close_input()
        if vim.api.nvim_win_is_valid(input_win) then
            vim.api.nvim_win_close(input_win, true)
        end
        if vim.api.nvim_buf_is_valid(input_buf) then
            vim.api.nvim_buf_delete(input_buf, { force = true })
        end
    end

    -- Function to update the window title and colors with current type
    local function update_title()
        local info = comment_types[current_type]
        vim.api.nvim_win_set_config(input_win, {
            title = " " .. info.icon .. " " .. info.label .. " ",
        })
        vim.api.nvim_set_option_value(
            "winhighlight",
            "FloatBorder:" .. info.border_hl .. ",FloatTitle:" .. info.title_hl,
            { win = input_win }
        )
    end

    -- Function to submit the comment
    local function submit()
        local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)

        -- Trim trailing empty lines
        while #lines > 0 and lines[#lines]:match("^%s*$") do
            table.remove(lines)
        end

        vim.cmd("stopinsert")
        close_input()

        local text = table.concat(lines, "\n")
        if text ~= "" then
            state.add_comment(file, line_num, current_type, text, original_line)
            render_comments(bufnr, file)
        end
    end

    -- Enter to submit (insert + normal mode)
    vim.keymap.set("i", "<CR>", submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("n", "<CR>", submit, { buffer = input_buf, nowait = true })

    -- Escape and Ctrl-C to submit from insert mode
    vim.keymap.set("i", "<Esc>", submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("i", "<C-c>", submit, { buffer = input_buf, nowait = true })

    -- Shift-Enter to insert a new line
    vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = input_buf, nowait = true })

    -- Tab to cycle type
    vim.keymap.set("i", "<Tab>", function()
        type_idx = (type_idx % #comment_type_order) + 1
        current_type = comment_type_order[type_idx]
        update_title()
    end, { buffer = input_buf, nowait = true })

    -- Shift-Tab to cycle backwards
    vim.keymap.set("i", "<S-Tab>", function()
        type_idx = type_idx - 1
        if type_idx < 1 then
            type_idx = #comment_type_order
        end
        current_type = comment_type_order[type_idx]
        update_title()
    end, { buffer = input_buf, nowait = true })

    -- Start in insert mode
    vim.cmd("startinsert")
end

---Delete comment at current line
local function delete_comment()
    if not M.current then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]

    local comment = state.get_comment_at_line(M.current.file, line_num)
    if comment then
        state.remove_comment(M.current.file, comment.id)
        render_comments(M.current.bufnr, M.current.file)
        vim.notify("Comment deleted", vim.log.levels.INFO)
    else
        vim.notify("No comment at this line", vim.log.levels.WARN)
    end
end

---Show help popup
local function show_help()
    local lines = {
        "Diff View Keymaps",
        "",
        "  c       Add comment (Tab to cycle type)",
        "  dc      Delete comment",
        "  ]c      Next hunk",
        "  [c      Previous hunk",
        "  ]f      Next file",
        "  [f      Previous file",
        "  <C-n>   Toggle file tree",
        "  q/<Esc> Close review",
        "  ?       Show this help",
    }

    vim.lsp.util.open_floating_preview(lines, "markdown", {
        border = "rounded",
        title = " Help ",
        title_pos = "center",
    })
end

---Setup keymaps for diff view
---@param bufnr number
---@param callbacks table
local function setup_keymaps(bufnr, callbacks)
    -- Add comment
    vim.keymap.set("n", "c", add_comment, { buffer = bufnr, desc = "Add comment" })

    -- Delete comment
    vim.keymap.set("n", "dc", delete_comment, { buffer = bufnr, desc = "Delete comment" })

    -- Next hunk
    vim.keymap.set("n", "]c", goto_next_hunk, { buffer = bufnr, desc = "Next hunk" })

    -- Previous hunk
    vim.keymap.set("n", "[c", goto_prev_hunk, { buffer = bufnr, desc = "Previous hunk" })

    -- Next file
    vim.keymap.set("n", "]f", goto_next_file, { buffer = bufnr, desc = "Next file" })

    -- Previous file
    vim.keymap.set("n", "[f", goto_prev_file, { buffer = bufnr, desc = "Previous file" })

    -- Close (shows exit popup)
    local function close_review()
        if callbacks.on_close then
            callbacks.on_close()
        end
    end

    vim.keymap.set("n", "q", close_review, { buffer = bufnr, nowait = true, desc = "Close review" })
    vim.keymap.set("n", "<Esc>", close_review, { buffer = bufnr, nowait = true, desc = "Close review" })

    -- Help
    vim.keymap.set("n", "?", show_help, { buffer = bufnr, desc = "Show help" })

    -- Toggle file tree
    vim.keymap.set("n", "<C-n>", function()
        local ui = require("review.ui")
        ui.toggle_file_tree()
    end, { buffer = bufnr, desc = "Toggle file tree" })
end

---Create the diff view component
---@param layout_component table { bufnr: number, winid: number }
---@param file string
---@param callbacks table
---@return DiffViewComponent
function M.create(layout_component, file, callbacks)
    local bufnr = layout_component.bufnr

    -- Render diff
    local render_lines = render_diff(bufnr, file)

    M.current = {
        bufnr = bufnr,
        winid = layout_component.winid,
        file = file,
        render_lines = render_lines,
        ns_id = ns_diff,
    }

    -- Render comments
    render_comments(bufnr, file)

    -- Setup keymaps
    setup_keymaps(bufnr, callbacks)

    -- Set buffer name and options (ignore if name already exists)
    pcall(vim.api.nvim_buf_set_name, bufnr, "Review: " .. file)

    -- Disable spell check and list chars on diff view
    vim.wo[layout_component.winid].spell = false
    vim.wo[layout_component.winid].list = false

    -- Enable wrap for text-heavy filetypes
    local ft = vim.bo[bufnr].filetype
    local wrap = ft == "markdown" or ft == "text"
    vim.wo[layout_component.winid].wrap = wrap
    vim.wo[layout_component.winid].linebreak = wrap

    return M.current
end

---Render the diff (for refreshing)
function M.render()
    if not M.current then
        return
    end

    M.current.render_lines = render_diff(M.current.bufnr, M.current.file)
    render_comments(M.current.bufnr, M.current.file)
end

---Get the current component
---@return DiffViewComponent|nil
function M.get()
    return M.current
end

---Destroy the component
function M.destroy()
    M.current = nil
end

return M
