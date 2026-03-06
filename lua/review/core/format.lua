local M = {}

---Shorten a git relative date string (e.g. "3 hours ago" -> "3h")
---@param date string
---@return string
function M.shorten_date(date)
    local number, unit = date:match("^(%d+) (%a+) ago$")
    if not number then
        return date
    end

    local short_units = {
        second = "s",
        seconds = "s",
        minute = "m",
        minutes = "m",
        hour = "h",
        hours = "h",
        day = "d",
        days = "d",
        week = "w",
        weeks = "w",
        month = "mo",
        months = "mo",
        year = "y",
        years = "y",
    }

    local short = short_units[unit]
    if short then
        return number .. short
    end

    return date
end

---Get the first N UTF-8 characters from a string
---@param str string
---@param count number
---@return string
local function utf8_sub(str, count)
    return vim.fn.strcharpart(str, 0, count)
end

---Extract author initials from a name (e.g. "John Doe" -> "JD", "vuki" -> "VU")
---@param author string|nil
---@return string
function M.author_initials(author)
    if not author or author == "" then
        return ""
    end

    local words = {}
    for word in author:gmatch("%S+") do
        table.insert(words, word)
    end

    if #words == 0 then
        return ""
    end

    if #words == 1 then
        return vim.fn.toupper(utf8_sub(words[1], 2))
    end

    return vim.fn.toupper(utf8_sub(words[1], 1) .. utf8_sub(words[2], 1))
end

return M
