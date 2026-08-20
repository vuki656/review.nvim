local new_set = MiniTest.new_set
local expect = MiniTest.expect

local watcher = require("review.core.watcher")

local T = new_set()

T["is_ignored_path"] = new_set()

T["is_ignored_path"]["ignores paths inside ignored directories"] = function()
    expect.equality(watcher.is_ignored_path(".git/index.lock"), true)
    expect.equality(watcher.is_ignored_path("packages/app/node_modules/foo/index.js"), true)
    expect.equality(watcher.is_ignored_path("target\\debug\\main"), true)
end

T["is_ignored_path"]["keeps regular paths"] = function()
    expect.equality(watcher.is_ignored_path("lua/review/init.lua"), false)
    expect.equality(watcher.is_ignored_path("src/.gitignore"), false)
    expect.equality(watcher.is_ignored_path("builds/out.txt"), false)
end

T["is_ignored_path"]["treats a missing filename as not ignored"] = function()
    expect.equality(watcher.is_ignored_path(nil), false)
end

return T
