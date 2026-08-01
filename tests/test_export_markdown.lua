local new_set = MiniTest.new_set
local expect = MiniTest.expect

local config = require("review.config")
local markdown = require("review.export.markdown")
local state = require("review.state")

local T = new_set({
    hooks = {
        pre_case = function()
            config.setup()
            state.reset()
        end,
    },
})

T["no comments returns no comments message"] = function()
    local result = markdown.generate()
    expect.equality(result:find("_No comments._") ~= nil, true)
end

T["single comment has correct markdown structure"] = function()
    state.add_comment("src/main.lua", 5, "note", "Looks good")
    local file_state = state.get_file_state("src/main.lua")
    file_state.render_lines = {
        { type = "context", content = "line 1" },
        { type = "context", content = "line 2" },
        { type = "context", content = "line 3" },
        { type = "context", content = "line 4" },
        { type = "add", content = "line 5" },
    }
    local result = markdown.generate()
    expect.equality(result:find("# Code Review Comments") ~= nil, true)
    expect.equality(result:find("## src/main.lua") ~= nil, true)
    expect.equality(result:find("%[NOTE%]") ~= nil, true)
    expect.equality(result:find("Looks good") ~= nil, true)
end

T["fix type shows FIX label"] = function()
    state.add_comment("test.lua", 1, "fix", "Fix this")
    state.get_file_state("test.lua").render_lines = { { type = "add", content = "x" } }
    local result = markdown.generate()
    expect.equality(result:find("%[FIX%]") ~= nil, true)
end

T["question type shows QUESTION label"] = function()
    state.add_comment("test.lua", 1, "question", "Why?")
    state.get_file_state("test.lua").render_lines = { { type = "add", content = "x" } }
    local result = markdown.generate()
    expect.equality(result:find("%[QUESTION%]") ~= nil, true)
end

T["files sorted alphabetically"] = function()
    state.add_comment("z_file.lua", 1, "note", "z comment")
    state.get_file_state("z_file.lua").render_lines = { { type = "add", content = "z" } }
    state.add_comment("a_file.lua", 1, "note", "a comment")
    state.get_file_state("a_file.lua").render_lines = { { type = "add", content = "a" } }
    local result = markdown.generate()
    local a_position = result:find("## a_file.lua")
    local z_position = result:find("## z_file.lua")
    expect.equality(a_position < z_position, true)
end

T["original_line used when present"] = function()
    state.add_comment("test.lua", 5, "note", "hello", 42)
    state.get_file_state("test.lua").render_lines = {
        { type = "context", content = "1" },
        { type = "context", content = "2" },
        { type = "context", content = "3" },
        { type = "context", content = "4" },
        { type = "add", content = "5" },
    }
    local result = markdown.generate()
    expect.equality(result:find("test.lua:42") ~= nil, true)
end

T["falls back to diff line when no original_line"] = function()
    state.add_comment("test.lua", 5, "note", "hello")
    state.get_file_state("test.lua").render_lines = {
        { type = "context", content = "1" },
        { type = "context", content = "2" },
        { type = "context", content = "3" },
        { type = "context", content = "4" },
        { type = "add", content = "5" },
    }
    local result = markdown.generate()
    expect.equality(result:find("test.lua:5") ~= nil, true)
end

T["language mapping for .ts files"] = function()
    state.add_comment("app.ts", 1, "note", "hello")
    local file_state = state.get_file_state("app.ts")
    file_state.render_lines = {
        { type = "context", content = "const x = 1" },
    }
    local result = markdown.generate()
    expect.equality(result:find("```typescript") ~= nil, true)
end

T["language mapping for .lua files"] = function()
    state.add_comment("init.lua", 1, "note", "hello")
    local file_state = state.get_file_state("init.lua")
    file_state.render_lines = {
        { type = "context", content = "local M = {}" },
    }
    local result = markdown.generate()
    expect.equality(result:find("```lua") ~= nil, true)
end

T["context lines from render_lines"] = function()
    state.add_comment("test.lua", 2, "note", "check this")
    local file_state = state.get_file_state("test.lua")
    file_state.render_lines = {
        { type = "context", content = "line one" },
        { type = "add", content = "line two" },
        { type = "context", content = "line three" },
    }
    local result = markdown.generate()
    expect.equality(result:find("%+line two") ~= nil, true)
end

T["range comment header shows start and end line"] = function()
    state.add_comment("src/api/client.ts", 1, "fix", "extract this", 42, "new", 5, 50)
    state.get_file_state("src/api/client.ts").render_lines = { { type = "add", content = "x" } }
    local result = markdown.generate()
    expect.equality(result:find("### %[FIX%] src/api/client%.ts:42%-50") ~= nil, true)
end

T["single line comment header has no range"] = function()
    state.add_comment("src/api/client.ts", 1, "fix", "single", 42, "new")
    state.get_file_state("src/api/client.ts").render_lines = { { type = "add", content = "x" } }
    local result = markdown.generate()
    expect.equality(result:find("### %[FIX%] src/api/client%.ts:42") ~= nil, true)
    expect.equality(result:find("client%.ts:42%-"), nil)
end

T["range comment context spans the whole range"] = function()
    config.setup({ export = { context_lines = 0 } })
    state.add_comment("test.lua", 2, "note", "range context", 2, "new", 4, 4)
    state.get_file_state("test.lua").render_lines = {
        { type = "context", content = "line one" },
        { type = "add", content = "line two" },
        { type = "add", content = "line three" },
        { type = "add", content = "line four" },
        { type = "context", content = "line five" },
    }
    local result = markdown.generate()
    expect.equality(result:find("%+line two") ~= nil, true)
    expect.equality(result:find("%+line three") ~= nil, true)
    expect.equality(result:find("%+line four") ~= nil, true)
    expect.equality(result:find("line five") == nil, true)
end

T["to_clipboard sets both registers"] = function()
    state.add_comment("test.lua", 1, "note", "clipboard test")
    state.get_file_state("test.lua").render_lines = { { type = "add", content = "x" } }
    markdown.to_clipboard()
    local plus_content = vim.fn.getreg("+")
    local star_content = vim.fn.getreg("*")
    expect.equality(plus_content:find("clipboard test") ~= nil, true)
    expect.equality(star_content:find("clipboard test") ~= nil, true)
end

T["send calls on_export with content and comments"] = function()
    local captured = {}
    config.setup({
        export = {
            on_export = function(content, comments)
                captured.content = content
                captured.comments = comments
            end,
        },
    })
    state.add_comment("test.lua", 1, "note", "handler test")
    state.get_file_state("test.lua").render_lines = { { type = "add", content = "x" } }

    local success = markdown.send()

    expect.equality(success, true)
    expect.equality(captured.content:find("handler test") ~= nil, true)
    expect.equality(#captured.comments, 1)
end

T["send reports failure when on_export returns false"] = function()
    config.setup({
        export = {
            on_export = function()
                return false
            end,
        },
    })
    state.add_comment("test.lua", 1, "note", "failed handoff")
    state.get_file_state("test.lua").render_lines = { { type = "add", content = "x" } }

    expect.equality(markdown.send(nil, true), false)
end

T["send reports failure when on_export errors"] = function()
    config.setup({
        export = {
            on_export = function()
                error("boom")
            end,
        },
    })
    state.add_comment("test.lua", 1, "note", "erroring handoff")
    state.get_file_state("test.lua").render_lines = { { type = "add", content = "x" } }

    expect.equality(markdown.send(nil, true), false)
end

T["send skips the callback when there are no comments"] = function()
    local called = false
    config.setup({
        export = {
            on_export = function()
                called = true
            end,
        },
    })

    expect.equality(markdown.send(nil, true), false)
    expect.equality(called, false)
end

T["to_clipboard also runs on_export"] = function()
    local called = false
    config.setup({
        export = {
            on_export = function()
                called = true
            end,
        },
    })
    state.add_comment("test.lua", 1, "note", "clipboard handler")
    state.get_file_state("test.lua").render_lines = { { type = "add", content = "x" } }

    markdown.to_clipboard()

    expect.equality(called, true)
end

T["has_handler is false by default"] = function()
    expect.equality(markdown.has_handler(), false)
end

T["context boundary handling at start of render_lines"] = function()
    config.setup({ export = { context_lines = 3 } })
    state.add_comment("test.lua", 1, "note", "first line comment")
    local file_state = state.get_file_state("test.lua")
    file_state.render_lines = {
        { type = "add", content = "only line" },
    }
    local result = markdown.generate()
    expect.equality(result:find("%+only line") ~= nil, true)
end

return T
