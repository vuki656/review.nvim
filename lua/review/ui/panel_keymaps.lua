local M = {}

local config = require("review.config")

---Navigate to a layout component by getter name
---@param getter_name string Layout getter method name (e.g. "get_file_tree")
local function navigate_to(getter_name)
    local layout = require("review.ui.layout")
    local component = layout[getter_name]()

    if
        (not component or not component.winid or not vim.api.nvim_win_is_valid(component.winid))
        and getter_name ~= "get_diff_view"
        and layout.is_mounted()
        and not layout.is_file_tree_visible()
    then
        layout.show_file_tree()
        component = layout[getter_name]()
    end

    if component and component.winid and vim.api.nvim_win_is_valid(component.winid) then
        vim.api.nvim_set_current_win(component.winid)
    end
end

---Set up optional numeric navigation between review sections
---@param map_function fun(lhs: string, rhs: string|function, opts: table, extra_bufnrs?: number[])
---@param extra_bufnrs? number[] Buffers that should receive the same mappings
function M.setup_number_navigation(map_function, extra_bufnrs)
    if not config.get().ui.number_navigation then
        return
    end

    local layout = require("review.ui.layout")
    local panels = layout.get_active_interactive_panels()

    for i, panel in ipairs(panels) do
        local key = tostring(i)
        local target = "get_" .. panel.name
        local desc = "Focus " .. panel.title .. " panel"
        map_function(key, function()
            navigate_to(target)
        end, { nowait = true, desc = desc, group = "Navigation" }, extra_bufnrs)
    end

    map_function("0", function()
        navigate_to("get_diff_view")
    end, { nowait = true, desc = "Focus diff pane", group = "Navigation" }, extra_bufnrs)
end

---@class PanelNavigation
---@field panel_name string Name of the current panel (e.g. "file_tree")
---@field scroll_keys? {down: string, up: string} Scroll keys (default "<C-d>"/"<C-u>")
---@field keymap_group? string Group name for help overlay tracking

---Setup shared sidebar panel keymaps
---@param bufnr number
---@param navigation PanelNavigation
---@param on_close function
---@param active_timers table
---@param map_function fun(lhs: string, rhs: string|function, opts: table, extra_bufnrs?: number[])
---@param on_escape? function Called when Esc is pressed
function M.setup(bufnr, navigation, on_close, active_timers, map_function, on_escape)
    local scroll_util = require("review.ui.util")

    local scroll_down = navigation.scroll_keys and navigation.scroll_keys.down or "<C-d>"
    local scroll_up = navigation.scroll_keys and navigation.scroll_keys.up or "<C-u>"
    local group = navigation.keymap_group

    map_function(scroll_down, function()
        scroll_util.smooth_scroll(active_timers, "down")
    end, { nowait = true, desc = "Scroll diff down", group = group })

    map_function(scroll_up, function()
        scroll_util.smooth_scroll(active_timers, "up")
    end, { nowait = true, desc = "Scroll diff up", group = group })

    map_function("q", on_close, { nowait = true, desc = "Close review", group = group })

    if on_escape then
        map_function("<Esc>", on_escape, { nowait = true, desc = "Reset to HEAD", group = group })
    end

    map_function("P", function()
        require("review.ui.push").push()
    end, { nowait = true, desc = "Push to remote", group = group })

    map_function("<Tab>", function()
        local layout = require("review.ui.layout")
        local target = layout.get_adjacent_panel_getter(navigation.panel_name, "next")
        if target then
            navigate_to(target)
        end
    end, { nowait = true, desc = "Next pane", group = group })

    map_function("h", function()
        local layout = require("review.ui.layout")
        local target = layout.get_adjacent_panel_getter(navigation.panel_name, "prev")
        if target then
            navigate_to(target)
        end
    end, { nowait = true, desc = "Previous panel", group = group })

    map_function("l", function()
        local layout = require("review.ui.layout")
        local target = layout.get_adjacent_panel_getter(navigation.panel_name, "next")
        if target then
            navigate_to(target)
        end
    end, { nowait = true, desc = "Next panel", group = group })

    M.setup_number_navigation(map_function)

    vim.keymap.set("n", "<Left>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Right>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<C-h>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<C-l>", function()
        local layout = require("review.ui.layout")
        if layout.is_split_mode() then
            navigate_to("get_diff_view_old")
        else
            navigate_to("get_diff_view")
        end
    end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<C-j>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<C-k>", "<Nop>", { buffer = bufnr, nowait = true })
end

return M
