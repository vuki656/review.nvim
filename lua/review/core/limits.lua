local M = {}

M.MAX_DIFF_BYTES = 1024 * 1024

M.MAX_SOURCE_BYTES = 256 * 1024

M.BINARY_PROBE_BYTES = 8192

---Whether a byte count is over a limit
---@param size number|nil
---@param limit number
---@return boolean
function M.is_too_large(size, limit)
    return type(size) == "number" and size > limit
end

---Whether a leading chunk of a file looks binary.
---Matches git: a NUL byte in the first bytes of the file means binary.
---@param chunk string|nil
---@return boolean
function M.is_binary_chunk(chunk)
    if type(chunk) ~= "string" or chunk == "" then
        return false
    end
    return chunk:find("\0", 1, true) ~= nil
end

return M
