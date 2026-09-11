local new_set = MiniTest.new_set
local expect = MiniTest.expect

local git = require("review.core.git")

local T = new_set()

T["name-status: modified file"] = function()
    local entry = git.parse_name_status_line("M\tlua/init.lua")
    expect.equality(entry.status, "modified")
    expect.equality(entry.path, "lua/init.lua")
    expect.equality(entry.rename_from, nil)
end

T["name-status: added and deleted"] = function()
    expect.equality(git.parse_name_status_line("A\tnew.txt").status, "added")
    expect.equality(git.parse_name_status_line("D\tgone.txt").status, "deleted")
end

T["name-status: conflicted file"] = function()
    local entry = git.parse_name_status_line("U\tconflict.txt")
    expect.equality(entry.status, "conflicted")
    expect.equality(entry.path, "conflict.txt")
end

T["name-status: rename with spaces in both paths"] = function()
    local entry = git.parse_name_status_line("R100\told name.txt\tnew name.txt")
    expect.equality(entry.status, "renamed")
    expect.equality(entry.path, "new name.txt")
    expect.equality(entry.rename_from, "old name.txt")
end

T["name-status: copy is not treated as modified"] = function()
    local entry = git.parse_name_status_line("C75\tsrc.txt\tdst.txt")
    expect.equality(entry.status, "copied")
    expect.equality(entry.path, "dst.txt")
    expect.equality(entry.rename_from, "src.txt")
end

T["name-status: path containing spaces stays intact"] = function()
    local entry = git.parse_name_status_line("M\tfile with spaces.txt")
    expect.equality(entry.path, "file with spaces.txt")
end

T["name-status: non-ascii path"] = function()
    local entry = git.parse_name_status_line("M\tä-ünïcode.txt")
    expect.equality(entry.path, "ä-ünïcode.txt")
end

T["name-status: empty and malformed input"] = function()
    expect.equality(git.parse_name_status_line(""), nil)
    expect.equality(git.parse_name_status_line("garbage"), nil)
end

local UNIT = "\31"

local function commit_line(fields)
    return table.concat(fields, UNIT)
end

T["commit line: basic fields"] = function()
    local commit = git.parse_commit_line(commit_line({
        "abc123def",
        "abc123d",
        "fix: something",
        "Ada Lovelace",
        "2 days ago",
        "parent1",
    }))
    expect.equality(commit.hash, "abc123def")
    expect.equality(commit.short_hash, "abc123d")
    expect.equality(commit.subject, "fix: something")
    expect.equality(commit.author, "Ada Lovelace")
    expect.equality(commit.date, "2 days ago")
    expect.equality(commit.parent_count, 1)
    expect.equality(commit.is_merge, false)
end

T["commit line: subject containing a pipe does not shift fields"] = function()
    local commit = git.parse_commit_line(commit_line({
        "abc123",
        "abc",
        "fix: a | b",
        "Ada Lovelace",
        "2 days ago",
        "parent1",
    }))
    expect.equality(commit.subject, "fix: a | b")
    expect.equality(commit.author, "Ada Lovelace")
    expect.equality(commit.date, "2 days ago")
    expect.equality(commit.parent_count, 1)
    expect.equality(commit.is_merge, false)
end

T["commit line: merge commit"] = function()
    local commit = git.parse_commit_line(commit_line({
        "h",
        "s",
        "Merge branch 'x'",
        "Ada",
        "now",
        "parent1 parent2",
    }))
    expect.equality(commit.parent_count, 2)
    expect.equality(commit.is_merge, true)
end

T["commit line: root commit has no parents"] = function()
    local commit = git.parse_commit_line(commit_line({ "h", "s", "init", "Ada", "now", "" }))
    expect.equality(commit.parent_count, 0)
    expect.equality(commit.is_merge, false)
end

T["commit line: empty and malformed input"] = function()
    expect.equality(git.parse_commit_line(""), nil)
    expect.equality(git.parse_commit_line("no separators here"), nil)
end

local unquote = new_set()
T["unquote_path"] = unquote

unquote["leaves an unquoted path alone"] = function()
    expect.equality(git.unquote_path("lua/review/core/git.lua"), "lua/review/core/git.lua")
end

unquote["leaves a path with only a leading quote alone"] = function()
    expect.equality(git.unquote_path('"unterminated.txt'), '"unterminated.txt')
end

unquote["decodes an escaped double quote"] = function()
    expect.equality(git.unquote_path('"we\\"ird.txt"'), 'we"ird.txt')
end

unquote["decodes an escaped backslash"] = function()
    expect.equality(git.unquote_path('"back\\\\slash.txt"'), "back\\slash.txt")
end

unquote["decodes a newline"] = function()
    expect.equality(git.unquote_path('"new\\nline.txt"'), "new\nline.txt")
end

unquote["decodes a tab"] = function()
    expect.equality(git.unquote_path('"a\\tb.txt"'), "a\tb.txt")
end

unquote["decodes octal escapes"] = function()
    expect.equality(git.unquote_path('"caf\\303\\251.txt"'), "café.txt")
end

unquote["name-status line with a quoted path is decoded"] = function()
    local entry = git.parse_name_status_line('M\t"we\\"ird.txt"')
    expect.equality(entry.status, "modified")
    expect.equality(entry.path, 'we"ird.txt')
end

unquote["rename line with quoted paths is decoded"] = function()
    local entry = git.parse_name_status_line('R100\t"old\\nname.txt"\t"new\\"name.txt"')
    expect.equality(entry.status, "renamed")
    expect.equality(entry.rename_from, "old\nname.txt")
    expect.equality(entry.path, 'new"name.txt')
end

local numstat = new_set()
T["numstat"] = numstat

numstat["modified file"] = function()
    local entry = git.parse_numstat_line("12\t3\tlua/init.lua")
    expect.equality(entry.added, 12)
    expect.equality(entry.deleted, 3)
    expect.equality(entry.path, "lua/init.lua")
end

numstat["binary file has no counts"] = function()
    local entry = git.parse_numstat_line("-\t-\tassets/logo.png")
    expect.equality(entry.added, nil)
    expect.equality(entry.deleted, nil)
    expect.equality(entry.path, "assets/logo.png")
end

numstat["rename inside a directory resolves to the new path"] = function()
    local entry = git.parse_numstat_line("1\t1\tlua/{old => new}/init.lua")
    expect.equality(entry.path, "lua/new/init.lua")
end

numstat["rename that drops a directory resolves to the new path"] = function()
    local entry = git.parse_numstat_line("0\t0\tlua/{sub => }/init.lua")
    expect.equality(entry.path, "lua/init.lua")
end

numstat["whole-path rename resolves to the new path"] = function()
    local entry = git.parse_numstat_line("0\t0\told.txt => new.txt")
    expect.equality(entry.path, "new.txt")
end

numstat["path containing spaces stays intact"] = function()
    local entry = git.parse_numstat_line("2\t0\tfile with spaces.txt")
    expect.equality(entry.path, "file with spaces.txt")
end

numstat["quoted path is decoded"] = function()
    local entry = git.parse_numstat_line('1\t0\t"we\\"ird.txt"')
    expect.equality(entry.path, 'we"ird.txt')
end

numstat["empty and malformed input"] = function()
    expect.equality(git.parse_numstat_line(""), nil)
    expect.equality(git.parse_numstat_line(nil), nil)
    expect.equality(git.parse_numstat_line("garbage"), nil)
    expect.equality(git.parse_numstat_line("12\tlua/init.lua"), nil)
end

return T
