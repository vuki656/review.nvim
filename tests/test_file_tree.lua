local new_set = MiniTest.new_set
local expect = MiniTest.expect

local file_tree = require("review.ui.file_tree")

local T = new_set()

local format = new_set()
T["format_line_stats"] = format

format["renders counts after the filename"] = function()
    local text, added_len = file_tree._format_line_stats({ added = 12, deleted = 3 })
    expect.equality(text, " +12 −3")
    expect.equality(added_len, #" +12")
end

format["added length is a byte offset usable as a highlight column"] = function()
    local text, added_len = file_tree._format_line_stats({ added = 0, deleted = 40 })
    expect.equality(text:sub(1, added_len), " +0")
    expect.equality(text:sub(added_len + 1), " −40")
end

format["binary stats render nothing"] = function()
    local text, added_len = file_tree._format_line_stats({ added = nil, deleted = nil })
    expect.equality(text, "")
    expect.equality(added_len, 0)
end

format["missing stats render nothing"] = function()
    local text, added_len = file_tree._format_line_stats(nil)
    expect.equality(text, "")
    expect.equality(added_len, 0)
end

local sum = new_set()
T["sum_line_stats"] = sum

sum["adds up the listed files"] = function()
    local totals = file_tree._sum_line_stats({ "a.lua", "b.lua" }, {
        ["a.lua"] = { added = 3, deleted = 1 },
        ["b.lua"] = { added = 4, deleted = 0 },
    })
    expect.equality(totals, { added = 7, deleted = 1 })
end

sum["ignores files that are not listed"] = function()
    local totals = file_tree._sum_line_stats({ "a.lua" }, {
        ["a.lua"] = { added = 3, deleted = 1 },
        ["stale.lua"] = { added = 100, deleted = 100 },
    })
    expect.equality(totals, { added = 3, deleted = 1 })
end

sum["binary files contribute nothing but do not block totals"] = function()
    local totals = file_tree._sum_line_stats({ "a.lua", "logo.png" }, {
        ["a.lua"] = { added = 3, deleted = 1 },
        ["logo.png"] = { added = nil, deleted = nil },
    })
    expect.equality(totals, { added = 3, deleted = 1 })
end

sum["nil when stats are disabled"] = function()
    expect.equality(file_tree._sum_line_stats({ "a.lua" }, nil), nil)
end

sum["nil when no listed file has stats"] = function()
    expect.equality(file_tree._sum_line_stats({ "a.lua" }, {}), nil)
end

sum["nil when there are no files"] = function()
    expect.equality(file_tree._sum_line_stats({}, { ["a.lua"] = { added = 1, deleted = 0 } }), nil)
end

sum["nil for the async.all failure sentinel"] = function()
    expect.equality(file_tree._sum_line_stats({ "a.lua" }, { code = -1, stdout = "", stderr = "boom" }), nil)
end

return T
