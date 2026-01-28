---@class QuickComment
---@field id string Unique identifier
---@field file string Absolute file path
---@field line number Source file line number
---@field type "note"|"fix"|"question"
---@field text string Comment text
---@field created_at number Timestamp
---@field context string|nil Line content at creation time

---@class QuickCommentsState
---@field comments table<string, QuickComment[]> Comments indexed by file path
---@field comment_id_counter number
---@field panel_open boolean

local M = {}

---@type QuickCommentsState
M.state = {
    comments = {},
    comment_id_counter = 0,
    panel_open = false,
}

---Generate a unique comment ID
---@return string
function M.generate_id()
    M.state.comment_id_counter = M.state.comment_id_counter + 1
    return string.format("qc_%d_%d", os.time(), M.state.comment_id_counter)
end

---Add a quick comment
---@param file string Absolute file path
---@param line number Line number
---@param type "note"|"fix"|"question"
---@param text string Comment text
---@param context string|nil Line content at creation time
---@return QuickComment
function M.add(file, line, type, text, context)
    if not M.state.comments[file] then
        M.state.comments[file] = {}
    end

    local comment = {
        id = M.generate_id(),
        file = file,
        line = line,
        type = type,
        text = text,
        created_at = os.time(),
        context = context,
    }

    table.insert(M.state.comments[file], comment)

    -- Sort by line number
    table.sort(M.state.comments[file], function(a, b)
        return a.line < b.line
    end)

    return comment
end

---Remove a comment by ID
---@param file string File path
---@param comment_id string Comment ID
---@return boolean success
function M.remove(file, comment_id)
    local comments = M.state.comments[file]
    if not comments then
        return false
    end

    for i, comment in ipairs(comments) do
        if comment.id == comment_id then
            table.remove(comments, i)
            -- Clean up empty file entries
            if #comments == 0 then
                M.state.comments[file] = nil
            end
            return true
        end
    end

    return false
end

---Update a comment's text
---@param file string File path
---@param comment_id string Comment ID
---@param new_text string New comment text
---@return boolean success
function M.update(file, comment_id, new_text)
    local comments = M.state.comments[file]
    if not comments then
        return false
    end

    for _, comment in ipairs(comments) do
        if comment.id == comment_id then
            comment.text = new_text
            return true
        end
    end

    return false
end

---Get a comment by ID
---@param file string File path
---@param comment_id string Comment ID
---@return QuickComment|nil
function M.get(file, comment_id)
    local comments = M.state.comments[file]
    if not comments then
        return nil
    end

    for _, comment in ipairs(comments) do
        if comment.id == comment_id then
            return comment
        end
    end

    return nil
end

---Get comment at a specific line
---@param file string File path
---@param line number Line number
---@return QuickComment|nil
function M.get_at_line(file, line)
    local comments = M.state.comments[file]
    if not comments then
        return nil
    end

    for _, comment in ipairs(comments) do
        if comment.line == line then
            return comment
        end
    end

    return nil
end

---Get all comments for a file
---@param file string File path
---@return QuickComment[]
function M.get_for_file(file)
    return M.state.comments[file] or {}
end

---Get all comments grouped by file
---@return table<string, QuickComment[]>
function M.get_all()
    return M.state.comments
end

---Get all comments as a flat list, sorted by file then line
---@return QuickComment[]
function M.get_all_flat()
    local all = {}

    for _, comments in pairs(M.state.comments) do
        for _, comment in ipairs(comments) do
            table.insert(all, comment)
        end
    end

    table.sort(all, function(a, b)
        if a.file ~= b.file then
            return a.file < b.file
        end
        return a.line < b.line
    end)

    return all
end

---Get total comment count
---@return number
function M.count()
    local total = 0
    for _, comments in pairs(M.state.comments) do
        total = total + #comments
    end
    return total
end

---Get list of files with comments
---@return string[]
function M.get_files()
    local files = {}
    for file, _ in pairs(M.state.comments) do
        table.insert(files, file)
    end
    table.sort(files)
    return files
end

---Clear all comments
function M.clear()
    M.state.comments = {}
end

---Reset state (for testing)
function M.reset()
    M.state = {
        comments = {},
        comment_id_counter = 0,
        panel_open = false,
    }
end

---Load state from persistence data
---@param data table
function M.load(data)
    if data.comments then
        M.state.comments = data.comments
    end
    if data.comment_id_counter then
        M.state.comment_id_counter = data.comment_id_counter
    end
end

---Export state for persistence
---@return table
function M.export()
    return {
        comments = M.state.comments,
        comment_id_counter = M.state.comment_id_counter,
    }
end

return M
