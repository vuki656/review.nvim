local M = {}

---Get relative path from cwd
---@param path string
---@return string
function M.get_relative_path(path)
    local cwd = vim.fn.getcwd()
    if path:sub(1, #cwd) == cwd then
        return path:sub(#cwd + 2)
    end
    return path
end

---Check if a filename is a test or spec file
---@param filename string
---@return boolean
function M.is_test_file(filename)
    local basename = vim.fn.fnamemodify(filename, ":t")
    if
        basename:match("^test[_.]")
        or basename:match("[_.]test%.")
        or basename:match("[_.]spec%.")
        or basename:match("^spec[_.]")
        or basename:match("_test%.")
        or basename:match("_spec%.")
    then
        return true
    end
    return false
end

---Get file extension for fenced code block language
---@param file string
---@return string
function M.get_code_fence_language(file)
    local extension = vim.fn.fnamemodify(file, ":e")
    local language_map = {
        ts = "typescript",
        js = "javascript",
        py = "python",
        rb = "ruby",
        rs = "rust",
        yml = "yaml",
        md = "markdown",
    }
    return language_map[extension] or extension
end

return M
