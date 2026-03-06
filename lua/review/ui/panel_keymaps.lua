local M = {}

---Navigate to a layout component by getter name
---@param getter_name string Layout getter method name (e.g. "get_file_tree")
local function navigate_to(getter_name)
    local layout = require("review.ui.layout")
    local component = layout[getter_name]()
    if component and component.winid and vim.api.nvim_win_is_valid(component.winid) then
        vim.api.nvim_set_current_win(component.winid)
    end
end

---@class PanelNavigation
---@field tab_target string Layout getter name for Tab cycling
---@field h_target string|nil Layout getter name for h key (nil = Nop)
---@field l_target string|nil Layout getter name for l key (nil = Nop)
---@field scroll_keys? {down: string, up: string} Scroll keys (default "<C-d>"/"<C-u>")
---@field keymap_group? string Group name for help overlay tracking

---Setup shared sidebar panel keymaps
---@param bufnr number
---@param navigation PanelNavigation
---@param on_close function
---@param active_timers table
---@param map_function fun(lhs: string, rhs: string|function, opts: table, extra_bufnrs?: number[])
function M.setup(bufnr, navigation, on_close, active_timers, map_function)
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

    map_function("<Tab>", function()
        navigate_to(navigation.tab_target)
    end, { nowait = true, desc = "Next pane", group = group })

    if navigation.h_target then
        map_function("h", function()
            navigate_to(navigation.h_target)
        end, { nowait = true, desc = "Previous panel", group = group })
    else
        vim.keymap.set("n", "h", "<Nop>", { buffer = bufnr, nowait = true })
    end

    if navigation.l_target then
        map_function("l", function()
            navigate_to(navigation.l_target)
        end, { nowait = true, desc = "Next panel", group = group })
    else
        vim.keymap.set("n", "l", "<Nop>", { buffer = bufnr, nowait = true })
    end

    vim.keymap.set("n", "<Left>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Right>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<C-h>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<C-l>", function()
        navigate_to("get_diff_view")
    end, { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<C-j>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<C-k>", "<Nop>", { buffer = bufnr, nowait = true })
end

return M
