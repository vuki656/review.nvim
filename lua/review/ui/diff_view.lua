local diff_parser = require("review.core.diff")
local git = require("review.core.git")
local layout = require("review.ui.layout")
local state = require("review.state")

local M = {}

---@class DiffViewComponent
---@field bufnr number
---@field winid number
---@field file string
---@field render_lines table[]
---@field ns_id number

---@class SplitDiffState
---@field old_bufnr number
---@field new_bufnr number
---@field old_lines table[]
---@field new_lines table[]

---@type DiffViewComponent|nil
M.current = nil

---@type SplitDiffState|nil
M.split_state = nil

---Namespace for diff highlights
local ns_diff = vim.api.nvim_create_namespace("review_diff")

---Namespace for comment markers
local ns_comments = vim.api.nvim_create_namespace("review_comments")

---Namespace for treesitter syntax highlights
local ns_syntax = vim.api.nvim_create_namespace("review_syntax")

---Apply treesitter highlights to a diff buffer using full file contents from git
---@param bufnr number
---@param render_lines table[]
---@param display_lines string[]
---@param file string
---@param line_offset? number Buffer line offset for sliced render_lines (0-indexed, default 0)
---@param base_override? string Git base revision override (for commit preview)
---@param base_end_override? string Git base_end revision override (for commit preview)
local function apply_treesitter_highlights(
    bufnr,
    render_lines,
    display_lines,
    file,
    line_offset,
    base_override,
    base_end_override
)
    line_offset = line_offset or 0

    if line_offset == 0 then
        vim.api.nvim_buf_clear_namespace(bufnr, ns_syntax, 0, -1)
    end

    local lang = vim.filetype.match({ filename = file })
    if not lang or lang == "" then
        return
    end

    local ok_lang, ts_lang = pcall(vim.treesitter.language.get_lang, lang)
    if ok_lang and ts_lang then
        lang = ts_lang
    end

    local ok_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
    if not ok_query or not query then
        return
    end

    local base = base_override or state.state.base
    local base_end = base_end_override or state.state.base_end

    local old_source_line_to_display = {}
    local new_source_line_to_display = {}
    local has_old_lines = false
    local has_new_lines = false

    for index, line in ipairs(render_lines) do
        if line.source_line then
            if
                line.type == "delete" or (line.type == "context" and not new_source_line_to_display[line.source_line])
            then
                old_source_line_to_display[line.source_line] = index
                has_old_lines = true
            end
            if line.type == "add" or line.type == "context" then
                new_source_line_to_display[line.source_line] = index
                has_new_lines = true
            end
        elseif line.old_line or line.new_line then
            if line.old_line and (line.type == "delete" or line.type == "context") then
                old_source_line_to_display[line.old_line] = index
                has_old_lines = true
            end
            if line.new_line and (line.type == "add" or line.type == "context") then
                new_source_line_to_display[line.new_line] = index
                has_new_lines = true
            end
        end
    end

    local old_content = nil
    if has_old_lines then
        old_content = git.get_file_at_rev(file, base)
    end

    local new_content = nil
    if has_new_lines then
        if base_end then
            new_content = git.get_file_at_rev(file, base_end)
        else
            new_content = git.get_working_tree_file(file)
        end
    end

    local function highlight_from_full_source(source_content, source_line_to_display)
        if not source_content then
            return
        end

        local ok_parser, parser = pcall(vim.treesitter.get_string_parser, source_content, lang)
        if not ok_parser then
            return
        end

        local ok_parse, trees = pcall(parser.parse, parser)
        if not ok_parse or not trees then
            return
        end

        for _, tree in ipairs(trees) do
            for capture_id, node in query:iter_captures(tree:root(), source_content) do
                local start_row, start_col, end_row, end_col = node:range()
                local capture_name = query.captures[capture_id]
                local hl_group = "@" .. capture_name .. "." .. lang

                if start_row == end_row then
                    local buf_line = source_line_to_display[start_row + 1]
                    if buf_line then
                        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_syntax, buf_line - 1 + line_offset, start_col, {
                            end_col = end_col,
                            hl_group = hl_group,
                            priority = 50,
                        })
                    end
                else
                    for row = start_row, end_row do
                        local buf_line = source_line_to_display[row + 1]
                        if buf_line then
                            local col_start = row == start_row and start_col or 0
                            local col_end = row == end_row and end_col or #(display_lines[buf_line] or "")
                            pcall(
                                vim.api.nvim_buf_set_extmark,
                                bufnr,
                                ns_syntax,
                                buf_line - 1 + line_offset,
                                col_start,
                                {
                                    end_col = col_end,
                                    hl_group = hl_group,
                                    priority = 50,
                                }
                            )
                        end
                    end
                end
            end
        end
    end

    highlight_from_full_source(old_content, old_source_line_to_display)
    highlight_from_full_source(new_content, new_source_line_to_display)
end

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

local LOCK_FILE_NAMES = {
    ["package-lock.json"] = true,
    ["yarn.lock"] = true,
    ["pnpm-lock.yaml"] = true,
    ["bun.lock"] = true,
    ["bun.lockb"] = true,
    ["Gemfile.lock"] = true,
    ["composer.lock"] = true,
    ["Cargo.lock"] = true,
    ["poetry.lock"] = true,
    ["go.sum"] = true,
}

---Check if a file is a lock file that should not render diffs
---@param file string
---@return boolean
local function is_lock_file(file)
    local filename = vim.fn.fnamemodify(file, ":t")
    return LOCK_FILE_NAMES[filename] == true
end

---Render diff to buffer
---@param bufnr number
---@param file string
---@return table[]|nil render_lines
local function render_diff(bufnr, file)
    if is_lock_file(file) then
        vim.bo[bufnr].readonly = false
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "",
            "  Lock file diff not shown.",
        })
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true
        return nil
    end

    local result = git.get_diff(file, state.state.base, state.state.base_end)
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

    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true

    apply_treesitter_highlights(bufnr, render_lines, display_lines, file)

    -- Find line pairs for word-level diff
    local line_pairs = find_line_pairs(render_lines)

    -- Detect new/deleted files from diff headers (not from line types)
    local is_new_file = parsed.file_old == "/dev/null"
    local is_deleted_file = parsed.file_new == "/dev/null"

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

    state.get_file_state(file).render_lines = render_lines

    return render_lines
end

---Render split (side-by-side) diff to two buffers
---@param old_bufnr number
---@param new_bufnr number
---@param file string
---@return table[]|nil old_lines, table[]|nil new_lines
local function render_split_diff(old_bufnr, new_bufnr, file)
    if is_lock_file(file) then
        for _, bufnr in ipairs({ old_bufnr, new_bufnr }) do
            vim.bo[bufnr].readonly = false
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "",
                "  Lock file diff not shown.",
            })
            vim.bo[bufnr].modifiable = false
            vim.bo[bufnr].readonly = true
        end
        return nil, nil
    end

    local result = git.get_diff(file, state.state.base, state.state.base_end)
    if not result.success then
        return nil, nil
    end

    if result.output == "" then
        return nil, nil
    end

    local parsed = diff_parser.parse(result.output)
    local old_lines, new_lines = diff_parser.get_split_render_lines(parsed)

    local old_display = {}
    local new_display = {}
    for _, line in ipairs(old_lines) do
        table.insert(old_display, line.content)
    end
    for _, line in ipairs(new_lines) do
        table.insert(new_display, line.content)
    end

    for _, bufnr in ipairs({ old_bufnr, new_bufnr }) do
        vim.bo[bufnr].readonly = false
        vim.bo[bufnr].modifiable = true
    end

    vim.api.nvim_buf_set_lines(old_bufnr, 0, -1, false, old_display)
    vim.api.nvim_buf_set_lines(new_bufnr, 0, -1, false, new_display)

    for _, bufnr in ipairs({ old_bufnr, new_bufnr }) do
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true
    end

    apply_treesitter_highlights(old_bufnr, old_lines, old_display, file)
    apply_treesitter_highlights(new_bufnr, new_lines, new_display, file)

    local is_new_file = parsed.file_old == "/dev/null"
    local is_deleted_file = parsed.file_new == "/dev/null"

    vim.api.nvim_buf_clear_namespace(old_bufnr, ns_diff, 0, -1)
    vim.api.nvim_buf_clear_namespace(new_bufnr, ns_diff, 0, -1)

    for i, line in ipairs(old_lines) do
        if line.type == "filepath" then
            local text = old_display[i] or ""
            if #text > 0 then
                vim.api.nvim_buf_set_extmark(old_bufnr, ns_diff, i - 1, 0, {
                    end_col = #text,
                    hl_group = "ReviewDiffFilePath",
                    priority = 10000,
                })
            end
        elseif line.type == "delete" then
            local extmark_opts = {
                sign_text = "▌",
                sign_hl_group = "ReviewDiffSignDelete",
            }
            if not is_deleted_file then
                extmark_opts.line_hl_group = "ReviewDiffDelete"
            end
            vim.api.nvim_buf_set_extmark(old_bufnr, ns_diff, i - 1, 0, extmark_opts)

            if line.pair_content then
                local ranges = compute_inline_diff(line.pair_content, line.content)
                for _, range in ipairs(ranges) do
                    if range[1] < range[2] then
                        vim.api.nvim_buf_add_highlight(
                            old_bufnr,
                            ns_diff,
                            "ReviewDiffDeleteInline",
                            i - 1,
                            range[1],
                            range[2]
                        )
                    end
                end
            end
        elseif line.type == "padding" then
            vim.api.nvim_buf_set_extmark(old_bufnr, ns_diff, i - 1, 0, {
                line_hl_group = "ReviewDiffPadding",
                sign_text = " ",
                sign_hl_group = "ReviewDiffSignContext",
            })
        elseif line.type == "context" then
            vim.api.nvim_buf_set_extmark(old_bufnr, ns_diff, i - 1, 0, {
                sign_text = " ",
                sign_hl_group = "ReviewDiffSignContext",
            })
        end
    end

    for i, line in ipairs(new_lines) do
        if line.type == "filepath" then
            local text = new_display[i] or ""
            if #text > 0 then
                vim.api.nvim_buf_set_extmark(new_bufnr, ns_diff, i - 1, 0, {
                    end_col = #text,
                    hl_group = "ReviewDiffFilePath",
                    priority = 10000,
                })
            end
        elseif line.type == "add" then
            local extmark_opts = {
                sign_text = "▌",
                sign_hl_group = "ReviewDiffSignAdd",
            }
            if not is_new_file then
                extmark_opts.line_hl_group = "ReviewDiffAdd"
            end
            vim.api.nvim_buf_set_extmark(new_bufnr, ns_diff, i - 1, 0, extmark_opts)

            if line.pair_content then
                local ranges = compute_inline_diff(line.pair_content, line.content)
                for _, range in ipairs(ranges) do
                    if range[1] < range[2] then
                        vim.api.nvim_buf_add_highlight(
                            new_bufnr,
                            ns_diff,
                            "ReviewDiffAddInline",
                            i - 1,
                            range[1],
                            range[2]
                        )
                    end
                end
            end
        elseif line.type == "padding" then
            vim.api.nvim_buf_set_extmark(new_bufnr, ns_diff, i - 1, 0, {
                line_hl_group = "ReviewDiffPadding",
                sign_text = " ",
                sign_hl_group = "ReviewDiffSignContext",
            })
        elseif line.type == "context" then
            vim.api.nvim_buf_set_extmark(new_bufnr, ns_diff, i - 1, 0, {
                sign_text = " ",
                sign_hl_group = "ReviewDiffSignContext",
            })
        end
    end

    state.get_file_state(file).render_lines = new_lines

    return old_lines, new_lines
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

---Check if a split line is a change
---@param line table
---@return boolean
local function is_split_change(line)
    return line.type == "add" or line.type == "delete"
end

---Navigate to next change (add/delete block)
local function goto_next_hunk()
    if not M.current or not M.current.render_lines then
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]
    local lines = M.split_state and M.split_state.new_lines or M.current.render_lines

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
    local lines = M.split_state and M.split_state.new_lines or M.current.render_lines

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
    local files = git.get_changed_files(state.state.base, state.state.base_end)
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

    local original_winid = vim.api.nvim_get_current_win()
    local original_cursor = vim.api.nvim_win_get_cursor(original_winid)

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]

    if M.split_state then
        local new_line = M.split_state.new_lines[line_num]
        if new_line and new_line.type == "padding" then
            vim.notify("Cannot comment on this line", vim.log.levels.WARN)
            return
        end
    end

    local source_line = get_current_source_line()
    local original_line = source_line or line_num
    local file = M.current.file
    local bufnr = M.current.bufnr

    -- Temporarily disable scrollbind/cursorbind in split mode to prevent scroll jump
    local split_windows = {}
    if M.split_state then
        if layout.current and layout.current.diff_view_old and layout.current.diff_view_new then
            local old_win = layout.current.diff_view_old.winid
            local new_win = layout.current.diff_view_new.winid
            for _, winid in ipairs({ old_win, new_win }) do
                if vim.api.nvim_win_is_valid(winid) then
                    table.insert(split_windows, winid)
                    vim.wo[winid].scrollbind = false
                    vim.wo[winid].cursorbind = false
                end
            end
        end
    end

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
    local win_opts = {
        relative = "cursor",
        row = 1,
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

    -- Function to close the input window and restore state
    local function close_input()
        if vim.api.nvim_win_is_valid(input_win) then
            vim.api.nvim_win_close(input_win, true)
        end
        if vim.api.nvim_buf_is_valid(input_buf) then
            vim.api.nvim_buf_delete(input_buf, { force = true })
        end
        if vim.api.nvim_win_is_valid(original_winid) then
            vim.api.nvim_set_current_win(original_winid)
            vim.api.nvim_win_set_cursor(original_winid, original_cursor)
        end
        for _, winid in ipairs(split_windows) do
            if vim.api.nvim_win_is_valid(winid) then
                vim.wo[winid].scrollbind = true
                vim.wo[winid].cursorbind = true
            end
        end
        if #split_windows > 0 then
            vim.cmd("syncbind")
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

    -- Template picker with Ctrl-T
    vim.keymap.set("i", "<C-t>", function()
        local cfg = require("review.config").get()
        local templates = cfg.templates
        if not templates or #templates == 0 then
            return
        end

        local picker_lines = {}
        for _, template in ipairs(templates) do
            table.insert(picker_lines, string.format("  %s  %s", template.key, template.label))
        end

        local picker_width = 30
        for _, line in ipairs(picker_lines) do
            picker_width = math.max(picker_width, vim.api.nvim_strwidth(line) + 4)
        end

        local picker_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(picker_buf, 0, -1, false, picker_lines)

        for line_idx, _ in ipairs(templates) do
            vim.api.nvim_buf_add_highlight(picker_buf, -1, "ReviewTemplateKey", line_idx - 1, 2, 3)
            vim.api.nvim_buf_add_highlight(picker_buf, -1, "ReviewTemplateLabel", line_idx - 1, 5, -1)
        end

        local picker_win = vim.api.nvim_open_win(picker_buf, true, {
            relative = "cursor",
            row = 1,
            col = 0,
            width = picker_width,
            height = #picker_lines,
            style = "minimal",
            border = "rounded",
            title = " Templates ",
            title_pos = "center",
        })

        vim.api.nvim_set_option_value(
            "winhighlight",
            "FloatBorder:ReviewTemplateBorder,FloatTitle:ReviewTemplateTitle",
            { win = picker_win }
        )

        local function close_picker()
            if vim.api.nvim_win_is_valid(picker_win) then
                vim.api.nvim_win_close(picker_win, true)
            end
            if vim.api.nvim_buf_is_valid(picker_buf) then
                vim.api.nvim_buf_delete(picker_buf, { force = true })
            end
            if vim.api.nvim_win_is_valid(input_win) then
                vim.api.nvim_set_current_win(input_win)
                vim.cmd("startinsert!")
            end
        end

        local function apply_template(template)
            close_picker()
            if vim.api.nvim_buf_is_valid(input_buf) then
                vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { template.text })
                if template.text:match(": $") then
                    vim.api.nvim_win_set_cursor(input_win, { 1, #template.text })
                else
                    submit()
                end
            end
        end

        for _, template in ipairs(templates) do
            vim.keymap.set("n", template.key, function()
                apply_template(template)
            end, { buffer = picker_buf, nowait = true })
        end

        vim.keymap.set("n", "<Esc>", close_picker, { buffer = picker_buf, nowait = true })
        vim.keymap.set("n", "q", close_picker, { buffer = picker_buf, nowait = true })
        vim.keymap.set("n", "<C-t>", close_picker, { buffer = picker_buf, nowait = true })
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

---@type {lhs: string, desc: string, group: string}[]
local registered_keymaps = {}

---Show help popup
local function show_help()
    local help = require("review.ui.help")
    help.show("Diff View", registered_keymaps)
end

---Setup keymaps for diff view
---@param bufnr number
---@param callbacks table
---@param old_bufnr number|nil
local function setup_keymaps(bufnr, callbacks, old_bufnr)
    registered_keymaps = {}

    ---Helper to register a keymap for help display and set it on one or more buffers
    ---@param lhs string
    ---@param rhs string|function
    ---@param opts table opts.group is used for help grouping (not passed to vim.keymap.set)
    ---@param target_bufnrs number[]
    local function map(lhs, rhs, opts, target_bufnrs)
        local group = opts.group
        opts.group = nil
        if opts.desc and group then
            table.insert(registered_keymaps, { lhs = lhs, desc = opts.desc, group = group })
        end
        for _, target_bufnr in ipairs(target_bufnrs) do
            local keymap_opts = vim.tbl_extend("force", opts, { buffer = target_bufnr })
            vim.keymap.set("n", lhs, rhs, keymap_opts)
        end
    end

    local function close_review()
        if callbacks.on_close then
            callbacks.on_close()
        end
    end

    local function toggle_mode()
        M.toggle_diff_mode(callbacks)
    end

    local all_bufnrs = old_bufnr and { bufnr, old_bufnr } or { bufnr }

    map("c", add_comment, { desc = "Add comment", group = "Comments" }, { bufnr })
    map("dc", delete_comment, { desc = "Delete comment", group = "Comments" }, { bufnr })
    map("]c", goto_next_hunk, { desc = "Next hunk", group = "Navigation" }, all_bufnrs)
    map("[c", goto_prev_hunk, { desc = "Previous hunk", group = "Navigation" }, all_bufnrs)
    map("]f", goto_next_file, { desc = "Next file", group = "Navigation" }, all_bufnrs)
    map("[f", goto_prev_file, { desc = "Previous file", group = "Navigation" }, all_bufnrs)
    map("S", toggle_mode, { desc = "Toggle split/unified diff", group = "View" }, all_bufnrs)
    map("<C-n>", function()
        local ui = require("review.ui")
        ui.toggle_file_tree()
    end, { desc = "Toggle file tree", group = "View" }, all_bufnrs)
    map("}", function()
        state.state.diff_context = state.state.diff_context + 1
        local ui = require("review.ui")
        ui.show_diff(state.state.current_file)
    end, { desc = "Expand diff context", group = "View" }, all_bufnrs)
    map("{", function()
        state.state.diff_context = math.max(0, state.state.diff_context - 1)
        local ui = require("review.ui")
        ui.show_diff(state.state.current_file)
    end, { desc = "Shrink diff context", group = "View" }, all_bufnrs)
    map("q", close_review, { nowait = true, desc = "Close review", group = "General" }, all_bufnrs)
    map("<Esc>", close_review, { nowait = true, desc = "Close review", group = "General" }, all_bufnrs)
    map("?", show_help, { desc = "Show help", group = "General" }, all_bufnrs)
end

---Apply common window options to a diff view window
---@param winid number
---@param bufnr number
local function apply_diff_view_win_options(winid, bufnr)
    vim.wo[winid].spell = false
    vim.wo[winid].list = false

    local ext = state.state.current_file and vim.fn.fnamemodify(state.state.current_file, ":e") or ""
    local wrap = ext == "md" or ext == "txt"
    vim.wo[winid].wrap = wrap
    vim.wo[winid].linebreak = wrap
end

---Create the diff view component
---@param layout_component table { bufnr: number, winid: number }
---@param file string
---@param callbacks table
---@return DiffViewComponent
function M.create(layout_component, file, callbacks)
    local bufnr = layout_component.bufnr

    if state.state.diff_mode == "split" then
        if not layout.is_split_mode() then
            layout.enter_split_mode()
        end

        local old_component = layout.get_diff_view_old()
        local new_component = layout.get_diff_view_new()

        if not old_component or not new_component then
            state.state.diff_mode = "unified"
            return M.create(layout_component, file, callbacks)
        end

        local old_lines, new_lines = render_split_diff(old_component.bufnr, new_component.bufnr, file)

        if not old_lines then
            state.state.diff_mode = "unified"
            layout.exit_split_mode()
            return M.create(layout_component, file, callbacks)
        end

        M.split_state = {
            old_bufnr = old_component.bufnr,
            new_bufnr = new_component.bufnr,
            old_lines = old_lines,
            new_lines = new_lines,
        }

        M.current = {
            bufnr = new_component.bufnr,
            winid = new_component.winid,
            file = file,
            render_lines = new_lines,
            ns_id = ns_diff,
        }

        render_comments(new_component.bufnr, file)

        setup_keymaps(new_component.bufnr, callbacks, old_component.bufnr)

        pcall(vim.api.nvim_buf_set_name, old_component.bufnr, "Review (old): " .. file)
        pcall(vim.api.nvim_buf_set_name, new_component.bufnr, "Review (new): " .. file)

        apply_diff_view_win_options(old_component.winid, old_component.bufnr)
        apply_diff_view_win_options(new_component.winid, new_component.bufnr)

        return M.current
    end

    if layout.is_split_mode() then
        layout.exit_split_mode()
    end
    M.split_state = nil

    local render_lines = render_diff(bufnr, file)

    M.current = {
        bufnr = bufnr,
        winid = layout_component.winid,
        file = file,
        render_lines = render_lines,
        ns_id = ns_diff,
    }

    render_comments(bufnr, file)

    setup_keymaps(bufnr, callbacks)

    pcall(vim.api.nvim_buf_set_name, bufnr, "Review: " .. file)

    apply_diff_view_win_options(layout_component.winid, bufnr)

    return M.current
end

---Toggle between unified and split diff modes
---@param callbacks table
function M.toggle_diff_mode(callbacks)
    if not M.current then
        return
    end

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local source_line = nil
    local current_render_lines = M.split_state and M.split_state.new_lines or M.current.render_lines

    if current_render_lines and current_render_lines[cursor_line] then
        source_line = current_render_lines[cursor_line].source_line
            or current_render_lines[cursor_line].new_line
            or current_render_lines[cursor_line].old_line
    end

    if state.state.diff_mode == "unified" then
        state.state.diff_mode = "split"
    else
        state.state.diff_mode = "unified"
    end

    local diff_split = layout.get_diff_view()
    if not diff_split then
        return
    end

    M.create(diff_split, M.current.file, callbacks)

    if source_line and M.current.render_lines then
        local target_lines = M.split_state and M.split_state.new_lines or M.current.render_lines
        for i, line in ipairs(target_lines) do
            local line_nr = line.source_line or line.new_line or line.old_line
            if line_nr and line_nr >= source_line then
                pcall(vim.api.nvim_win_set_cursor, 0, { i, 0 })
                return
            end
        end
    end
end

---Render the diff (for refreshing)
function M.render()
    if not M.current then
        return
    end

    if M.split_state then
        local old_lines, new_lines = render_split_diff(M.split_state.old_bufnr, M.split_state.new_bufnr, M.current.file)
        if old_lines then
            M.split_state.old_lines = old_lines
            M.split_state.new_lines = new_lines
            M.current.render_lines = new_lines
        end
        render_comments(M.split_state.new_bufnr, M.current.file)
    else
        M.current.render_lines = render_diff(M.current.bufnr, M.current.file)
        render_comments(M.current.bufnr, M.current.file)
    end
end

---Render a full commit diff (all files) into a single buffer for preview
---@param layout_component table { bufnr: number, winid: number }
---@param base string
---@param base_end string
---@param preview_callbacks table { on_close: function }
function M.create_commit_preview(layout_component, base, base_end, preview_callbacks)
    local bufnr = layout_component.bufnr

    if layout.is_split_mode() then
        layout.exit_split_mode()
    end
    M.split_state = nil

    local files = git.get_changed_files(base, base_end)

    local max_preview_files = 50

    if #files > max_preview_files then
        vim.bo[bufnr].readonly = false
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "",
            "  Commit has " .. #files .. " changed files.",
            "  Preview is disabled for commits with more than " .. max_preview_files .. " files.",
            "",
            "  Press <CR> to select this commit and browse files individually.",
        })
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true

        M.current = {
            bufnr = bufnr,
            winid = layout_component.winid,
            file = nil,
            render_lines = nil,
            ns_id = ns_diff,
        }
        return
    end

    if #files == 0 then
        vim.bo[bufnr].readonly = false
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
            "",
            "  No changes in this commit.",
        })
        vim.bo[bufnr].modifiable = false
        vim.bo[bufnr].readonly = true

        M.current = {
            bufnr = bufnr,
            winid = layout_component.winid,
            file = nil,
            render_lines = nil,
            ns_id = ns_diff,
        }
        return
    end

    local all_display_lines = {}
    local all_render_lines = {}
    local file_sections = {}

    local win_width = 80
    if layout_component.winid and vim.api.nvim_win_is_valid(layout_component.winid) then
        local win_info = vim.fn.getwininfo(layout_component.winid)
        local text_off = win_info[1] and win_info[1].textoff or 0
        win_width = vim.api.nvim_win_get_width(layout_component.winid) - text_off
    end

    local combined_result = git.get_commit_diff(base, base_end)
    if combined_result.success and combined_result.output ~= "" then
        local diff_chunks = vim.split(combined_result.output, "\ndiff --git ", { plain = true })

        for chunk_index, chunk in ipairs(diff_chunks) do
            local raw_chunk = chunk
            if chunk_index > 1 then
                raw_chunk = "diff --git " .. chunk
            end

            local file_path = raw_chunk:match("\n%-%-%- a/(.-)%s*\n") or raw_chunk:match("\n%+%+%+ b/(.-)%s*\n")
            if not file_path then
                file_path = raw_chunk:match("diff %-%-git a/(.-) b/")
            end

            if file_path then
                local parsed = diff_parser.parse(raw_chunk)
                local raw_lines = diff_parser.get_render_lines(parsed)

                local render_line_count = 0
                for _, line in ipairs(raw_lines) do
                    if line.type ~= "header" then
                        render_line_count = render_line_count + 1
                    end
                end

                local max_preview_lines = 1000

                local top_border = string.rep("▁", win_width)
                local bottom_border = string.rep("▔", win_width)

                table.insert(all_display_lines, top_border)
                table.insert(all_render_lines, { type = "file_divider_border_top", content = top_border })

                local label = "  " .. file_path
                table.insert(all_display_lines, label)
                table.insert(all_render_lines, { type = "file_divider", content = label })

                table.insert(all_display_lines, bottom_border)
                table.insert(all_render_lines, { type = "file_divider_border_bottom", content = bottom_border })

                local section_start = #all_display_lines + 1

                if render_line_count > max_preview_lines then
                    local placeholder = "  (diff too large — " .. render_line_count .. " lines)"
                    table.insert(all_display_lines, placeholder)
                    table.insert(all_render_lines, { type = "context", content = placeholder })
                else
                    local is_new_file = parsed.file_old == "/dev/null"
                    local is_deleted_file = parsed.file_new == "/dev/null"

                    for _, line in ipairs(raw_lines) do
                        if line.type ~= "header" then
                            local content = line.content or ""
                            table.insert(all_display_lines, content)
                            table.insert(all_render_lines, line)
                        end
                    end

                    table.insert(file_sections, {
                        file = file_path,
                        start_line = section_start,
                        end_line = #all_display_lines,
                        is_new_file = is_new_file,
                        is_deleted_file = is_deleted_file,
                    })
                end
            end
        end
    end

    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, all_display_lines)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true

    vim.api.nvim_buf_clear_namespace(bufnr, ns_syntax, 0, -1)

    local line_pairs = find_line_pairs(all_render_lines)

    vim.api.nvim_buf_clear_namespace(bufnr, ns_diff, 0, -1)

    local section_lookup = {}
    for _, section in ipairs(file_sections) do
        for line_index = section.start_line, section.end_line do
            section_lookup[line_index] = section
        end
    end

    for line_index, line in ipairs(all_render_lines) do
        local sign_hl = nil
        local sign_text = "▌"
        local inline_hl = nil
        local line_hl = nil

        local section = section_lookup[line_index]
        local is_new_file = section and section.is_new_file
        local is_deleted_file = section and section.is_deleted_file

        if line.type == "file_divider_border_top" then
            vim.api.nvim_buf_set_extmark(bufnr, ns_diff, line_index - 1, 0, {
                end_col = #(all_display_lines[line_index] or ""),
                hl_group = "ReviewDiffFileDividerBorderTop",
                priority = 10000,
            })
        elseif line.type == "file_divider_border_bottom" then
            vim.api.nvim_buf_set_extmark(bufnr, ns_diff, line_index - 1, 0, {
                end_col = #(all_display_lines[line_index] or ""),
                hl_group = "ReviewDiffFileDividerBorderBottom",
                priority = 10000,
            })
        elseif line.type == "file_divider" then
            vim.api.nvim_buf_set_extmark(bufnr, ns_diff, line_index - 1, 0, {
                end_col = #(all_display_lines[line_index] or ""),
                hl_group = "ReviewDiffFileDivider",
                line_hl_group = "ReviewDiffFileHeaderBg",
                priority = 10000,
            })
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

        if sign_hl then
            local extmark_opts = {
                sign_text = sign_text,
                sign_hl_group = sign_hl,
            }
            if line_hl and not is_new_file and not is_deleted_file then
                extmark_opts.line_hl_group = line_hl
            end
            vim.api.nvim_buf_set_extmark(bufnr, ns_diff, line_index - 1, 0, extmark_opts)
        end

        if inline_hl and line_pairs[line_index] then
            local old_content = line_pairs[line_index]
            local new_content = line.content or ""
            local inline_ranges = compute_inline_diff(old_content, new_content)

            for _, range in ipairs(inline_ranges) do
                if range[1] < range[2] then
                    vim.api.nvim_buf_add_highlight(bufnr, ns_diff, inline_hl, line_index - 1, range[1], range[2])
                end
            end
        end
    end

    local total_diff_lines = #all_display_lines
    local max_treesitter_lines = 500

    if total_diff_lines <= max_treesitter_lines then
        for _, section in ipairs(file_sections) do
            local section_render_lines = {}
            local section_display_lines = {}
            for line_index = section.start_line, section.end_line do
                table.insert(section_render_lines, all_render_lines[line_index])
                table.insert(section_display_lines, all_display_lines[line_index])
            end

            apply_treesitter_highlights(
                bufnr,
                section_render_lines,
                section_display_lines,
                section.file,
                section.start_line - 1,
                base,
                base_end
            )
        end
    end

    M.current = {
        bufnr = bufnr,
        winid = layout_component.winid,
        file = nil,
        render_lines = all_render_lines,
        ns_id = ns_diff,
    }

    vim.api.nvim_buf_clear_namespace(bufnr, ns_comments, 0, -1)

    local function close_review()
        if preview_callbacks.on_close then
            preview_callbacks.on_close()
        end
    end

    registered_keymaps = {}
    vim.keymap.set("n", "q", close_review, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Esc>", close_review, { buffer = bufnr, nowait = true })

    pcall(vim.api.nvim_buf_set_name, bufnr, "Review: commit preview")

    vim.wo[layout_component.winid].spell = false
    vim.wo[layout_component.winid].list = false
    vim.wo[layout_component.winid].wrap = false
    vim.wo[layout_component.winid].linebreak = false
end

---Get the current component
---@return DiffViewComponent|nil
function M.get()
    return M.current
end

---Destroy the component
function M.destroy()
    M.current = nil
    M.split_state = nil
end

return M
