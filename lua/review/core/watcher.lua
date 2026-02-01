local M = {}

---@type uv_fs_event_t|nil
local fs_event = nil

---@type uv_timer_t|nil
local debounce_timer = nil

---Start watching a directory for file changes
---@param git_root string Path to watch
---@param callback fun() Called when changes are detected (debounced)
function M.start(git_root, callback)
    M.stop()

    local config = require("review.config").get()
    if not config.auto_refresh.enabled then
        return
    end

    local debounce_ms = config.auto_refresh.debounce_ms

    fs_event = vim.uv.new_fs_event()
    debounce_timer = vim.uv.new_timer()

    fs_event:start(git_root, { recursive = true }, function(error, filename)
        if error then
            return
        end

        if filename and filename:match("^%.git/") then
            return
        end

        debounce_timer:stop()
        debounce_timer:start(debounce_ms, 0, function()
            vim.schedule(callback)
        end)
    end)
end

---Stop watching for file changes
function M.stop()
    if debounce_timer then
        debounce_timer:stop()
        debounce_timer:close()
        debounce_timer = nil
    end

    if fs_event then
        fs_event:stop()
        fs_event:close()
        fs_event = nil
    end
end

return M
