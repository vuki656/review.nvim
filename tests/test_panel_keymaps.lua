local new_set = MiniTest.new_set
local expect = MiniTest.expect

local config = require("review.config")
local panel_keymaps = require("review.ui.panel_keymaps")

local T = new_set({
    hooks = {
        pre_case = function()
            config.setup()
        end,
    },
})

local function capture_mappings(extra_bufnrs)
    local mappings = {}
    panel_keymaps.setup_number_navigation(function(lhs, rhs, opts, extra)
        table.insert(mappings, {
            lhs = lhs,
            rhs = rhs,
            desc = opts.desc,
            group = opts.group,
            extra_bufnrs = extra,
        })
    end, extra_bufnrs)
    return mappings
end

T["numeric navigation is disabled by default"] = function()
    local mappings = capture_mappings()
    expect.equality(#mappings, 0)
end

T["numeric navigation registers all section targets"] = function()
    config.setup({ ui = { number_navigation = true } })

    local extra_bufnrs = { 10, 11 }
    local mappings = capture_mappings(extra_bufnrs)

    expect.equality(
        vim.tbl_map(function(mapping)
            return mapping.lhs
        end, mappings),
        { "1", "2", "3", "4", "0" }
    )
    expect.equality(
        vim.tbl_map(function(mapping)
            return mapping.desc
        end, mappings),
        {
            "Focus Files panel",
            "Focus Branches panel",
            "Focus Commits panel",
            "Focus Comments panel",
            "Focus diff pane",
        }
    )
    expect.equality(
        vim.tbl_map(function(mapping)
            return mapping.group
        end, mappings),
        { "Navigation", "Navigation", "Navigation", "Navigation", "Navigation" }
    )
    for _, mapping in ipairs(mappings) do
        expect.equality(mapping.extra_bufnrs, extra_bufnrs)
    end
end

return T
