local new_set = MiniTest.new_set
local expect = MiniTest.expect

local qc_state = require("review.quick_comments.state")

local T = new_set({
    hooks = {
        pre_case = function()
            qc_state.reset()
        end,
    },
})

local reset_tests = new_set()
T["reset"] = reset_tests

reset_tests["clears all state"] = function()
    qc_state.add("/test.lua", 1, "note", "hello")
    qc_state.reset()
    expect.equality(qc_state.count(), 0)
    expect.equality(qc_state.state.comment_id_counter, 0)
end

local id_tests = new_set()
T["generate_id"] = id_tests

id_tests["matches qc_N_N pattern"] = function()
    local identifier = qc_state.generate_id()
    expect.equality(identifier:match("^qc_%d+_%d+$") ~= nil, true)
end

id_tests["sequential IDs differ"] = function()
    local id1 = qc_state.generate_id()
    local id2 = qc_state.generate_id()
    expect.no_equality(id1, id2)
end

local add_tests = new_set()
T["add"] = add_tests

add_tests["returns comment with all fields"] = function()
    local comment = qc_state.add("/test.lua", 10, "fix", "Fix this", "local x = 1")
    expect.equality(comment.file, "/test.lua")
    expect.equality(comment.line, 10)
    expect.equality(comment.type, "fix")
    expect.equality(comment.text, "Fix this")
    expect.equality(comment.context, "local x = 1")
    expect.equality(type(comment.created_at), "number")
    expect.equality(comment.id:match("^qc_") ~= nil, true)
end

add_tests["sorts by line within file"] = function()
    qc_state.add("/test.lua", 20, "note", "twenty")
    qc_state.add("/test.lua", 5, "note", "five")
    qc_state.add("/test.lua", 10, "note", "ten")
    local comments = qc_state.get_for_file("/test.lua")
    expect.equality(comments[1].line, 5)
    expect.equality(comments[2].line, 10)
    expect.equality(comments[3].line, 20)
end

add_tests["stores context as nil when not provided"] = function()
    local comment = qc_state.add("/test.lua", 1, "note", "hello")
    expect.equality(comment.context, nil)
end

local remove_tests = new_set()
T["remove"] = remove_tests

remove_tests["returns true on success"] = function()
    local comment = qc_state.add("/test.lua", 1, "note", "hello")
    expect.equality(qc_state.remove("/test.lua", comment.id), true)
end

remove_tests["returns false for missing file"] = function()
    expect.equality(qc_state.remove("/missing.lua", "qc_1_1"), false)
end

remove_tests["returns false for missing id"] = function()
    qc_state.add("/test.lua", 1, "note", "hello")
    expect.equality(qc_state.remove("/test.lua", "qc_999_999"), false)
end

remove_tests["cleans up empty file entry"] = function()
    local comment = qc_state.add("/test.lua", 1, "note", "hello")
    qc_state.remove("/test.lua", comment.id)
    expect.equality(qc_state.state.comments["/test.lua"], nil)
end

local update_tests = new_set()
T["update"] = update_tests

update_tests["returns true on success"] = function()
    local comment = qc_state.add("/test.lua", 1, "note", "original")
    expect.equality(qc_state.update("/test.lua", comment.id, "updated"), true)
    expect.equality(qc_state.get("/test.lua", comment.id).text, "updated")
end

update_tests["returns false for missing file"] = function()
    expect.equality(qc_state.update("/missing.lua", "qc_1_1", "text"), false)
end

update_tests["returns false for missing id"] = function()
    qc_state.add("/test.lua", 1, "note", "hello")
    expect.equality(qc_state.update("/test.lua", "qc_999_999", "text"), false)
end

local get_tests = new_set()
T["get"] = get_tests

get_tests["returns comment when found"] = function()
    local comment = qc_state.add("/test.lua", 1, "note", "hello")
    local found = qc_state.get("/test.lua", comment.id)
    expect.equality(found.text, "hello")
end

get_tests["returns nil when not found"] = function()
    expect.equality(qc_state.get("/missing.lua", "qc_1_1"), nil)
end

local get_at_line_tests = new_set()
T["get_at_line"] = get_at_line_tests

get_at_line_tests["returns comment at line"] = function()
    qc_state.add("/test.lua", 5, "note", "found")
    local result = qc_state.get_at_line("/test.lua", 5)
    expect.equality(result.text, "found")
end

get_at_line_tests["returns nil when not found"] = function()
    expect.equality(qc_state.get_at_line("/test.lua", 999), nil)
end

local get_for_file_tests = new_set()
T["get_for_file"] = get_for_file_tests

get_for_file_tests["returns comments for file"] = function()
    qc_state.add("/test.lua", 1, "note", "one")
    qc_state.add("/test.lua", 2, "fix", "two")
    local comments = qc_state.get_for_file("/test.lua")
    expect.equality(#comments, 2)
end

get_for_file_tests["returns empty table for missing file"] = function()
    expect.equality(qc_state.get_for_file("/missing.lua"), {})
end

local get_all_tests = new_set()
T["get_all"] = get_all_tests

get_all_tests["returns all comments grouped by file"] = function()
    qc_state.add("/a.lua", 1, "note", "a")
    qc_state.add("/b.lua", 1, "note", "b")
    local all = qc_state.get_all()
    expect.no_equality(all["/a.lua"], nil)
    expect.no_equality(all["/b.lua"], nil)
end

local get_all_flat_tests = new_set()
T["get_all_flat"] = get_all_flat_tests

get_all_flat_tests["sorted by file then line"] = function()
    qc_state.add("/b.lua", 10, "note", "b10")
    qc_state.add("/a.lua", 5, "note", "a5")
    qc_state.add("/a.lua", 1, "note", "a1")
    local all = qc_state.get_all_flat()
    expect.equality(#all, 3)
    expect.equality(all[1].file, "/a.lua")
    expect.equality(all[1].line, 1)
    expect.equality(all[2].file, "/a.lua")
    expect.equality(all[2].line, 5)
    expect.equality(all[3].file, "/b.lua")
end

local count_tests = new_set()
T["count"] = count_tests

count_tests["accurate count across files"] = function()
    qc_state.add("/a.lua", 1, "note", "a")
    qc_state.add("/b.lua", 1, "note", "b")
    qc_state.add("/b.lua", 2, "note", "b2")
    expect.equality(qc_state.count(), 3)
end

local get_files_tests = new_set()
T["get_files"] = get_files_tests

get_files_tests["returns sorted file list"] = function()
    qc_state.add("/c.lua", 1, "note", "c")
    qc_state.add("/a.lua", 1, "note", "a")
    qc_state.add("/b.lua", 1, "note", "b")
    expect.equality(qc_state.get_files(), { "/a.lua", "/b.lua", "/c.lua" })
end

local clear_tests = new_set()
T["clear"] = clear_tests

clear_tests["empties all comments"] = function()
    qc_state.add("/a.lua", 1, "note", "a")
    qc_state.add("/b.lua", 1, "note", "b")
    qc_state.clear()
    expect.equality(qc_state.count(), 0)
    expect.equality(qc_state.get_files(), {})
end

local persistence_tests = new_set()
T["load and export"] = persistence_tests

persistence_tests["export returns correct shape"] = function()
    qc_state.add("/test.lua", 1, "note", "hello")
    local exported = qc_state.export()
    expect.no_equality(exported.comments, nil)
    expect.no_equality(exported.comment_id_counter, nil)
    expect.equality(type(exported.comments), "table")
    expect.equality(type(exported.comment_id_counter), "number")
end

persistence_tests["load restores state from export"] = function()
    qc_state.add("/test.lua", 1, "note", "hello")
    qc_state.add("/test.lua", 5, "fix", "fix this")
    local exported = qc_state.export()

    qc_state.reset()
    expect.equality(qc_state.count(), 0)

    qc_state.load(exported)
    expect.equality(qc_state.count(), 2)
    expect.equality(qc_state.get_for_file("/test.lua")[1].text, "hello")
end

persistence_tests["data preserved through round-trip"] = function()
    local original = qc_state.add("/test.lua", 42, "question", "Why?", "local x = 1")
    local exported = qc_state.export()

    qc_state.reset()
    qc_state.load(exported)

    local restored = qc_state.get_for_file("/test.lua")[1]
    expect.equality(restored.id, original.id)
    expect.equality(restored.line, 42)
    expect.equality(restored.type, "question")
    expect.equality(restored.text, "Why?")
    expect.equality(restored.context, "local x = 1")
end

return T
