local M = {}

---@class CommentTypeInfo
---@field id "note"|"fix"|"question"
---@field label string
---@field key string Single key shortcut
---@field number_key string Number key shortcut
---@field highlight string Highlight group
---@field icon string Icon/prefix for display

---@type CommentTypeInfo[]
M.types = {
    {
        id = "note",
        label = "Note",
        key = "n",
        number_key = "1",
        highlight = "ReviewCommentNote",
        icon = "",
    },
    {
        id = "fix",
        label = "Fix",
        key = "f",
        number_key = "2",
        highlight = "ReviewCommentFix",
        icon = "",
    },
    {
        id = "question",
        label = "Question",
        key = "q",
        number_key = "3",
        highlight = "ReviewCommentQuestion",
        icon = "",
    },
}

---Get type info by id
---@param id "note"|"fix"|"question"
---@return CommentTypeInfo|nil
function M.get(id)
    for _, t in ipairs(M.types) do
        if t.id == id then
            return t
        end
    end
    return nil
end

---Get type info by key
---@param key string
---@return CommentTypeInfo|nil
function M.get_by_key(key)
    for _, t in ipairs(M.types) do
        if t.key == key or t.number_key == key then
            return t
        end
    end
    return nil
end

---Format comment for display
---@param type "note"|"fix"|"question"
---@param text string
---@param max_len number|nil Maximum text length
---@return string
function M.format(type, text, max_len)
    local type_info = M.get(type)
    if not type_info then
        return text
    end

    local display_text = text
    if max_len and #text > max_len then
        display_text = text:sub(1, max_len - 3) .. "..."
    end

    return string.format("[%s] %s", type_info.label, display_text)
end

---Get the label for a type
---@param type "note"|"fix"|"question"
---@return string
function M.get_label(type)
    local type_info = M.get(type)
    return type_info and type_info.label or "Unknown"
end

return M
