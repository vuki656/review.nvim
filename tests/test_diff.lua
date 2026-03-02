local new_set = MiniTest.new_set
local expect = MiniTest.expect
local helpers = require("tests.helpers")

local diff = require("review.core.diff")

local T = new_set()

local parse = new_set()
T["parse"] = parse

parse["empty string returns empty result"] = function()
    local result = diff.parse("")
    expect.equality(result.file_old, nil)
    expect.equality(result.file_new, nil)
    expect.equality(result.hunks, {})
end

parse["nil returns empty result"] = function()
    local result = diff.parse(nil)
    expect.equality(result.hunks, {})
end

parse["parses file headers with a/b prefix"] = function()
    local result = diff.parse(helpers.SIMPLE_DIFF)
    expect.equality(result.file_old, "file.lua")
    expect.equality(result.file_new, "file.lua")
end

parse["parses file headers without a/b prefix (dev/null)"] = function()
    local result = diff.parse(helpers.ADD_ONLY_DIFF)
    expect.equality(result.file_old, "/dev/null")
    expect.equality(result.file_new, "new_file.lua")
end

parse["parses hunk header with counts"] = function()
    local result = diff.parse(helpers.SIMPLE_DIFF)
    local hunk = result.hunks[1]
    expect.equality(hunk.old_start, 1)
    expect.equality(hunk.old_count, 3)
    expect.equality(hunk.new_start, 1)
    expect.equality(hunk.new_count, 4)
end

parse["parses hunk header without counts"] = function()
    local result = diff.parse(helpers.NO_COUNT_HEADER_DIFF)
    local hunk = result.hunks[1]
    expect.equality(hunk.old_start, 5)
    expect.equality(hunk.old_count, 1)
    expect.equality(hunk.new_start, 5)
    expect.equality(hunk.new_count, 1)
end

parse["identifies add lines"] = function()
    local result = diff.parse(helpers.ADD_ONLY_DIFF)
    for _, line in ipairs(result.hunks[1].lines) do
        expect.equality(line.type, "add")
    end
end

parse["identifies delete lines"] = function()
    local result = diff.parse(helpers.DELETE_ONLY_DIFF)
    for _, line in ipairs(result.hunks[1].lines) do
        expect.equality(line.type, "delete")
    end
end

parse["identifies context lines"] = function()
    local result = diff.parse(helpers.SIMPLE_DIFF)
    local first_line = result.hunks[1].lines[1]
    expect.equality(first_line.type, "context")
end

parse["strips prefix from content"] = function()
    local result = diff.parse(helpers.SIMPLE_DIFF)
    local lines = result.hunks[1].lines
    expect.equality(lines[1].content, "local M = {}")
    expect.equality(lines[2].content, "local old = true")
    expect.equality(lines[3].content, "local new = true")
end

parse["preserves raw line"] = function()
    local result = diff.parse(helpers.SIMPLE_DIFF)
    local lines = result.hunks[1].lines
    expect.equality(lines[1].raw, " local M = {}")
    expect.equality(lines[2].raw, "-local old = true")
    expect.equality(lines[3].raw, "+local new = true")
end

parse["assigns correct old_line numbers"] = function()
    local result = diff.parse(helpers.SIMPLE_DIFF)
    local lines = result.hunks[1].lines
    expect.equality(lines[1].old_line, 1)
    expect.equality(lines[2].old_line, 2)
    expect.equality(lines[3].old_line, nil)
    expect.equality(lines[4].old_line, nil)
    expect.equality(lines[5].old_line, 3)
end

parse["assigns correct new_line numbers"] = function()
    local result = diff.parse(helpers.SIMPLE_DIFF)
    local lines = result.hunks[1].lines
    expect.equality(lines[1].new_line, 1)
    expect.equality(lines[2].new_line, nil)
    expect.equality(lines[3].new_line, 2)
    expect.equality(lines[4].new_line, 3)
    expect.equality(lines[5].new_line, 4)
end

parse["parses multiple hunks"] = function()
    local result = diff.parse(helpers.MULTI_HUNK_DIFF)
    expect.equality(#result.hunks, 2)
    expect.equality(result.hunks[1].old_start, 1)
    expect.equality(result.hunks[2].old_start, 10)
end

parse["headers only with no hunks returns empty hunks"] = function()
    local input = table.concat({
        "diff --git a/file.lua b/file.lua",
        "index abc..def 100644",
        "--- a/file.lua",
        "+++ b/file.lua",
    }, "\n")
    local result = diff.parse(input)
    expect.equality(result.file_old, "file.lua")
    expect.equality(result.file_new, "file.lua")
    expect.equality(result.hunks, {})
end

parse["lines before first hunk are ignored"] = function()
    local input = table.concat({
        "diff --git a/file.lua b/file.lua",
        "index abc..def 100644",
        "some random line",
        "--- a/file.lua",
        "+++ b/file.lua",
        "@@ -1,1 +1,1 @@",
        "-old",
        "+new",
    }, "\n")
    local result = diff.parse(input)
    expect.equality(#result.hunks, 1)
    expect.equality(#result.hunks[1].lines, 2)
end

local get_render_lines = new_set()
T["get_render_lines"] = get_render_lines

get_render_lines["empty hunks returns empty list"] = function()
    local result = diff.get_render_lines({ hunks = {} })
    expect.equality(result, {})
end

get_render_lines["inserts header line before hunk lines"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local lines = diff.get_render_lines(parsed)
    expect.equality(lines[1].type, "header")
    expect.equality(lines[1].content, parsed.hunks[1].header)
end

get_render_lines["total line count matches hunks plus headers"] = function()
    local parsed = diff.parse(helpers.MULTI_HUNK_DIFF)
    local lines = diff.get_render_lines(parsed)
    local expected_count = 0
    for _, hunk in ipairs(parsed.hunks) do
        expected_count = expected_count + 1 + #hunk.lines
    end
    expect.equality(#lines, expected_count)
end

get_render_lines["header lines have nil line numbers"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local lines = diff.get_render_lines(parsed)
    expect.equality(lines[1].old_line, nil)
    expect.equality(lines[1].new_line, nil)
end

local get_split = new_set()
T["get_split_render_lines"] = get_split

get_split["filepath lines at top of both sides"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local old_lines, new_lines = diff.get_split_render_lines(parsed)
    expect.equality(old_lines[1].type, "filepath")
    expect.equality(new_lines[1].type, "filepath")
    expect.equality(old_lines[1].content, "file.lua")
end

get_split["context lines appear on both sides"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local old_lines, new_lines = diff.get_split_render_lines(parsed)
    local found_context = false
    for index = 3, #old_lines do
        if old_lines[index].type == "context" then
            expect.equality(new_lines[index].type, "context")
            expect.equality(old_lines[index].content, new_lines[index].content)
            found_context = true
            break
        end
    end
    expect.equality(found_context, true)
end

get_split["paired delete and add have pair_content"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local old_lines, new_lines = diff.get_split_render_lines(parsed)
    local found_pair = false
    for index = 3, #old_lines do
        if old_lines[index].type == "delete" and old_lines[index].pair_content then
            expect.equality(new_lines[index].type, "add")
            expect.no_equality(new_lines[index].pair_content, nil)
            found_pair = true
            break
        end
    end
    expect.equality(found_pair, true)
end

get_split["unmatched delete gets padding on new side"] = function()
    local parsed = diff.parse(helpers.DELETE_ONLY_DIFF)
    local old_lines, new_lines = diff.get_split_render_lines(parsed)
    local found_padding = false
    for index = 3, #old_lines do
        if old_lines[index].type == "delete" then
            expect.equality(new_lines[index].type, "padding")
            found_padding = true
            break
        end
    end
    expect.equality(found_padding, true)
end

get_split["unmatched add gets padding on old side"] = function()
    local parsed = diff.parse(helpers.ADD_ONLY_DIFF)
    local old_lines, new_lines = diff.get_split_render_lines(parsed)
    local found_padding = false
    for index = 3, #new_lines do
        if new_lines[index].type == "add" then
            expect.equality(old_lines[index].type, "padding")
            found_padding = true
            break
        end
    end
    expect.equality(found_padding, true)
end

get_split["old_lines and new_lines always same length"] = function()
    local diffs = {
        helpers.SIMPLE_DIFF,
        helpers.MULTI_HUNK_DIFF,
        helpers.ADD_ONLY_DIFF,
        helpers.DELETE_ONLY_DIFF,
        helpers.MIXED_DIFF,
    }
    for _, diff_text in ipairs(diffs) do
        local parsed = diff.parse(diff_text)
        local old_lines, new_lines = diff.get_split_render_lines(parsed)
        expect.equality(#old_lines, #new_lines)
    end
end

local get_source_line = new_set()
T["get_source_line"] = get_source_line

get_source_line["add line returns new_line and new"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local lines = diff.get_render_lines(parsed)
    for index, line in ipairs(lines) do
        if line.type == "add" then
            local source, side = diff.get_source_line(index, lines)
            expect.equality(source, line.new_line)
            expect.equality(side, "new")
            break
        end
    end
end

get_source_line["delete line returns old_line and old"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local lines = diff.get_render_lines(parsed)
    for index, line in ipairs(lines) do
        if line.type == "delete" then
            local source, side = diff.get_source_line(index, lines)
            expect.equality(source, line.old_line)
            expect.equality(side, "old")
            break
        end
    end
end

get_source_line["context line returns new_line and new"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local lines = diff.get_render_lines(parsed)
    for index, line in ipairs(lines) do
        if line.type == "context" then
            local source, side = diff.get_source_line(index, lines)
            expect.equality(source, line.new_line)
            expect.equality(side, "new")
            break
        end
    end
end

get_source_line["header line returns nil nil"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local lines = diff.get_render_lines(parsed)
    local source, side = diff.get_source_line(1, lines)
    expect.equality(source, nil)
    expect.equality(side, nil)
end

get_source_line["out of bounds returns nil nil"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local lines = diff.get_render_lines(parsed)
    local source, side = diff.get_source_line(999, lines)
    expect.equality(source, nil)
    expect.equality(side, nil)
end

return T
