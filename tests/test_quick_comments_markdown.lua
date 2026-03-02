local new_set = MiniTest.new_set
local expect = MiniTest.expect

local qc_markdown = require("review.quick_comments.markdown")

local T = new_set()

T["empty list returns header only"] = function()
    local result = qc_markdown.build({})
    expect.equality(result, "# Quick Comments")
end

T["single comment has correct structure"] = function()
    local comments = {
        {
            id = "qc_1_1",
            file = vim.fn.getcwd() .. "/src/main.lua",
            line = 10,
            type = "note",
            text = "Looks good",
            created_at = 1000000,
            context = nil,
        },
    }
    local result = qc_markdown.build(comments)
    expect.equality(result:find("## src/main.lua") ~= nil, true)
    expect.equality(result:find("Line 10") ~= nil, true)
    expect.equality(result:find("Note") ~= nil, true)
    expect.equality(result:find("Looks good") ~= nil, true)
end

T["context code block present when context exists"] = function()
    local comments = {
        {
            id = "qc_1_1",
            file = vim.fn.getcwd() .. "/test.lua",
            line = 5,
            type = "fix",
            text = "Fix this",
            created_at = 1000000,
            context = "local x = 1",
        },
    }
    local result = qc_markdown.build(comments)
    expect.equality(result:find("```") ~= nil, true)
    expect.equality(result:find("local x = 1") ~= nil, true)
end

T["no code block when context is nil"] = function()
    local comments = {
        {
            id = "qc_1_1",
            file = vim.fn.getcwd() .. "/test.lua",
            line = 5,
            type = "fix",
            text = "Fix this",
            created_at = 1000000,
            context = nil,
        },
    }
    local result = qc_markdown.build(comments)
    expect.equality(result:find("```"), nil)
end

T["multiple comments same file get one header"] = function()
    local base_path = vim.fn.getcwd() .. "/test.lua"
    local comments = {
        {
            id = "qc_1_1",
            file = base_path,
            line = 5,
            type = "note",
            text = "First",
            created_at = 1000000,
            context = nil,
        },
        {
            id = "qc_1_2",
            file = base_path,
            line = 10,
            type = "fix",
            text = "Second",
            created_at = 1000001,
            context = nil,
        },
    }
    local result = qc_markdown.build(comments)
    local _, count = result:gsub("## test.lua", "")
    expect.equality(count, 1)
end

T["multiple files get separate headers"] = function()
    local cwd = vim.fn.getcwd()
    local comments = {
        {
            id = "qc_1_1",
            file = cwd .. "/a.lua",
            line = 1,
            type = "note",
            text = "In A",
            created_at = 1000000,
            context = nil,
        },
        {
            id = "qc_1_2",
            file = cwd .. "/b.lua",
            line = 1,
            type = "note",
            text = "In B",
            created_at = 1000001,
            context = nil,
        },
    }
    local result = qc_markdown.build(comments)
    expect.equality(result:find("## a.lua") ~= nil, true)
    expect.equality(result:find("## b.lua") ~= nil, true)
end

return T
