local log = require("review.core.log")

local M = {}

local MAX_WATCHED_DIRS = 2000

local IGNORED_DIRS = {
    [".git"] = true,
    ["node_modules"] = true,
    ["target"] = true,
    ["dist"] = true,
    ["build"] = true,
    [".venv"] = true,
    ["vendor"] = true,
}

---@type uv.uv_fs_event_t[]
local fs_events = {}

---@type uv.uv_timer_t|nil
local debounce_timer = nil

---Whether libuv can watch a whole tree with one recursive handle on this platform
---@return boolean
local function supports_recursive()
    local sysname = vim.uv.os_uname().sysname
    return sysname == "Darwin" or sysname == "Windows_NT"
end

---Whether a path reported by a recursive watcher lives inside an ignored directory
---@param filename string|nil
---@return boolean
local function is_ignored_path(filename)
    if not filename then
        return false
    end
    for segment in string.gmatch(filename, "[^/\\]+") do
        if IGNORED_DIRS[segment] then
            return true
        end
    end
    return false
end

M.is_ignored_path = is_ignored_path

---Collect directories to watch, skipping ignored trees
---@param root string
---@return string[]
local function collect_directories(root)
    local dirs = { root }
    local queue = { root }
    local truncated = false

    while #queue > 0 and not truncated do
        local current = table.remove(queue)
        local ok, iterator = pcall(vim.fs.dir, current)
        if ok then
            for name, kind in iterator do
                if kind == "directory" and not IGNORED_DIRS[name] then
                    if #dirs >= MAX_WATCHED_DIRS then
                        truncated = true
                        break
                    end
                    local path = vim.fs.joinpath(current, name)
                    table.insert(dirs, path)
                    table.insert(queue, path)
                end
            end
        end
    end

    if truncated then
        log.warn("watcher: hit the", MAX_WATCHED_DIRS, "directory limit, some changes will not auto-refresh")
    end

    return dirs
end

---Start watching a repository for file changes
---@param git_root string Path to watch
---@param callback fun() Called when changes are detected (debounced)
function M.start(git_root, callback)
    M.stop()

    local config = require("review.config").get()
    if not config.auto_refresh.enabled then
        log.debug("watcher: disabled by config")
        return
    end

    local debounce_ms = config.auto_refresh.debounce_ms
    debounce_timer = vim.uv.new_timer()

    local function on_change(error, filename)
        if error or not debounce_timer or is_ignored_path(filename) then
            return
        end
        debounce_timer:stop()
        debounce_timer:start(debounce_ms, 0, function()
            vim.schedule(callback)
        end)
    end

    local function watch(path, opts)
        local handle = vim.uv.new_fs_event()
        if not handle then
            return false
        end
        local ok = pcall(function()
            handle:start(path, opts, on_change)
        end)
        if ok then
            table.insert(fs_events, handle)
        else
            handle:close()
        end
        return ok
    end

    if supports_recursive() and watch(git_root, { recursive = true }) then
        log.info("watcher: watching", git_root, "recursively debounce=", debounce_ms)
        return
    end

    for _, dir in ipairs(collect_directories(git_root)) do
        watch(dir, {})
    end

    log.info("watcher: watching", #fs_events, "directories debounce=", debounce_ms)
end

---Stop watching for file changes
function M.stop()
    if debounce_timer then
        debounce_timer:stop()
        debounce_timer:close()
        debounce_timer = nil
    end

    for _, handle in ipairs(fs_events) do
        handle:stop()
        handle:close()
    end
    fs_events = {}
end

return M
