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

T["binary diff is flagged"] = function()
    local parsed = diff.parse("diff --git a/bin.dat b/bin.dat\nBinary files a/bin.dat and b/bin.dat differ\n")
    expect.equality(parsed.binary, true)
    expect.equality(#parsed.hunks, 0)
end

T["non-binary diff is not flagged"] = function()
    local parsed = diff.parse("--- a/f.txt\n+++ b/f.txt\n@@ -1 +1 @@\n-a\n+b\n")
    expect.equality(parsed.binary, false)
end

get_source_line["split add line returns its source_line"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local _, new_lines = diff.get_split_render_lines(parsed)
    local found = false
    for index, line in ipairs(new_lines) do
        if line.type == "add" then
            local source, side = diff.get_source_line(index, new_lines)
            expect.equality(source, line.source_line)
            expect.no_equality(source, nil)
            expect.equality(side, "new")
            found = true
            break
        end
    end
    expect.equality(found, true)
end

get_source_line["split delete line returns its source_line"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local old_lines = diff.get_split_render_lines(parsed)
    local found = false
    for index, line in ipairs(old_lines) do
        if line.type == "delete" then
            local source, side = diff.get_source_line(index, old_lines)
            expect.equality(source, line.source_line)
            expect.no_equality(source, nil)
            expect.equality(side, "old")
            found = true
            break
        end
    end
    expect.equality(found, true)
end

get_source_line["split padding and filepath lines return nil"] = function()
    local parsed = diff.parse(helpers.SIMPLE_DIFF)
    local old_lines = diff.get_split_render_lines(parsed)
    expect.equality(diff.get_source_line(1, old_lines), nil)
    for index, line in ipairs(old_lines) do
        if line.type == "padding" then
            expect.equality(diff.get_source_line(index, old_lines), nil)
            break
        end
    end
end

T["deleted line starting with -- is not mistaken for a file header"] = function()
    local parsed = diff.parse(table.concat({
        "--- a/f.lua",
        "+++ b/f.lua",
        "@@ -1,4 +1,3 @@",
        " local a = 1",
        "--- an old comment",
        "-local b = 2",
        "+local b = 3",
        " local c = 4",
    }, "\n"))

    expect.equality(parsed.file_old, "f.lua")

    local lines = parsed.hunks[1].lines
    expect.equality(lines[2].type, "delete")
    expect.equality(lines[2].content, "-- an old comment")
    expect.equality(lines[2].old_line, 2)
    expect.equality(lines[3].old_line, 3)
    expect.equality(lines[4].type, "add")
    expect.equality(lines[5].type, "context")
    expect.equality(lines[5].old_line, 4)
end

T["added line starting with ++ is not mistaken for a file header"] = function()
    local parsed = diff.parse(table.concat({
        "--- a/f.c",
        "+++ b/f.c",
        "@@ -1,2 +1,3 @@",
        " int a;",
        "+++counter;",
        " int c;",
    }, "\n"))

    expect.equality(parsed.file_new, "f.c")

    local lines = parsed.hunks[1].lines
    expect.equality(lines[2].type, "add")
    expect.equality(lines[2].content, "++counter;")
    expect.equality(lines[3].new_line, 3)
end

T["diff --git resets hunk state between files"] = function()
    local parsed = diff.parse(table.concat({
        "diff --git a/one.lua b/one.lua",
        "--- a/one.lua",
        "+++ b/one.lua",
        "@@ -1 +1 @@",
        "-a",
        "+b",
        "diff --git a/two.lua b/two.lua",
        "--- a/two.lua",
        "+++ b/two.lua",
        "@@ -10 +10 @@",
        "-c",
        "+d",
    }, "\n"))

    expect.equality(parsed.file_new, "two.lua")
    expect.equality(#parsed.hunks, 2)
    expect.equality(parsed.hunks[2].old_start, 10)
    expect.equality(#parsed.hunks[1].lines, 2)
end

T["crlf diff strips carriage returns"] = function()
    local parsed = diff.parse("--- a/f.txt\r\n+++ b/f.txt\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n")
    expect.equality(parsed.file_new, "f.txt")
    expect.equality(parsed.hunks[1].lines[1].content, "a")
    expect.equality(parsed.hunks[1].lines[2].content, "b")
end

local function mixed_render_lines()
    return {
        { type = "filepath", content = "f.lua" },
        { type = "context", old_line = 40, new_line = 40, content = "keep" },
        { type = "delete", old_line = 41, content = "old one" },
        { type = "delete", old_line = 42, content = "old two" },
        { type = "add", new_line = 41, content = "new one" },
        { type = "add", new_line = 42, content = "new two" },
        { type = "context", old_line = 43, new_line = 43, content = "tail" },
    }
end

local source_range_tests = new_set()
T["get_source_range"] = source_range_tests

source_range_tests["selection starting on a delete stays on the old side"] = function()
    local range = diff.get_source_range(3, 6, mixed_render_lines())
    expect.equality(range.side, "old")
    expect.equality(range.line, 3)
    expect.equality(range.original_line, 41)
    expect.equality(range.end_line, 4)
    expect.equality(range.original_end_line, 42)
end

source_range_tests["selection starting on context stays on the new side"] = function()
    local range = diff.get_source_range(2, 6, mixed_render_lines())
    expect.equality(range.side, "new")
    expect.equality(range.original_line, 40)
    expect.equality(range.end_line, 6)
    expect.equality(range.original_end_line, 42)
end

source_range_tests["anchors to the first row that has a source line"] = function()
    local range = diff.get_source_range(1, 3, mixed_render_lines())
    expect.equality(range.line, 2)
    expect.equality(range.original_line, 40)
    expect.equality(range.side, "new")
    expect.equality(range.end_line, nil)
end

source_range_tests["single row selection has no end"] = function()
    local range = diff.get_source_range(5, 5, mixed_render_lines())
    expect.equality(range.original_line, 41)
    expect.equality(range.end_line, nil)
    expect.equality(range.original_end_line, nil)
end

source_range_tests["nil when no row has a source line"] = function()
    expect.equality(diff.get_source_range(1, 1, mixed_render_lines()), nil)
end

source_range_tests["nil without render lines"] = function()
    expect.equality(diff.get_source_range(1, 3, nil), nil)
end

local reanchor_tests = new_set()
T["reanchor_comment"] = reanchor_tests

reanchor_tests["moves display rows to the current rendering"] = function()
    local comment = { line = 99, end_line = 100, original_line = 41, original_end_line = 42, side = "new" }
    diff.reanchor_comment(comment, mixed_render_lines())
    expect.equality(comment.line, 5)
    expect.equality(comment.end_line, 6)
end

reanchor_tests["degrades to single line when the end row is gone"] = function()
    local comment = { line = 5, end_line = 6, original_line = 41, original_end_line = 99, side = "new" }
    diff.reanchor_comment(comment, mixed_render_lines())
    expect.equality(comment.line, 5)
    expect.equality(comment.end_line, nil)
    expect.equality(comment.original_end_line, 99)
end

reanchor_tests["keeps the old display row when the start row is gone"] = function()
    local comment = { line = 7, original_line = 99, side = "new" }
    diff.reanchor_comment(comment, mixed_render_lines())
    expect.equality(comment.line, 7)
end

reanchor_tests["does not match the wrong side"] = function()
    local comment = { line = 1, original_line = 41, side = "old" }
    diff.reanchor_comment(comment, mixed_render_lines())
    expect.equality(comment.line, 3)
end

return T
