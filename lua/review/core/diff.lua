---@class DiffHunk
---@field header string The @@ header line
---@field old_start number Starting line in old file
---@field old_count number Number of lines in old file
---@field new_start number Starting line in new file
---@field new_count number Number of lines in new file
---@field lines DiffLine[]

---@class DiffLine
---@field type "context"|"add"|"delete"|"header"
---@field content string The line content (without +/- prefix)
---@field raw string The raw line with prefix
---@field old_line number|nil Line number in old file
---@field new_line number|nil Line number in new file

---@class ParsedDiff
---@field file_old string|nil Old file path
---@field file_new string|nil New file path
---@field binary boolean Whether git reported the file as binary
---@field hunks DiffHunk[]

local M = {}

---Parse the @@ header to extract line numbers
---@param header string
---@return number old_start, number old_count, number new_start, number new_count
local function parse_hunk_header(header)
    -- Format: @@ -old_start,old_count +new_start,new_count @@
    local old_start, old_count, new_start, new_count = header:match("@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")

    old_start = tonumber(old_start) or 1
    old_count = tonumber(old_count) or 1
    new_start = tonumber(new_start) or 1
    new_count = tonumber(new_count) or 1

    return old_start, old_count, new_start, new_count
end

---Parse a unified diff string into structured format
---@param diff_text string Raw unified diff output
---@return ParsedDiff
function M.parse(diff_text)
    local result = {
        file_old = nil,
        file_new = nil,
        binary = false,
        hunks = {},
    }

    if not diff_text or diff_text == "" then
        return result
    end

    if diff_text:match("^Binary files ") or diff_text:match("\nBinary files ") then
        result.binary = true
    end

    local lines = vim.split((diff_text:gsub("\r\n", "\n")), "\n", { plain = true })
    local current_hunk = nil
    local old_line = 0
    local new_line = 0

    for _, line in ipairs(lines) do
        -- Parse file headers
        if line:match("^diff %-%-git ") then
            current_hunk = nil
        elseif current_hunk == nil and line:match("^%-%-%- ") then
            result.file_old = line:match("^%-%-%- a/(.+)$") or line:match("^%-%-%- (.+)$")
        elseif current_hunk == nil and line:match("^%+%+%+ ") then
            result.file_new = line:match("^%+%+%+ b/(.+)$") or line:match("^%+%+%+ (.+)$")
        elseif line:match("^@@ ") then
            -- Start new hunk
            local old_start, old_count, new_start, new_count = parse_hunk_header(line)
            current_hunk = {
                header = line,
                old_start = old_start,
                old_count = old_count,
                new_start = new_start,
                new_count = new_count,
                lines = {},
            }
            table.insert(result.hunks, current_hunk)
            old_line = old_start
            new_line = new_start
        elseif current_hunk then
            -- Parse diff lines
            local prefix = line:sub(1, 1)
            local content = line:sub(2)

            if prefix == "+" then
                table.insert(current_hunk.lines, {
                    type = "add",
                    content = content,
                    raw = line,
                    old_line = nil,
                    new_line = new_line,
                })
                new_line = new_line + 1
            elseif prefix == "-" then
                table.insert(current_hunk.lines, {
                    type = "delete",
                    content = content,
                    raw = line,
                    old_line = old_line,
                    new_line = nil,
                })
                old_line = old_line + 1
            elseif prefix == " " then
                table.insert(current_hunk.lines, {
                    type = "context",
                    content = content,
                    raw = line,
                    old_line = old_line,
                    new_line = new_line,
                })
                old_line = old_line + 1
                new_line = new_line + 1
            end
        end
    end

    return result
end

---Get all lines for rendering (flattened from hunks)
---@param parsed_diff ParsedDiff
---@return DiffLine[]
function M.get_render_lines(parsed_diff)
    local render_lines = {}

    for _, hunk in ipairs(parsed_diff.hunks) do
        -- Add hunk header as special line
        table.insert(render_lines, {
            type = "header",
            content = hunk.header,
            raw = hunk.header,
            old_line = nil,
            new_line = nil,
        })

        -- Add all lines from hunk
        for _, line in ipairs(hunk.lines) do
            table.insert(render_lines, line)
        end
    end

    return render_lines
end

---@class SplitLine
---@field type "context"|"add"|"delete"|"padding"|"filepath"
---@field content string
---@field source_line number|nil
---@field pair_content string|nil

---Get aligned split render lines for side-by-side diff
---@param parsed_diff ParsedDiff
---@return SplitLine[] old_lines, SplitLine[] new_lines
function M.get_split_render_lines(parsed_diff)
    local old_lines = {}
    local new_lines = {}

    local file_path = parsed_diff.file_new or parsed_diff.file_old or ""

    table.insert(old_lines, { type = "filepath", content = file_path, source_line = nil, pair_content = nil })
    table.insert(new_lines, { type = "filepath", content = file_path, source_line = nil, pair_content = nil })
    table.insert(old_lines, { type = "filepath", content = "", source_line = nil, pair_content = nil })
    table.insert(new_lines, { type = "filepath", content = "", source_line = nil, pair_content = nil })

    for _, hunk in ipairs(parsed_diff.hunks) do
        local line_idx = 1
        local lines = hunk.lines

        while line_idx <= #lines do
            local line = lines[line_idx]

            if line.type == "context" then
                table.insert(old_lines, {
                    type = "context",
                    content = line.content,
                    source_line = line.old_line,
                    pair_content = nil,
                })
                table.insert(new_lines, {
                    type = "context",
                    content = line.content,
                    source_line = line.new_line,
                    pair_content = nil,
                })
                line_idx = line_idx + 1
            elseif line.type == "delete" then
                local deletes = {}
                local scan = line_idx
                while scan <= #lines and lines[scan].type == "delete" do
                    table.insert(deletes, lines[scan])
                    scan = scan + 1
                end

                local adds = {}
                while scan <= #lines and lines[scan].type == "add" do
                    table.insert(adds, lines[scan])
                    scan = scan + 1
                end

                local max_count = math.max(#deletes, #adds)
                for pair_idx = 1, max_count do
                    local delete_line = deletes[pair_idx]
                    local add_line = adds[pair_idx]

                    if delete_line and add_line then
                        table.insert(old_lines, {
                            type = "delete",
                            content = delete_line.content,
                            source_line = delete_line.old_line,
                            pair_content = add_line.content,
                        })
                        table.insert(new_lines, {
                            type = "add",
                            content = add_line.content,
                            source_line = add_line.new_line,
                            pair_content = delete_line.content,
                        })
                    elseif delete_line then
                        table.insert(old_lines, {
                            type = "delete",
                            content = delete_line.content,
                            source_line = delete_line.old_line,
                            pair_content = nil,
                        })
                        table.insert(new_lines, {
                            type = "padding",
                            content = "",
                            source_line = nil,
                            pair_content = nil,
                        })
                    elseif add_line then
                        table.insert(old_lines, {
                            type = "padding",
                            content = "",
                            source_line = nil,
                            pair_content = nil,
                        })
                        table.insert(new_lines, {
                            type = "add",
                            content = add_line.content,
                            source_line = add_line.new_line,
                            pair_content = nil,
                        })
                    end
                end

                line_idx = scan
            elseif line.type == "add" then
                table.insert(old_lines, {
                    type = "padding",
                    content = "",
                    source_line = nil,
                    pair_content = nil,
                })
                table.insert(new_lines, {
                    type = "add",
                    content = line.content,
                    source_line = line.new_line,
                    pair_content = nil,
                })
                line_idx = line_idx + 1
            else
                line_idx = line_idx + 1
            end
        end
    end

    return old_lines, new_lines
end

---Get the source line number for a rendered line
---@param rendered_line_num number 1-based line number in rendered buffer
---@param render_lines DiffLine[]|SplitLine[]
---@return number|nil original_line, "old"|"new"|nil side
function M.get_source_line(rendered_line_num, render_lines)
    local line = render_lines[rendered_line_num]
    if not line then
        return nil, nil
    end

    if line.type ~= "add" and line.type ~= "delete" and line.type ~= "context" then
        return nil, nil
    end

    local side = line.type == "delete" and "old" or "new"

    if line.source_line then
        return line.source_line, side
    end

    if line.type == "delete" then
        return line.old_line, "old"
    end

    return line.new_line, "new"
end

---Resolve the source lines a display row range covers
---The range is anchored to the first row that has a source line, and only rows on that
---same side contribute, so a selection spanning both sides never mixes them
---@param start_row number
---@param end_row number
---@param render_lines DiffLine[]|SplitLine[]|nil
---@return table|nil range { line, end_line, original_line, original_end_line, side }
function M.get_source_range(start_row, end_row, render_lines)
    if not render_lines then
        return nil
    end

    local anchor_row, first, side
    for row = start_row, end_row do
        local source, row_side = M.get_source_line(row, render_lines)
        if source then
            anchor_row, first, side = row, source, row_side
            break
        end
    end

    if not first then
        return nil
    end

    local last_row, last
    for row = anchor_row + 1, end_row do
        local source, row_side = M.get_source_line(row, render_lines)
        if source and row_side == side then
            last_row, last = row, source
        end
    end

    return {
        line = anchor_row,
        end_line = last_row,
        original_line = first,
        original_end_line = last,
        side = side,
    }
end

---Resolve the display row a source line sits on in the current rendering
---@param source_line number|nil
---@param side "old"|"new"|nil
---@param render_lines DiffLine[]|SplitLine[]|nil
---@return number|nil
function M.find_display_row(source_line, side, render_lines)
    if not source_line or not render_lines then
        return nil
    end

    local want_old = side == "old"

    for index, line in ipairs(render_lines) do
        local is_old = line.type == "delete"
        if is_old == want_old then
            local source = line.source_line or (is_old and line.old_line or line.new_line)
            if source == source_line then
                return index
            end
        end
    end

    return nil
end

---Re-anchor a comment's display rows against the current rendering
---Falls back to the existing display row when the start line is gone, and degrades to a
---single-line comment when the end line is gone, keeping original_end_line for export
---@param comment ReviewComment
---@param render_lines DiffLine[]|SplitLine[]
function M.reanchor_comment(comment, render_lines)
    comment.line = M.find_display_row(comment.original_line, comment.side, render_lines) or comment.line

    if not comment.end_line and not comment.original_end_line then
        return
    end

    local end_row = M.find_display_row(comment.original_end_line, comment.side, render_lines)
    if end_row and end_row > comment.line then
        comment.end_line = end_row
    else
        comment.end_line = nil
    end
end

return M
