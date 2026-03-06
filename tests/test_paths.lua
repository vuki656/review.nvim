local new_set = MiniTest.new_set
local expect = MiniTest.expect

local paths = require("review.core.paths")

local T = new_set()

T["get_relative_path"] = new_set()

T["get_relative_path"]["strips cwd prefix"] = function()
    local cwd = vim.fn.getcwd()
    local result = paths.get_relative_path(cwd .. "/src/main.lua")
    expect.equality(result, "src/main.lua")
end

T["get_relative_path"]["returns path unchanged when not under cwd"] = function()
    local result = paths.get_relative_path("/other/project/file.lua")
    expect.equality(result, "/other/project/file.lua")
end

T["get_relative_path"]["returns path unchanged when already relative"] = function()
    local result = paths.get_relative_path("src/main.lua")
    expect.equality(result, "src/main.lua")
end

T["is_test_file"] = new_set()

T["is_test_file"]["detects test_ prefix"] = function()
    expect.equality(paths.is_test_file("test_main.lua"), true)
end

T["is_test_file"]["detects .test. infix"] = function()
    expect.equality(paths.is_test_file("main.test.ts"), true)
end

T["is_test_file"]["detects .spec. infix"] = function()
    expect.equality(paths.is_test_file("main.spec.js"), true)
end

T["is_test_file"]["detects _test. infix"] = function()
    expect.equality(paths.is_test_file("main_test.go"), true)
end

T["is_test_file"]["detects _spec. infix"] = function()
    expect.equality(paths.is_test_file("main_spec.rb"), true)
end

T["is_test_file"]["detects spec_ prefix"] = function()
    expect.equality(paths.is_test_file("spec_helper.rb"), true)
end

T["is_test_file"]["rejects regular files"] = function()
    expect.equality(paths.is_test_file("main.lua"), false)
end

T["is_test_file"]["rejects files with test in directory path only"] = function()
    expect.equality(paths.is_test_file("utils.lua"), false)
end

T["get_code_fence_language"] = new_set()

T["get_code_fence_language"]["maps ts to typescript"] = function()
    expect.equality(paths.get_code_fence_language("file.ts"), "typescript")
end

T["get_code_fence_language"]["maps js to javascript"] = function()
    expect.equality(paths.get_code_fence_language("file.js"), "javascript")
end

T["get_code_fence_language"]["maps py to python"] = function()
    expect.equality(paths.get_code_fence_language("file.py"), "python")
end

T["get_code_fence_language"]["maps yml to yaml"] = function()
    expect.equality(paths.get_code_fence_language("file.yml"), "yaml")
end

T["get_code_fence_language"]["passes through lua unchanged"] = function()
    expect.equality(paths.get_code_fence_language("file.lua"), "lua")
end

T["get_code_fence_language"]["passes through unknown extensions"] = function()
    expect.equality(paths.get_code_fence_language("file.zig"), "zig")
end

return T
