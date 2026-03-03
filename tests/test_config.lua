local new_set = MiniTest.new_set
local expect = MiniTest.expect

local config = require("review.config")

local T = new_set({
    hooks = {
        pre_case = function()
            config.options = {}
        end,
    },
})

T["setup with no args uses defaults"] = function()
    config.setup()
    expect.equality(config.get().diff.base, "HEAD")
    expect.equality(config.get().ui.file_tree_width, 33)
    expect.equality(config.get().tmux.auto_enter, false)
end

T["setup with empty table uses defaults"] = function()
    config.setup({})
    expect.equality(config.get().diff.base, "HEAD")
end

T["partial override merges correctly"] = function()
    config.setup({
        diff = { base = "main" },
        ui = { file_tree_width = 40 },
    })
    expect.equality(config.get().diff.base, "main")
    expect.equality(config.get().ui.file_tree_width, 40)
    expect.equality(config.get().ui.diff_view_mode, "unified")
    expect.equality(config.get().tmux.target, "CLAUDE")
end

T["deep nested override preserves siblings"] = function()
    config.setup({
        quick_comments = {
            panel = { width = 80 },
        },
    })
    expect.equality(config.get().quick_comments.panel.width, 80)
    expect.equality(config.get().quick_comments.panel.position, "right")
    expect.equality(config.get().quick_comments.signs.enabled, true)
end

T["repeated setup overrides previous"] = function()
    config.setup({ diff = { base = "main" } })
    expect.equality(config.get().diff.base, "main")

    config.setup({ diff = { base = "develop" } })
    expect.equality(config.get().diff.base, "develop")
end

T["templates are overridable"] = function()
    local custom_templates = {
        { key = "x", label = "Custom", text = "Custom text" },
    }
    config.setup({ templates = custom_templates })
    expect.equality(#config.get().templates, 1)
    expect.equality(config.get().templates[1].key, "x")
end

T["get returns current options"] = function()
    config.setup({ diff = { base = "test" } })
    local result = config.get()
    expect.equality(result.diff.base, "test")
end

return T
