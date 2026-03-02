local comment_types_module = require("review.comment_types")

local comment_types = comment_types_module.TYPES

local M = {}

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

---Build markdown content from quick comments
---@param comments QuickComment[]
---@return string
function M.build(comments)
    local lines = { "# Quick Comments" }
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

    return table.concat(lines, "\n")
end

return M
