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
        return words[1]:sub(1, 2):upper()
    end

    return (words[1]:sub(1, 1) .. words[2]:sub(1, 1)):upper()
end

return M
