local json_persistence = require("review.core.json_persistence")
local log = require("review.core.log")
local state = require("review.state")

local M = {}

local FILENAME = "review-session.json"

local loaded_path = nil
local unreadable_path = nil
local loaded_mtime = nil

---Modification time of a file, or nil when it does not exist
---@param path string
---@return number|nil
local function mtime_of(path)
    local stat = vim.uv.fs_stat(path)
    return stat and stat.mtime and stat.mtime.sec
end

---Whether the file changed on disk since we loaded it
---@param path string
---@return boolean
local function changed_since_load(path)
    return mtime_of(path) ~= loaded_mtime
end

---Get the path to the persistence file
---@return string|nil
function M.get_path()
    return json_persistence.get_git_path(FILENAME)
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

    local ok, data = json_persistence.read_json_file(path)
    if not ok then
        unreadable_path = path
        vim.notify("Failed to parse review session file, leaving it untouched", vim.log.levels.WARN)
        log.warn("persistence: parse failed, will not overwrite or delete", path)
        return false
    end

    if data and data.version ~= 1 then
        unreadable_path = path
        vim.notify("Unsupported review session file version, leaving it untouched", vim.log.levels.WARN)
        log.warn("persistence: version", tostring(data.version), "unsupported, will not overwrite or delete", path)
        return false
    end

    loaded_path = path
    unreadable_path = nil
    loaded_mtime = mtime_of(path)

    if not data then
        return true
    end

    if data.files then
        for file_path, file_data in pairs(data.files) do
            local file_state = state.get_file_state(file_path)
            if file_data.comments then
                file_state.comments = file_data.comments
            end
        end
    end

    local git = require("review.core.git")
    if data.base and not state.is_history_mode() then
        if git.is_safe_rev(data.base) and git.is_safe_rev(data.base_end) then
            state.state.base = data.base
            state.state.base_end = data.base_end
        else
            log.warn("persistence: ignoring unsafe base in session file", tostring(data.base))
        end
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
---@param opts? table|boolean Options table (e.g. { force_empty = true }) or boolean force_empty flag
---@return boolean success
function M.save(opts)
    local force_empty = false
    if type(opts) == "table" then
        force_empty = opts.force_empty == true
    elseif type(opts) == "boolean" then
        force_empty = opts
    end

    local config = require("review.config").get()
    if not config.persistence.enabled then
        return true
    end

    local path = M.get_path()
    if not path then
        return false
    end

    if loaded_path and loaded_path ~= path then
        log.warn("persistence: refusing to save into", path, "loaded from", loaded_path)
        return false
    end

    if unreadable_path == path then
        log.warn("persistence: refusing to overwrite", path, "-- it exists but could not be read")
        return false
    end

    local conflicted = changed_since_load(path)

    local all_comments = state.get_all_comments()
    if #all_comments == 0 then
        if conflicted and not force_empty then
            log.warn("persistence: another session wrote", path, "-- leaving it in place")
            return true
        end
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
                    end_line = comment.end_line,
                    original_line = comment.original_line,
                    original_end_line = comment.original_end_line,
                    side = comment.side,
                    type = comment.type,
                    text = comment.text,
                    created_at = comment.created_at,
                })
            end
            files_data[file_path] = { comments = comments }
        end
    end

    if conflicted then
        local ok, disk = json_persistence.read_json_file(path)
        if ok and disk and disk.version == 1 and disk.files then
            local merged = 0
            for file_path, file_data in pairs(disk.files) do
                local target = files_data[file_path] or { comments = {} }
                local seen = {}
                for _, comment in ipairs(target.comments) do
                    seen[comment.id] = true
                end
                for _, comment in ipairs(file_data.comments or {}) do
                    if not seen[comment.id] then
                        table.insert(target.comments, comment)
                        merged = merged + 1
                    end
                end
                files_data[file_path] = target
            end
            if merged > 0 then
                log.warn("persistence: merged", merged, "comment(s) written by another session")
                vim.notify(
                    string.format("Merged %d comment(s) saved by another Neovim session", merged),
                    vim.log.levels.WARN
                )
            end
        end
    end

    local data = {
        version = 1,
        files = files_data,
        base = state.state.base,
        base_end = state.state.base_end,
        diff_mode = state.state.diff_mode,
        comment_id_counter = state.state.comment_id_counter,
    }

    if not json_persistence.write_json_file(path, data) then
        vim.notify("Failed to write review session file", vim.log.levels.ERROR)
        log.error("persistence: write failed", path)
        return false
    end

    loaded_mtime = mtime_of(path)
    log.info("persistence: saved", #all_comments, "comment(s) to", path)
    return true
end

---Delete the session file
---@return boolean success
function M.delete()
    local path = M.get_path()
    if not path then
        return false
    end

    if unreadable_path == path then
        log.warn("persistence: refusing to delete", path, "-- it exists but could not be read")
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
