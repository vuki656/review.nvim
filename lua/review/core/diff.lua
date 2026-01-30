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
        hunks = {},
    }

    if not diff_text or diff_text == "" then
        return result
    end

    local lines = vim.split(diff_text, "\n", { plain = true })
    local current_hunk = nil
    local old_line = 0
    local new_line = 0

    for _, line in ipairs(lines) do
        -- Parse file headers
        if line:match("^%-%-%- ") then
            result.file_old = line:match("^%-%-%- a/(.+)$") or line:match("^%-%-%- (.+)$")
        elseif line:match("^%+%+%+ ") then
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

---Get the source line number for a rendered line
---@param rendered_line_num number 1-based line number in rendered buffer
---@param render_lines DiffLine[]
---@return number|nil original_line, "old"|"new"|nil side
function M.get_source_line(rendered_line_num, render_lines)
    local line = render_lines[rendered_line_num]
    if not line then
        return nil, nil
    end

    if line.type == "add" then
        return line.new_line, "new"
    elseif line.type == "delete" then
        return line.old_line, "old"
    elseif line.type == "context" then
        return line.new_line, "new"
    end

    return nil, nil
end

return M
