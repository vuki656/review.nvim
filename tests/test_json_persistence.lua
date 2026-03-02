local new_set = MiniTest.new_set
local expect = MiniTest.expect

local json_persistence = require("review.core.json_persistence")

local T = new_set()

local function temp_path()
    return os.tmpname()
end

local read_tests = new_set()
T["read_json_file"] = read_tests

read_tests["missing file returns true nil"] = function()
    local ok, data = json_persistence.read_json_file("/tmp/review_nvim_nonexistent_" .. os.time())
    expect.equality(ok, true)
    expect.equality(data, nil)
end

read_tests["empty file returns true nil"] = function()
    local path = temp_path()
    local file = io.open(path, "w")
    file:write("")
    file:close()
    local ok, data = json_persistence.read_json_file(path)
    expect.equality(ok, true)
    expect.equality(data, nil)
    os.remove(path)
end

read_tests["invalid JSON returns false nil"] = function()
    local path = temp_path()
    local file = io.open(path, "w")
    file:write("not json {{{")
    file:close()
    local ok, data = json_persistence.read_json_file(path)
    expect.equality(ok, false)
    expect.equality(data, nil)
    os.remove(path)
end

read_tests["valid JSON returns true data"] = function()
    local path = temp_path()
    local file = io.open(path, "w")
    file:write('{"key":"value","number":42}')
    file:close()
    local ok, data = json_persistence.read_json_file(path)
    expect.equality(ok, true)
    expect.equality(data.key, "value")
    expect.equality(data.number, 42)
    os.remove(path)
end

read_tests["non-table JSON returns false nil"] = function()
    local path = temp_path()
    local file = io.open(path, "w")
    file:write('"just a string"')
    file:close()
    local ok, data = json_persistence.read_json_file(path)
    expect.equality(ok, false)
    expect.equality(data, nil)
    os.remove(path)
end

local write_tests = new_set()
T["write_json_file"] = write_tests

write_tests["write and read round-trip"] = function()
    local path = temp_path()
    local input = { name = "test", items = { 1, 2, 3 }, nested = { deep = true } }
    local write_ok = json_persistence.write_json_file(path, input)
    expect.equality(write_ok, true)

    local read_ok, data = json_persistence.read_json_file(path)
    expect.equality(read_ok, true)
    expect.equality(data.name, "test")
    expect.equality(#data.items, 3)
    expect.equality(data.nested.deep, true)
    os.remove(path)
end

write_tests["unwritable path returns false"] = function()
    local ok = json_persistence.write_json_file("/nonexistent_dir/impossible_file.json", { test = true })
    expect.equality(ok, false)
end

return T
