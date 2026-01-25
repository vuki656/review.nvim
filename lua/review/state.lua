---@class ReviewComment
---@field id string Unique identifier
---@field file string File path
---@field line number Line number in the diff
---@field original_line number|nil Original line in source file
---@field type "note"|"fix"|"question"
---@field text string Comment text
---@field created_at number Timestamp

---@class ReviewFileState
---@field path string File path
---@field reviewed boolean Whether file has been reviewed (staged)
---@field comments ReviewComment[]

---@class ReviewState
---@field is_open boolean Whether UI is currently open
---@field files table<string, ReviewFileState>
---@field current_file string|nil Currently selected file
---@field diff_mode "unified"|"split"
---@field base string Git base for comparison
---@field comment_id_counter number

local M = {}

---@type ReviewState
M.state = {
    is_open = false,
    files = {},
    current_file = nil,
    diff_mode = "unified",
    base = "HEAD",
    comment_id_counter = 0,
}

function M.reset()
    M.state = {
        is_open = false,
        files = {},
        current_file = nil,
        diff_mode = "unified",
        base = "HEAD",
        comment_id_counter = 0,
    }
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
    return string.format("comment_%d", M.state.comment_id_counter)
end

---@param file string
---@param line number
---@param type "note"|"fix"|"question"
---@param text string
---@param original_line number|nil
---@return ReviewComment
function M.add_comment(file, line, type, text, original_line)
    local file_state = M.get_file_state(file)
    local comment = {
        id = M.generate_comment_id(),
        file = file,
        line = line,
        original_line = original_line,
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
        if comment.line == line then
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

return M
