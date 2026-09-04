local new_set = MiniTest.new_set
local expect = MiniTest.expect

local limits = require("review.core.limits")

local T = new_set()

T["is_too_large"] = new_set()

T["is_too_large"]["is false at the limit"] = function()
    expect.equality(limits.is_too_large(100, 100), false)
end

T["is_too_large"]["is true above the limit"] = function()
    expect.equality(limits.is_too_large(101, 100), true)
end

T["is_too_large"]["is false below the limit"] = function()
    expect.equality(limits.is_too_large(0, 100), false)
end

T["is_too_large"]["is false when the size is unknown"] = function()
    expect.equality(limits.is_too_large(nil, 100), false)
end

T["is_binary_chunk"] = new_set()

T["is_binary_chunk"]["detects a NUL byte"] = function()
    expect.equality(limits.is_binary_chunk("abc\0def"), true)
end

T["is_binary_chunk"]["detects a leading NUL byte"] = function()
    expect.equality(limits.is_binary_chunk("\0"), true)
end

T["is_binary_chunk"]["treats plain text as text"] = function()
    expect.equality(limits.is_binary_chunk("local x = 1\nreturn x\n"), false)
end

T["is_binary_chunk"]["treats utf-8 as text"] = function()
    expect.equality(limits.is_binary_chunk("héllo — wörld"), false)
end

T["is_binary_chunk"]["is false for an empty chunk"] = function()
    expect.equality(limits.is_binary_chunk(""), false)
end

T["is_binary_chunk"]["is false when the read failed"] = function()
    expect.equality(limits.is_binary_chunk(nil), false)
end

T["limits"] = new_set()

T["limits"]["diff cap is larger than the source cap"] = function()
    expect.equality(limits.MAX_DIFF_BYTES > limits.MAX_SOURCE_BYTES, true)
end

T["limits"]["binary probe is smaller than both caps"] = function()
    expect.equality(limits.BINARY_PROBE_BYTES < limits.MAX_SOURCE_BYTES, true)
end

return T
