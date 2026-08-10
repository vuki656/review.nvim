---@class ReviewComment
---@field id string Unique identifier
---@field file string File path
---@field line number Display row in the current rendering, re-anchored on render
---@field end_line number|nil Last display row of a multi-line comment, re-anchored on render
---@field original_line number|nil Original line in source file
---@field original_end_line number|nil Last original line of a multi-line comment
---@field side "old"|"new"|nil Which side of the diff original_line refers to
---@field type "note"|"fix"|"question"
---@field text string Comment text
---@field created_at number Timestamp

---@class ReviewFileState
---@field path string File path
---@field reviewed boolean Whether file has been reviewed (staged)
---@field comments ReviewComment[]
---@field render_lines table[]|nil Cached parsed diff lines for export context

---@class ReviewState
---@field is_open boolean Whether UI is currently open
---@field files table<string, ReviewFileState>
---@field current_file string|nil Currently selected file
---@field diff_mode "unified"|"split"
---@field base string Git base for comparison
---@field base_end string|nil End of commit range (for history mode: base..base_end)
---@field comment_id_counter number
---@field diff_context number

local M = {}

local DEFAULT_STATE = {
    is_open = false,
    files = {},
    current_file = nil,
    diff_mode = "unified",
    base = "HEAD",
    base_end = nil,
    comment_id_counter = 0,
    is_pushing = false,
    diff_context = 3,
}

---@type ReviewState
M.state = vim.deepcopy(DEFAULT_STATE)

function M.reset()
    M.state = vim.deepcopy(DEFAULT_STATE)
end

---@return boolean
function M.is_history_mode()
    return M.state.base ~= nil and M.state.base ~= "HEAD"
end

---@param file string
---@return ReviewFileState
function M.get_file_state(file)
    if not M.state.files[file] then
        M.state.files[file] = {
            path = file,
            reviewed = false,
            comments = {},
        }
    end
    return M.state.files[file]
end

---@param file string
---@param reviewed boolean
function M.set_reviewed(file, reviewed)
    local file_state = M.get_file_state(file)
    file_state.reviewed = reviewed
end

---@param file string
---@return boolean
function M.is_reviewed(file)
    local file_state = M.state.files[file]
    return file_state and file_state.reviewed or false
end

---@return string
function M.generate_comment_id()
    M.state.comment_id_counter = M.state.comment_id_counter + 1
    return string.format("comment_%d_%d", M.state.comment_id_counter, vim.uv.os_getpid())
end

---@param file string
---@param line number
---@param type "note"|"fix"|"question"
---@param text string
---@param original_line number|nil
---@param side "old"|"new"|nil
---@param end_line number|nil
---@param original_end_line number|nil
---@return ReviewComment
function M.add_comment(file, line, type, text, original_line, side, end_line, original_end_line)
    local file_state = M.get_file_state(file)
    if end_line and end_line <= line then
        end_line = nil
    end
    if original_end_line and original_line and original_end_line <= original_line then
        original_end_line = nil
    end
    local comment = {
        id = M.generate_comment_id(),
        file = file,
        line = line,
        end_line = end_line,
        original_line = original_line,
        original_end_line = original_end_line,
        side = side,
        type = type,
        text = text,
        created_at = os.time(),
    }
    table.insert(file_state.comments, comment)
    return comment
end

---@param file string
---@param comment_id string
---@return boolean
function M.remove_comment(file, comment_id)
    local file_state = M.state.files[file]
    if not file_state then
        return false
    end

    for i, comment in ipairs(file_state.comments) do
        if comment.id == comment_id then
            table.remove(file_state.comments, i)
            return true
        end
    end
    return false
end

---@param file string
---@param line number
---@return ReviewComment|nil
function M.get_comment_at_line(file, line)
    local file_state = M.state.files[file]
    if not file_state then
        return nil
    end

    for _, comment in ipairs(file_state.comments) do
        if line >= comment.line and line <= (comment.end_line or comment.line) then
            return comment
        end
    end
    return nil
end

---@param file string
---@return ReviewComment[]
function M.get_comments_for_file(file)
    local file_state = M.state.files[file]
    if not file_state then
        return {}
    end
    return file_state.comments
end

---@return ReviewComment[]
function M.get_all_comments()
    local all_comments = {}
    for _, file_state in pairs(M.state.files) do
        for _, comment in ipairs(file_state.comments) do
            table.insert(all_comments, comment)
        end
    end
    -- Sort by file, then by line
    table.sort(all_comments, function(a, b)
        if a.file ~= b.file then
            return a.file < b.file
        end
        return a.line < b.line
    end)
    return all_comments
end

---@return table<string, ReviewComment[]>
function M.get_comments_grouped_by_file()
    local grouped = {}
    for file, file_state in pairs(M.state.files) do
        if #file_state.comments > 0 then
            -- Sort comments by line number
            local sorted_comments = vim.deepcopy(file_state.comments)
            table.sort(sorted_comments, function(a, b)
                return a.line < b.line
            end)
            grouped[file] = sorted_comments
        end
    end
    return grouped
end

---Clear all comments across all files
---@return number count Number of comments cleared
function M.clear_all_comments()
    local count = 0
    for _, file_state in pairs(M.state.files) do
        count = count + #file_state.comments
        file_state.comments = {}
    end
    return count
end

return M
