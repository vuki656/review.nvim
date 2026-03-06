local new_set = MiniTest.new_set
local expect = MiniTest.expect

local format = require("review.core.format")

local T = new_set()

T["shorten_date"] = new_set()

T["shorten_date"]["shortens seconds"] = function()
    expect.equality(format.shorten_date("5 seconds ago"), "5s")
end

T["shorten_date"]["shortens singular second"] = function()
    expect.equality(format.shorten_date("1 second ago"), "1s")
end

T["shorten_date"]["shortens minutes"] = function()
    expect.equality(format.shorten_date("30 minutes ago"), "30m")
end

T["shorten_date"]["shortens hours"] = function()
    expect.equality(format.shorten_date("3 hours ago"), "3h")
end

T["shorten_date"]["shortens days"] = function()
    expect.equality(format.shorten_date("7 days ago"), "7d")
end

T["shorten_date"]["shortens weeks"] = function()
    expect.equality(format.shorten_date("2 weeks ago"), "2w")
end

T["shorten_date"]["shortens months"] = function()
    expect.equality(format.shorten_date("6 months ago"), "6mo")
end

T["shorten_date"]["shortens years"] = function()
    expect.equality(format.shorten_date("1 year ago"), "1y")
end

T["shorten_date"]["returns non-matching dates unchanged"] = function()
    expect.equality(format.shorten_date("just now"), "just now")
end

T["shorten_date"]["returns unknown unit unchanged"] = function()
    expect.equality(format.shorten_date("3 fortnights ago"), "3 fortnights ago")
end

T["author_initials"] = new_set()

T["author_initials"]["two-word name returns initials"] = function()
    expect.equality(format.author_initials("John Doe"), "JD")
end

T["author_initials"]["single-word name returns first two chars uppercased"] = function()
    expect.equality(format.author_initials("vuki"), "VU")
end

T["author_initials"]["three-word name uses first two words"] = function()
    expect.equality(format.author_initials("John Michael Doe"), "JM")
end

T["author_initials"]["nil returns empty string"] = function()
    expect.equality(format.author_initials(nil), "")
end

T["author_initials"]["empty string returns empty string"] = function()
    expect.equality(format.author_initials(""), "")
end

T["author_initials"]["lowercase name uppercases initials"] = function()
    expect.equality(format.author_initials("alice bob"), "AB")
end

return T
