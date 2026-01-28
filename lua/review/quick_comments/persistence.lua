local git = require("review.core.git")
local qc_state = require("review.quick_comments.state")

local M = {}

local FILENAME = "review-comments.json"

---Get the path to the persistence file
---@return string|nil
function M.get_path()
    local git_root = git.get_root()
    if not git_root then
        return nil
    end
    return git_root .. "/.git/" .. FILENAME
end

---Load comments from disk
---@return boolean success
function M.load()
    local path = M.get_path()
    if not path then
        return false
    end

    local file = io.open(path, "r")
    if not file then
        -- No saved comments yet, that's fine
        return true
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return true
    end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then
        vim.notify("Failed to parse quick comments file", vim.log.levels.WARN)
        return false
    end

    -- Check version
    if data.version ~= 1 then
        vim.notify("Unsupported quick comments file version", vim.log.levels.WARN)
        return false
    end

    -- Load into state
    qc_state.load({
        comments = data.comments or {},
        comment_id_counter = data.comment_id_counter or 0,
    })

    return true
end

---Save comments to disk
---@return boolean success
function M.save()
    local path = M.get_path()
    if not path then
        return false
    end

    local state_data = qc_state.export()

    -- Don't save empty state
    if qc_state.count() == 0 then
        -- Remove file if it exists and there are no comments
        os.remove(path)
        return true
    end

    local data = {
        version = 1,
        comments = state_data.comments,
        comment_id_counter = state_data.comment_id_counter,
    }

    local ok, json = pcall(vim.json.encode, data)
    if not ok then
        vim.notify("Failed to encode quick comments", vim.log.levels.ERROR)
        return false
    end

    local file = io.open(path, "w")
    if not file then
        vim.notify("Failed to write quick comments file", vim.log.levels.ERROR)
        return false
    end

    file:write(json)
    file:close()

    return true
end

---Set up autosave on VimLeavePre
function M.setup_autosave()
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("ReviewQuickCommentsPersist", { clear = true }),
        callback = function()
            M.save()
        end,
    })
end

return M
