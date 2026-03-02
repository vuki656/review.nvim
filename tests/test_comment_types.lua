local new_set = MiniTest.new_set
local expect = MiniTest.expect

local comment_types = require("review.comment_types")

local T = new_set()

T["TYPES has exactly fix, note, question"] = function()
    local keys = vim.tbl_keys(comment_types.TYPES)
    table.sort(keys)
    expect.equality(keys, { "fix", "note", "question" })
end

T["each type has all required fields"] = function()
    local required_fields = { "label", "icon", "highlight", "border_hl", "title_hl" }

    for type_key, type_def in pairs(comment_types.TYPES) do
        for _, field in ipairs(required_fields) do
            expect.equality(
                type(type_def[field]),
                "string",
                string.format("TYPES.%s.%s should be a string", type_key, field)
            )
        end
    end
end

T["ORDER is exactly fix, note, question"] = function()
    expect.equality(comment_types.ORDER, { "fix", "note", "question" })
end

T["every ORDER entry exists in TYPES"] = function()
    for _, key in ipairs(comment_types.ORDER) do
        expect.no_equality(comment_types.TYPES[key], nil, string.format("ORDER entry '%s' missing from TYPES", key))
    end
end

return T
