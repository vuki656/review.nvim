local git = require("review.core.git")

local M = {}

---Get the path to a file inside .git/
---@param filename string
---@return string|nil
function M.get_git_path(filename)
    local git_root = git.get_root()
    if not git_root then
        return nil
    end
    return git_root .. "/.git/" .. filename
end

---Read and decode a JSON file
---@param path string
---@return boolean ok
---@return table|nil data
function M.read_json_file(path)
    local file = io.open(path, "r")
    if not file then
        return true, nil
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return true, nil
    end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then
        return false, nil
    end

    return true, data
end

---Encode and write data to a JSON file
---@param path string
---@param data table
---@return boolean ok
function M.write_json_file(path, data)
    local encode_ok, json = pcall(vim.json.encode, data)
    if not encode_ok then
        return false
    end

    local file = io.open(path, "w")
    if not file then
        return false
    end

    file:write(json)
    file:close()
    return true
end

return M
