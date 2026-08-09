local new_set = MiniTest.new_set
local expect = MiniTest.expect

local config = require("review.config")
local helpers = require("tests.helpers")

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
    expect.equality(config.get().ui.number_navigation, false)
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
    expect.equality(config.get().ui.number_navigation, false)
    expect.equality(config.get().tmux.target, "!")
end

T["numeric section navigation can be enabled"] = function()
    config.setup({ ui = { number_navigation = true } })
    expect.equality(config.get().ui.number_navigation, true)
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

T["get_enabled_panels resolves defaults"] = function()
    local panels = config.get_enabled_panels(nil)
    expect.equality(panels, { "branch_info", "file_tree", "branch_list", "commit_list", "comment_list" })
end

T["get_enabled_panels handles array of aliases"] = function()
    local panels = config.get_enabled_panels({ "files", "comments" })
    expect.equality(panels, { "file_tree", "comment_list" })
end

T["get_enabled_panels handles boolean flags to disable branch and commits"] = function()
    local panels = config.get_enabled_panels({ branch_info = false, branch_list = false, commit_list = false })
    expect.equality(panels, { "file_tree", "comment_list" })

    local alias_panels = config.get_enabled_panels({ branch = false, branches = false, commits = false })
    expect.equality(alias_panels, { "file_tree", "comment_list" })
end

T["get_enabled_panels fallback ensures file_tree is present"] = function()
    local panels = config.get_enabled_panels({})
    expect.equality(panels, { "branch_info", "file_tree", "branch_list", "commit_list", "comment_list" })

    local empty_panels = config.get_enabled_panels({ "invalid_panel_name" })
    expect.equality(empty_panels, { "file_tree" })
end

T["get_enabled_panels({ files = false }) still contains file_tree"] = function()
    local panels = config.get_enabled_panels({ files = false })
    expect.equality(vim.tbl_contains(panels, "file_tree"), true)
end

T["setup warns on non-table ui.panels and uses defaults"] = function()
    local captured, restore = helpers.capture_notifications()
    config.setup({ ui = { panels = "files" } })
    restore()

    expect.equality(#captured, 1)
    expect.equality(captured[1].message, "ui.panels must be a table, using defaults")
    expect.equality(captured[1].level, vim.log.levels.WARN)
    expect.equality(config.get().ui.panels, config.defaults.ui.panels)
end

T["setup warns on unknown panel names and disabled files panel"] = function()
    local captured, restore = helpers.capture_notifications()
    config.setup({ ui = { panels = { "invalid_name" } } })
    restore()

    expect.equality(#captured, 2)
    expect.equality(captured[1].message, "Unknown panel name 'invalid_name', skipping")
    expect.equality(captured[1].level, vim.log.levels.WARN)
    expect.equality(captured[2].message, "Files panel cannot be disabled")
    expect.equality(captured[2].level, vim.log.levels.WARN)
end

T["setup warns when files panel disabled via map"] = function()
    local captured, restore = helpers.capture_notifications()
    config.setup({ ui = { panels = { files = false } } })
    restore()

    expect.equality(#captured, 1)
    expect.equality(captured[1].message, "Files panel cannot be disabled")
    expect.equality(captured[1].level, vim.log.levels.WARN)
end

return T
