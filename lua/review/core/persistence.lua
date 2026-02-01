local git = require("review.core.git")
local state = require("review.state")

local M = {}

local FILENAME = "review-session.json"

---Get the path to the persistence file
---@return string|nil
function M.get_path()
    local git_root = git.get_root()
    if not git_root then
        return nil
    end
    return git_root .. "/.git/" .. FILENAME
end

---Check if a saved session exists
---@return boolean
function M.exists()
    local path = M.get_path()
    if not path then
        return false
    end

    local file = io.open(path, "r")
    if not file then
        return false
    end
    file:close()
    return true
end

---Load session from disk into state
---@return boolean success
function M.load()
    local path = M.get_path()
    if not path then
        return false
    end

    local file = io.open(path, "r")
    if not file then
        return true
    end

    local content = file:read("*all")
    file:close()

    if not content or content == "" then
        return true
    end

    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" then
        vim.notify("Failed to parse review session file", vim.log.levels.WARN)
        return false
    end

    if data.version ~= 1 then
        vim.notify("Unsupported review session file version", vim.log.levels.WARN)
        return false
    end

    if data.files then
        for file_path, file_data in pairs(data.files) do
            local file_state = state.get_file_state(file_path)
            if file_data.comments then
                file_state.comments = file_data.comments
            end
        end
    end

    if data.base then
        state.state.base = data.base
    end

    if data.diff_mode then
        state.state.diff_mode = data.diff_mode
    end

    if data.comment_id_counter then
        state.state.comment_id_counter = data.comment_id_counter
    end

    return true
end

---Save session to disk
---@return boolean success
function M.save()
    local config = require("review.config").get()
    if not config.persistence.enabled then
        return true
    end

    local path = M.get_path()
    if not path then
        return false
    end

    local all_comments = state.get_all_comments()
    if #all_comments == 0 then
        os.remove(path)
        return true
    end

    local files_data = {}
    for file_path, file_state in pairs(state.state.files) do
        if #file_state.comments > 0 then
            local comments = {}
            for _, comment in ipairs(file_state.comments) do
                table.insert(comments, {
                    id = comment.id,
                    file = comment.file,
                    line = comment.line,
                    original_line = comment.original_line,
                    type = comment.type,
                    text = comment.text,
                    created_at = comment.created_at,
                })
            end
            files_data[file_path] = { comments = comments }
        end
    end

    local data = {
        version = 1,
        files = files_data,
        base = state.state.base,
        diff_mode = state.state.diff_mode,
        comment_id_counter = state.state.comment_id_counter,
    }

    local encode_ok, json = pcall(vim.json.encode, data)
    if not encode_ok then
        vim.notify("Failed to encode review session", vim.log.levels.ERROR)
        return false
    end

    local file = io.open(path, "w")
    if not file then
        vim.notify("Failed to write review session file", vim.log.levels.ERROR)
        return false
    end

    file:write(json)
    file:close()

    return true
end

---Delete the session file
---@return boolean success
function M.delete()
    local path = M.get_path()
    if not path then
        return false
    end
    os.remove(path)
    return true
end

---Set up autosave on VimLeavePre
function M.setup_autosave()
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("ReviewSessionPersist", { clear = true }),
        callback = function()
            if state.state.is_open then
                M.save()
            end
        end,
    })
end

return M
