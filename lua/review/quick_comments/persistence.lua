local json_persistence = require("review.core.json_persistence")
local qc_state = require("review.quick_comments.state")

local M = {}

local FILENAME = "review-comments.json"

---Get the path to the persistence file
---@return string|nil
function M.get_path()
    return json_persistence.get_git_path(FILENAME)
end

---Load comments from disk
---@return boolean success
function M.load()
    local path = M.get_path()
    if not path then
        return false
    end

    local ok, data = json_persistence.read_json_file(path)
    if not ok then
        vim.notify("Failed to parse quick comments file", vim.log.levels.WARN)
        return false
    end

    if not data then
        return true
    end

    if data.version ~= 1 then
        vim.notify("Unsupported quick comments file version", vim.log.levels.WARN)
        return false
    end

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

    if qc_state.count() == 0 then
        os.remove(path)
        return true
    end

    local data = {
        version = 1,
        comments = state_data.comments,
        comment_id_counter = state_data.comment_id_counter,
    }

    if not json_persistence.write_json_file(path, data) then
        vim.notify("Failed to write quick comments file", vim.log.levels.ERROR)
        return false
    end

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
