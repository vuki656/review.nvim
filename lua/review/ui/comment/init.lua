local input = require("review.ui.comment.input")
local markers = require("review.ui.comment.markers")
local types = require("review.ui.comment.types")

local M = {}

-- Re-export submodules
M.input = input
M.markers = markers
M.types = types

---Open comment input at current position
---@param file string
---@param line number
---@param original_line number|nil
---@param on_complete function|nil
function M.add(file, line, original_line, on_complete)
    input.open(file, line, original_line, on_complete)
end

---Render comments for a file
---@param bufnr number
---@param file string
function M.render(bufnr, file)
    markers.render(bufnr, file)
end

---Clear comment markers
---@param bufnr number
function M.clear(bufnr)
    markers.clear(bufnr)
end

---Close any open comment inputs
function M.close()
    input.close()
end

return M
