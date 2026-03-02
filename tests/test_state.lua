local new_set = MiniTest.new_set
local expect = MiniTest.expect

local state = require("review.state")

local T = new_set({
    hooks = {
        pre_case = function()
            state.reset()
        end,
    },
})

local reset_tests = new_set()
T["reset"] = reset_tests

reset_tests["clears all state"] = function()
    state.state.is_open = true
    state.state.current_file = "test.lua"
    state.add_comment("test.lua", 1, "note", "hello")
    state.reset()
    expect.equality(state.state.is_open, false)
    expect.equality(state.state.current_file, nil)
    expect.equality(vim.tbl_count(state.state.files), 0)
    expect.equality(state.state.comment_id_counter, 0)
end

reset_tests["no shared references after reset"] = function()
    state.add_comment("a.lua", 1, "note", "first")
    local files_before = state.state.files
    state.reset()
    expect.equality(vim.tbl_count(files_before), 1)
    expect.equality(vim.tbl_count(state.state.files), 0)
end

local history_tests = new_set()
T["is_history_mode"] = history_tests

history_tests["false for HEAD"] = function()
    state.state.base = "HEAD"
    expect.equality(state.is_history_mode(), false)
end

history_tests["true for non-HEAD"] = function()
    state.state.base = "abc123"
    expect.equality(state.is_history_mode(), true)
end

local file_state_tests = new_set()
T["get_file_state"] = file_state_tests

file_state_tests["creates on first access"] = function()
    local fs = state.get_file_state("new.lua")
    expect.equality(fs.path, "new.lua")
    expect.equality(fs.reviewed, false)
    expect.equality(fs.comments, {})
end

file_state_tests["returns same reference on second access"] = function()
    local first = state.get_file_state("test.lua")
    first.reviewed = true
    local second = state.get_file_state("test.lua")
    expect.equality(second.reviewed, true)
end

file_state_tests["does not overwrite existing state"] = function()
    state.add_comment("test.lua", 1, "note", "existing")
    local fs = state.get_file_state("test.lua")
    expect.equality(#fs.comments, 1)
end

local reviewed_tests = new_set()
T["reviewed"] = reviewed_tests

reviewed_tests["set and get"] = function()
    state.set_reviewed("test.lua", true)
    expect.equality(state.is_reviewed("test.lua"), true)
    state.set_reviewed("test.lua", false)
    expect.equality(state.is_reviewed("test.lua"), false)
end

reviewed_tests["unknown file returns false"] = function()
    expect.equality(state.is_reviewed("nonexistent.lua"), false)
end

local comment_id_tests = new_set()
T["generate_comment_id"] = comment_id_tests

comment_id_tests["sequential comment_N format"] = function()
    local id1 = state.generate_comment_id()
    local id2 = state.generate_comment_id()
    expect.equality(id1, "comment_1")
    expect.equality(id2, "comment_2")
end

comment_id_tests["global counter persists across files"] = function()
    state.add_comment("a.lua", 1, "note", "first")
    state.add_comment("b.lua", 1, "note", "second")
    local id = state.generate_comment_id()
    expect.equality(id, "comment_3")
end

local add_comment_tests = new_set()
T["add_comment"] = add_comment_tests

add_comment_tests["returns comment with all fields"] = function()
    local comment = state.add_comment("test.lua", 5, "fix", "Fix this", 42)
    expect.equality(comment.id, "comment_1")
    expect.equality(comment.file, "test.lua")
    expect.equality(comment.line, 5)
    expect.equality(comment.type, "fix")
    expect.equality(comment.text, "Fix this")
    expect.equality(comment.original_line, 42)
    expect.equality(type(comment.created_at), "number")
end

add_comment_tests["stored in correct file state"] = function()
    state.add_comment("test.lua", 1, "note", "hello")
    local fs = state.state.files["test.lua"]
    expect.equality(#fs.comments, 1)
    expect.equality(fs.comments[1].text, "hello")
end

add_comment_tests["created_at is a positive number"] = function()
    local comment = state.add_comment("test.lua", 1, "note", "hello")
    expect.equality(comment.created_at > 0, true)
end

add_comment_tests["original_line is nil when not provided"] = function()
    local comment = state.add_comment("test.lua", 1, "note", "hello")
    expect.equality(comment.original_line, nil)
end

local remove_comment_tests = new_set()
T["remove_comment"] = remove_comment_tests

remove_comment_tests["returns true on success"] = function()
    local comment = state.add_comment("test.lua", 1, "note", "hello")
    expect.equality(state.remove_comment("test.lua", comment.id), true)
end

remove_comment_tests["returns false for missing file"] = function()
    expect.equality(state.remove_comment("nonexistent.lua", "comment_1"), false)
end

remove_comment_tests["returns false for missing comment id"] = function()
    state.add_comment("test.lua", 1, "note", "hello")
    expect.equality(state.remove_comment("test.lua", "comment_999"), false)
end

remove_comment_tests["removes correct comment among multiple"] = function()
    state.add_comment("test.lua", 1, "note", "first")
    local second = state.add_comment("test.lua", 2, "note", "second")
    state.add_comment("test.lua", 3, "note", "third")
    state.remove_comment("test.lua", second.id)
    local remaining = state.get_comments_for_file("test.lua")
    expect.equality(#remaining, 2)
    expect.equality(remaining[1].text, "first")
    expect.equality(remaining[2].text, "third")
end

local get_at_line_tests = new_set()
T["get_comment_at_line"] = get_at_line_tests

get_at_line_tests["returns first match"] = function()
    state.add_comment("test.lua", 5, "note", "found")
    local result = state.get_comment_at_line("test.lua", 5)
    expect.equality(result.text, "found")
end

get_at_line_tests["returns nil for missing line"] = function()
    state.add_comment("test.lua", 5, "note", "hello")
    expect.equality(state.get_comment_at_line("test.lua", 10), nil)
end

get_at_line_tests["returns nil for missing file"] = function()
    expect.equality(state.get_comment_at_line("nonexistent.lua", 1), nil)
end

local get_all_tests = new_set()
T["get_all_comments"] = get_all_tests

get_all_tests["sorted by file then line"] = function()
    state.add_comment("b.lua", 10, "note", "b10")
    state.add_comment("a.lua", 5, "note", "a5")
    state.add_comment("a.lua", 1, "note", "a1")
    local all = state.get_all_comments()
    expect.equality(#all, 3)
    expect.equality(all[1].file, "a.lua")
    expect.equality(all[1].line, 1)
    expect.equality(all[2].file, "a.lua")
    expect.equality(all[2].line, 5)
    expect.equality(all[3].file, "b.lua")
end

get_all_tests["empty when no comments"] = function()
    expect.equality(state.get_all_comments(), {})
end

local grouped_tests = new_set()
T["get_comments_grouped_by_file"] = grouped_tests

grouped_tests["excludes files with no comments"] = function()
    state.get_file_state("empty.lua")
    state.add_comment("has.lua", 1, "note", "hello")
    local grouped = state.get_comments_grouped_by_file()
    expect.equality(grouped["empty.lua"], nil)
    expect.no_equality(grouped["has.lua"], nil)
end

grouped_tests["sorted within file by line"] = function()
    state.add_comment("test.lua", 10, "note", "ten")
    state.add_comment("test.lua", 1, "note", "one")
    local grouped = state.get_comments_grouped_by_file()
    expect.equality(grouped["test.lua"][1].line, 1)
    expect.equality(grouped["test.lua"][2].line, 10)
end

grouped_tests["returns deep copy"] = function()
    state.add_comment("test.lua", 1, "note", "original")
    local grouped = state.get_comments_grouped_by_file()
    grouped["test.lua"][1].text = "mutated"
    local original = state.get_comments_for_file("test.lua")
    expect.equality(original[1].text, "original")
end

return T
