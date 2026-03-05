local M = {}

local LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
}

local LEVEL_NAMES = { "DEBUG", "INFO", "WARN", "ERROR" }

local current_level = LEVELS.INFO

local log_path = vim.fn.stdpath("log") .. "/review.log"

---@return string
function M.get_log_path()
    return log_path
end

---Configure the logger
---@param level string|nil Log level name (DEBUG, INFO, WARN, ERROR)
function M.setup(level)
    if level and LEVELS[level:upper()] then
        current_level = LEVELS[level:upper()]
    end
end

---Write a log entry at the given level
---@param level number
---@param ... any
local function write(level, ...)
    if level < current_level then
        return
    end

    local parts = {}
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        table.insert(parts, tostring(value))
    end
    local message = table.concat(parts, " ")

    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local level_name = LEVEL_NAMES[level] or "UNKNOWN"
    local line = string.format("[%s] [%s] %s\n", timestamp, level_name, message)

    local file = io.open(log_path, "a")
    if file then
        file:write(line)
        file:close()
    end
end

---@param ... any
function M.debug(...)
    write(LEVELS.DEBUG, ...)
end

---@param ... any
function M.info(...)
    write(LEVELS.INFO, ...)
end

---@param ... any
function M.warn(...)
    write(LEVELS.WARN, ...)
end

---@param ... any
function M.error(...)
    write(LEVELS.ERROR, ...)
end

return M
