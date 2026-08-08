local config = require("review.config")
local log = require("review.core.log")

local M = {}

---@class ReviewLayoutComponent
---@field bufnr number
---@field winid number

---@class ReviewLayout
---@field branch_info ReviewLayoutComponent
---@field file_tree ReviewLayoutComponent
---@field commit_list ReviewLayoutComponent
---@field branch_list ReviewLayoutComponent
---@field comment_list ReviewLayoutComponent
---@field diff_view ReviewLayoutComponent
---@field diff_view_old ReviewLayoutComponent|nil
---@field diff_view_new ReviewLayoutComponent|nil

---@type ReviewLayout|nil
M.current = nil

---@type number|nil
M.prev_tab = nil

---@type number|nil
M.review_tab = nil

---@type number|nil
M.base_winid = nil

---@type number|nil
local resize_autocmd_id = nil

---@class SidebarPanelDef
---@field name string Key in ReviewLayout
---@field title string Display title for float border
---@field filetype string Buffer filetype
---@field is_interactive boolean Whether this panel gets cursorline/active highlight
---@field height_weight number|nil Weight for height calculation (default 1.0)

local ALL_SIDEBAR_PANELS = {
    { name = "branch_info", title = "Branch", filetype = "review-branch-info", is_interactive = false },
    { name = "file_tree", title = "Files", filetype = "review-tree", is_interactive = true },
    { name = "branch_list", title = "Branches", filetype = "review-branches", is_interactive = true },
    { name = "commit_list", title = "Commits", filetype = "review-commits", is_interactive = true },
    {
        name = "comment_list",
        title = "Comments",
        filetype = "review-comments",
        is_interactive = true,
        height_weight = 0.5,
    },
}

local PANEL_DEFS_BY_NAME = {}
for _, panel_def in ipairs(ALL_SIDEBAR_PANELS) do
    PANEL_DEFS_BY_NAME[panel_def.name] = panel_def
end

local PANEL_MODULES = {
    branch_list = "review.ui.branch_list",
    commit_list = "review.ui.commit_list",
    comment_list = "review.ui.comment_list",
}

---Get active sidebar panels based on user configuration
---@return SidebarPanelDef[]
local function get_active_sidebar_panels()
    local opts = config.get()
    local enabled_names = config.get_enabled_panels(opts.ui and opts.ui.panels)
    local active = {}
    for _, name in ipairs(enabled_names) do
        local def = PANEL_DEFS_BY_NAME[name]
        if def then
            table.insert(active, def)
        end
    end
    return active
end

---Get list of active interactive sidebar panels
---@return SidebarPanelDef[]
function M.get_active_interactive_panels()
    local active = get_active_sidebar_panels()
    local interactive = {}
    for _, panel in ipairs(active) do
        if panel.is_interactive then
            table.insert(interactive, panel)
        end
    end
    return interactive
end

---Get adjacent panel getter for navigation (<Tab>, h, l)
---@param current_panel_name string
---@param direction "next"|"prev"
---@return string getter_name
function M.get_adjacent_panel_getter(current_panel_name, direction)
    local interactive = M.get_active_interactive_panels()
    if #interactive == 0 then
        return "get_diff_view"
    end

    local current_idx = nil
    for idx, panel in ipairs(interactive) do
        if panel.name == current_panel_name then
            current_idx = idx
            break
        end
    end

    if not current_idx then
        return "get_file_tree"
    end

    if #interactive == 1 then
        if direction == "next" then
            return "get_diff_view"
        else
            return "get_" .. current_panel_name
        end
    end

    local next_idx
    if direction == "next" then
        next_idx = (current_idx % #interactive) + 1
    else
        next_idx = ((current_idx - 2 + #interactive) % #interactive) + 1
    end

    return "get_" .. interactive[next_idx].name
end

---@type number|nil
local focus_autocmd_id = nil
local tab_closed_autocmd_id = nil

local INACTIVE_WINHIGHLIGHT = "NormalFloat:Normal,FloatBorder:ReviewFloatBorder,FloatTitle:ReviewFloatTitle"
local ACTIVE_SIDEBAR_WINHIGHLIGHT = "NormalFloat:Normal,FloatBorder:ReviewFloatBorderActive,"
    .. "FloatTitle:ReviewFloatTitleActive,CursorLine:ReviewSelected"
local ACTIVE_DIFF_WINHIGHLIGHT = "NormalFloat:Normal,FloatBorder:ReviewFloatBorderActive,"
    .. "FloatTitle:ReviewFloatTitleActive,CursorLine:ReviewDiffCursorLine"

---Update border highlights based on the currently focused window
local function update_border_highlights()
    if not M.current then
        return
    end
    local current_win = vim.api.nvim_get_current_win()
    local interactive_panels = M.get_active_interactive_panels()
    for _, panel_def in ipairs(interactive_panels) do
        local component = M.current[panel_def.name]
        if component and vim.api.nvim_win_is_valid(component.winid) then
            if component.winid == current_win then
                vim.api.nvim_set_option_value("winhighlight", ACTIVE_SIDEBAR_WINHIGHLIGHT, { win = component.winid })
                vim.api.nvim_set_option_value("cursorline", true, { win = component.winid })
            else
                local base = INACTIVE_WINHIGHLIGHT .. ",CursorLine:ReviewSelected"
                vim.api.nvim_set_option_value("winhighlight", base, { win = component.winid })
                vim.api.nvim_set_option_value("cursorline", false, { win = component.winid })
            end
        end
    end
    local branch_info = M.current.branch_info
    if branch_info and vim.api.nvim_win_is_valid(branch_info.winid) then
        vim.api.nvim_set_option_value("winhighlight", INACTIVE_WINHIGHLIGHT, { win = branch_info.winid })
        vim.api.nvim_set_option_value("cursorline", false, { win = branch_info.winid })
    end
    local diff_panels = { M.current.diff_view, M.current.diff_view_old, M.current.diff_view_new }
    for _, component in ipairs(diff_panels) do
        if component and vim.api.nvim_win_is_valid(component.winid) then
            if component.winid == current_win then
                vim.api.nvim_set_option_value("winhighlight", ACTIVE_DIFF_WINHIGHLIGHT, { win = component.winid })
                vim.api.nvim_set_option_value("cursorline", true, { win = component.winid })
            else
                vim.api.nvim_set_option_value("winhighlight", INACTIVE_WINHIGHLIGHT, { win = component.winid })
                vim.api.nvim_set_option_value("cursorline", false, { win = component.winid })
            end
        end
    end
end

---Calculate floating window positions for all panes
---@param sidebar_visible boolean
---@return table positions
local function calculate_positions(sidebar_visible)
    local columns = vim.o.columns
    local lines = vim.o.lines
    local total_height = lines - 2

    local opts = config.get()
    local sidebar_content_width = math.floor(columns * opts.ui.file_tree_width / 100)

    local positions = {}

    if sidebar_visible then
        local active_panels = get_active_sidebar_panels()
        local interactive_panels = {}
        local branch_info_def = nil

        for _, panel in ipairs(active_panels) do
            if panel.is_interactive then
                table.insert(interactive_panels, panel)
            elseif panel.name == "branch_info" then
                branch_info_def = panel
            end
        end

        local sidebar_outer_width = sidebar_content_width + 2
        local diff_content_width = columns - sidebar_outer_width - 2
        local diff_col = sidebar_outer_width

        local has_branch_info = (branch_info_def ~= nil)
        local branch_info_height = has_branch_info and 1 or 0
        local branch_info_outer_height = has_branch_info and 3 or 0

        local sidebar_border_rows = #active_panels * 2
        local available_content = total_height - sidebar_border_rows - branch_info_height

        local total_weight = 0
        for _, panel in ipairs(interactive_panels) do
            total_weight = total_weight + (panel.height_weight or 1.0)
        end

        local panel_heights = {}
        local allocated = 0
        if total_weight > 0 then
            for panel_index, panel in ipairs(interactive_panels) do
                local weight = panel.height_weight or 1.0
                local height = math.floor(available_content * weight / total_weight)
                panel_heights[panel.name] = height
                allocated = allocated + height
            end

            local remainder = available_content - allocated
            if remainder > 0 and #interactive_panels > 0 then
                local first_name = interactive_panels[1].name
                panel_heights[first_name] = panel_heights[first_name] + remainder
            end
        end

        if has_branch_info then
            positions.branch_info = {
                row = 0,
                col = 0,
                width = sidebar_content_width,
                height = 1,
            }
        end

        local current_row = branch_info_outer_height
        for _, panel in ipairs(interactive_panels) do
            local height = panel_heights[panel.name] or available_content
            positions[panel.name] = {
                row = current_row,
                col = 0,
                width = sidebar_content_width,
                height = math.max(height, 1),
            }
            current_row = current_row + height + 2
        end

        positions.diff_view = {
            row = 0,
            col = diff_col,
            width = diff_content_width,
            height = total_height - 2,
        }
    else
        positions.diff_view = {
            row = 0,
            col = 0,
            width = columns - 2,
            height = total_height - 2,
        }
    end

    return positions
end

---Apply file tree window options
---@param winid number
local function apply_tree_win_options(winid)
    vim.api.nvim_set_option_value("number", false, { win = winid })
    vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
    vim.api.nvim_set_option_value("cursorline", true, { win = winid })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = winid })
    vim.api.nvim_set_option_value("wrap", false, { win = winid })
    vim.api.nvim_set_option_value("scrollbind", false, { win = winid })
    vim.api.nvim_set_option_value("cursorbind", false, { win = winid })
    vim.api.nvim_set_option_value(
        "winhighlight",
        INACTIVE_WINHIGHLIGHT .. ",CursorLine:ReviewSelected",
        { win = winid }
    )
end

---Apply diff view window options
---@param winid number
local function apply_diff_win_options(winid)
    vim.api.nvim_set_option_value("number", true, { win = winid })
    vim.api.nvim_set_option_value("relativenumber", false, { win = winid })
    vim.api.nvim_set_option_value("cursorline", false, { win = winid })
    vim.api.nvim_set_option_value("signcolumn", "yes", { win = winid })
    vim.api.nvim_set_option_value("wrap", false, { win = winid })
    vim.api.nvim_set_option_value("scrollbind", false, { win = winid })
    vim.api.nvim_set_option_value("cursorbind", false, { win = winid })
    vim.api.nvim_set_option_value("winhighlight", INACTIVE_WINHIGHLIGHT, { win = winid })
end

---Create a scratch buffer with the given filetype
---@param filetype string
---@return number bufnr
local function create_panel_buffer(filetype)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
    vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
    vim.api.nvim_set_option_value("filetype", filetype, { buf = bufnr })
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    vim.api.nvim_set_option_value("readonly", false, { buf = bufnr })
    return bufnr
end

---Open a floating window
---@param bufnr number
---@param pos table {row, col, width, height}
---@param title string|nil
---@return number winid
local function open_float(bufnr, pos, title)
    local float_opts = {
        relative = "editor",
        row = pos.row,
        col = pos.col,
        width = math.max(pos.width, 1),
        height = math.max(pos.height, 1),
        border = "rounded",
        style = "minimal",
        focusable = true,
    }
    if title then
        float_opts.title = " " .. title .. " "
        float_opts.title_pos = "left"
    end
    return vim.api.nvim_open_win(bufnr, false, float_opts)
end

---Create the main layout with floating windows in a new tab
---@return ReviewLayout
function M.create()
    log.info("layout: creating")
    M.prev_tab = vim.api.nvim_get_current_tabpage()

    vim.cmd("tabnew")
    M.review_tab = vim.api.nvim_get_current_tabpage()

    local base_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = base_buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = base_buf })
    vim.api.nvim_set_option_value("buflisted", false, { buf = base_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = base_buf })
    local base_win = vim.api.nvim_get_current_win()
    M.base_winid = base_win

    local positions = calculate_positions(true)

    M.current = {}

    for _, panel_def in ipairs(get_active_sidebar_panels()) do
        local bufnr = create_panel_buffer(panel_def.filetype)
        local winid = open_float(bufnr, positions[panel_def.name], " " .. panel_def.title)
        apply_tree_win_options(winid)
        if not panel_def.is_interactive then
            vim.api.nvim_set_option_value("cursorline", false, { win = winid })
        end
        M.current[panel_def.name] = { bufnr = bufnr, winid = winid }
    end

    local diff_buf = create_panel_buffer("review-diff")
    local diff_win = open_float(diff_buf, positions.diff_view, nil)
    apply_diff_win_options(diff_win)
    M.current.diff_view = { bufnr = diff_buf, winid = diff_win }

    resize_autocmd_id = vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            M.reposition()
        end,
    })

    tab_closed_autocmd_id = vim.api.nvim_create_autocmd("TabClosed", {
        callback = function()
            if not M.current then
                return
            end
            if M.base_winid and vim.api.nvim_win_is_valid(M.base_winid) then
                return
            end
            log.info("layout: review tab closed externally, tearing down")
            vim.schedule(function()
                require("review.ui").close(false)
            end)
        end,
    })

    focus_autocmd_id = vim.api.nvim_create_autocmd("WinEnter", {
        callback = function()
            M.bounce_from_passive_window()
            if M.current and M.is_layout_window(vim.api.nvim_get_current_win()) then
                update_border_highlights()
            end
        end,
    })

    return M.current
end

---Reposition diff windows (unified or split) to fill the given area
---@param diff_pos table {row, col, width, height}
local function reposition_diff_windows(diff_pos)
    if M.is_split_mode() then
        local half_width = math.floor(diff_pos.width / 2)
        local old_component = M.current.diff_view_old
        local new_component = M.current.diff_view_new
        if old_component and vim.api.nvim_win_is_valid(old_component.winid) then
            vim.api.nvim_win_set_config(old_component.winid, {
                relative = "editor",
                row = diff_pos.row,
                col = diff_pos.col,
                width = math.max(half_width, 1),
                height = math.max(diff_pos.height, 1),
            })
        end
        if new_component and vim.api.nvim_win_is_valid(new_component.winid) then
            vim.api.nvim_win_set_config(new_component.winid, {
                relative = "editor",
                row = diff_pos.row,
                col = diff_pos.col + half_width + 2,
                width = math.max(diff_pos.width - half_width - 2, 1),
                height = math.max(diff_pos.height, 1),
            })
        end
    else
        local diff_component = M.current.diff_view
        if diff_component and vim.api.nvim_win_is_valid(diff_component.winid) then
            vim.api.nvim_win_set_config(diff_component.winid, {
                relative = "editor",
                row = diff_pos.row,
                col = diff_pos.col,
                width = math.max(diff_pos.width, 1),
                height = math.max(diff_pos.height, 1),
            })
        end
    end
end

---Reposition all layout windows after a resize
function M.reposition()
    if not M.current then
        return
    end

    local sidebar_visible = M.is_file_tree_visible()
    local positions = calculate_positions(sidebar_visible)
    log.debug("layout: reposition", vim.o.columns .. "x" .. vim.o.lines, "sidebar=" .. tostring(sidebar_visible))

    if sidebar_visible then
        for _, panel_def in ipairs(get_active_sidebar_panels()) do
            local component = M.current[panel_def.name]
            local pos = positions[panel_def.name]
            if component and pos and vim.api.nvim_win_is_valid(component.winid) then
                vim.api.nvim_win_set_config(component.winid, {
                    relative = "editor",
                    row = pos.row,
                    col = pos.col,
                    width = math.max(pos.width, 1),
                    height = math.max(pos.height, 1),
                    title = " " .. panel_def.title .. " ",
                    title_pos = "left",
                })
            end
        end
    end

    reposition_diff_windows(positions.diff_view)
end

---Check if a window is part of the layout but has no keymaps to escape from
---@param winid number
---@return boolean
function M.is_passive_window(winid)
    if winid == M.base_winid then
        return true
    end
    local branch_info = M.current and M.current.branch_info
    return branch_info ~= nil and branch_info.winid == winid
end

---Move focus off a passive layout window onto the next usable one
function M.bounce_from_passive_window()
    if not M.current then
        return
    end

    local current = vim.api.nvim_get_current_win()
    if not M.is_passive_window(current) then
        return
    end

    local wins = vim.api.nvim_tabpage_list_wins(0)
    local start_index = 1
    for index, winid in ipairs(wins) do
        if winid == current then
            start_index = index
            break
        end
    end

    for offset = 1, #wins do
        local candidate = wins[((start_index - 1 + offset) % #wins) + 1]
        if
            not M.is_passive_window(candidate)
            and vim.api.nvim_win_is_valid(candidate)
            and M.is_layout_window(candidate)
        then
            log.debug("layout: bouncing focus off passive window", current, "to", candidate)
            vim.api.nvim_set_current_win(candidate)
            return
        end
    end
end

---Check if a window belongs to the layout
---@param winid number
---@return boolean
function M.is_layout_window(winid)
    if winid == M.base_winid then
        return true
    end
    if not M.current then
        return false
    end
    local component_names = { "diff_view", "diff_view_old", "diff_view_new" }
    for _, panel_def in ipairs(get_active_sidebar_panels()) do
        table.insert(component_names, panel_def.name)
    end
    for _, name in ipairs(component_names) do
        local component = M.current[name]
        if component and component.winid == winid then
            return true
        end
    end
    return false
end

---Check if file tree is currently visible
---@return boolean
function M.is_file_tree_visible()
    if not M.current then
        return false
    end
    return vim.api.nvim_win_is_valid(M.current.file_tree.winid)
end

---Hide the file tree panel (and commit list and branch list)
function M.hide_file_tree()
    if not M.current then
        return
    end

    local focus_win = M.current.diff_view.winid
    if M.is_split_mode() then
        local new_component = M.current.diff_view_new
        if new_component and vim.api.nvim_win_is_valid(new_component.winid) then
            focus_win = new_component.winid
        end
    end
    if vim.api.nvim_win_is_valid(focus_win) then
        vim.api.nvim_set_current_win(focus_win)
    end

    for _, panel_def in ipairs(get_active_sidebar_panels()) do
        local name = panel_def.name
        local component = M.current[name]
        if component and vim.api.nvim_win_is_valid(component.winid) then
            vim.api.nvim_win_close(component.winid, true)
        end
    end

    local positions = calculate_positions(false)
    reposition_diff_windows(positions.diff_view)
end

---Show the file tree panel (re-open the windows with existing buffers)
function M.show_file_tree()
    if not M.current then
        return
    end

    local tree = M.current.file_tree
    if vim.api.nvim_win_is_valid(tree.winid) then
        return
    end

    local positions = calculate_positions(true)

    for _, panel_def in ipairs(get_active_sidebar_panels()) do
        local component = M.current[panel_def.name]
        local pos = positions[panel_def.name]
        if component and pos then
            local winid = open_float(component.bufnr, pos, " " .. panel_def.title)
            apply_tree_win_options(winid)
            if not panel_def.is_interactive then
                vim.api.nvim_set_option_value("cursorline", false, { win = winid })
            end
            component.winid = winid
            if panel_def.name == "file_tree" then
                require("review.ui.file_tree").set_winid(winid)
            elseif PANEL_MODULES[panel_def.name] then
                local panel_module = require(PANEL_MODULES[panel_def.name])
                if panel_module.current then
                    panel_module.current.winid = winid
                end
            end
        end
    end

    reposition_diff_windows(positions.diff_view)
end

---Toggle the file tree panel visibility
function M.toggle_file_tree()
    if M.is_file_tree_visible() then
        M.hide_file_tree()
    else
        M.show_file_tree()
    end
end

---Enter split (side-by-side) diff mode
function M.enter_split_mode()
    if not M.current then
        return
    end

    if M.is_split_mode() then
        return
    end

    local stale_old = M.current.diff_view_old
    if stale_old then
        M.current.diff_view_old = nil
        M.current.diff_view_new = nil
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(stale_old.bufnr) then
                vim.api.nvim_buf_delete(stale_old.bufnr, { force = true })
            end
        end)
    end

    local diff_win = M.current.diff_view.winid

    local prev_win = vim.api.nvim_get_current_win()

    if vim.api.nvim_win_is_valid(diff_win) then
        vim.api.nvim_win_close(diff_win, true)
    end

    local sidebar_visible = M.is_file_tree_visible()
    local positions = calculate_positions(sidebar_visible)
    local diff_pos = positions.diff_view

    local half_width = math.floor(diff_pos.width / 2)

    local old_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = old_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = old_buf })
    vim.api.nvim_set_option_value("modifiable", true, { buf = old_buf })
    vim.api.nvim_set_option_value("readonly", false, { buf = old_buf })

    local old_pos = {
        row = diff_pos.row,
        col = diff_pos.col,
        width = half_width,
        height = diff_pos.height,
    }
    local old_win = open_float(old_buf, old_pos, nil)
    apply_diff_win_options(old_win)

    local new_pos = {
        row = diff_pos.row,
        col = diff_pos.col + half_width + 2,
        width = diff_pos.width - half_width - 2,
        height = diff_pos.height,
    }
    local new_win = open_float(M.current.diff_view.bufnr, new_pos, nil)
    apply_diff_win_options(new_win)

    vim.api.nvim_set_option_value("scrollbind", true, { win = old_win })
    vim.api.nvim_set_option_value("cursorbind", true, { win = old_win })
    vim.api.nvim_set_option_value("scrollbind", true, { win = new_win })
    vim.api.nvim_set_option_value("cursorbind", true, { win = new_win })

    M.current.diff_view.winid = new_win
    M.current.diff_view_old = { bufnr = old_buf, winid = old_win }
    M.current.diff_view_new = { bufnr = M.current.diff_view.bufnr, winid = new_win }

    if vim.api.nvim_win_is_valid(prev_win) and prev_win ~= diff_win then
        vim.api.nvim_set_current_win(prev_win)
    else
        vim.api.nvim_set_current_win(new_win)
    end
end

---Exit split (side-by-side) diff mode
function M.exit_split_mode()
    if not M.current then
        return
    end

    if not M.is_split_mode() then
        return
    end

    local old_component = M.current.diff_view_old
    local new_component = M.current.diff_view_new

    local prev_win = vim.api.nvim_get_current_win()
    local was_focused = (old_component and prev_win == old_component.winid)
        or (new_component and prev_win == new_component.winid)

    if new_component and vim.api.nvim_win_is_valid(new_component.winid) then
        vim.api.nvim_set_option_value("scrollbind", false, { win = new_component.winid })
        vim.api.nvim_set_option_value("cursorbind", false, { win = new_component.winid })
        vim.api.nvim_win_close(new_component.winid, true)
    end

    if old_component then
        if vim.api.nvim_win_is_valid(old_component.winid) then
            vim.api.nvim_win_close(old_component.winid, true)
        end
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(old_component.bufnr) then
                vim.api.nvim_buf_delete(old_component.bufnr, { force = true })
            end
        end)
    end

    local sidebar_visible = M.is_file_tree_visible()
    local positions = calculate_positions(sidebar_visible)
    local diff_pos = positions.diff_view

    local diff_win = open_float(M.current.diff_view.bufnr, diff_pos, nil)
    apply_diff_win_options(diff_win)

    M.current.diff_view.winid = diff_win
    M.current.diff_view_old = nil
    M.current.diff_view_new = nil

    if was_focused or not vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(diff_win)
    end
end

---Check if currently in split mode
---@return boolean
function M.is_split_mode()
    if not M.current or not M.current.diff_view_old then
        return false
    end
    return vim.api.nvim_win_is_valid(M.current.diff_view_old.winid)
end

---Get the old-side diff view component
---@return ReviewLayoutComponent|nil
function M.get_diff_view_old()
    return M.current and M.current.diff_view_old
end

---Get the new-side diff view component
---@return ReviewLayoutComponent|nil
function M.get_diff_view_new()
    return M.current and M.current.diff_view_new
end

---Mount the layout (no-op, create() does everything)
function M.mount() end

---Unmount the layout
function M.unmount()
    log.info("layout: unmounting")
    if M.current then
        if M.is_split_mode() then
            M.exit_split_mode()
        end

        if resize_autocmd_id then
            vim.api.nvim_del_autocmd(resize_autocmd_id)
            resize_autocmd_id = nil
        end

        if focus_autocmd_id then
            vim.api.nvim_del_autocmd(focus_autocmd_id)
            focus_autocmd_id = nil
        end

        if tab_closed_autocmd_id then
            pcall(vim.api.nvim_del_autocmd, tab_closed_autocmd_id)
            tab_closed_autocmd_id = nil
        end

        local prev_tab = M.prev_tab
        local review_tab = M.review_tab

        local float_wins = {}
        local panel_buffers = {}
        for _, panel_def in ipairs(get_active_sidebar_panels()) do
            local component = M.current[panel_def.name]
            if component then
                if vim.api.nvim_win_is_valid(component.winid) then
                    table.insert(float_wins, component.winid)
                end
                table.insert(panel_buffers, component.bufnr)
            end
        end
        local diff_component = M.current.diff_view
        if diff_component then
            if vim.api.nvim_win_is_valid(diff_component.winid) then
                table.insert(float_wins, diff_component.winid)
            end
            table.insert(panel_buffers, diff_component.bufnr)
        end

        M.current = nil
        M.prev_tab = nil
        M.review_tab = nil

        for _, winid in ipairs(float_wins) do
            pcall(vim.api.nvim_win_close, winid, true)
        end

        if review_tab and vim.api.nvim_tabpage_is_valid(review_tab) then
            pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(review_tab))
        end

        if prev_tab and vim.api.nvim_tabpage_is_valid(prev_tab) then
            vim.api.nvim_set_current_tabpage(prev_tab)
        end

        M.base_winid = nil

        vim.schedule(function()
            for _, bufnr in ipairs(panel_buffers) do
                pcall(function()
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        vim.api.nvim_buf_delete(bufnr, { force = true })
                    end
                end)
            end
        end)
    end
end

---Check if layout is mounted
---@return boolean
function M.is_mounted()
    return M.current ~= nil
end

---Get a layout component by name
---@param name string
---@return ReviewLayoutComponent|nil
function M.get_component(name)
    return M.current and M.current[name]
end

---@return ReviewLayoutComponent|nil
function M.get_branch_info()
    return M.get_component("branch_info")
end

---@return ReviewLayoutComponent|nil
function M.get_file_tree()
    return M.get_component("file_tree")
end

---@return ReviewLayoutComponent|nil
function M.get_commit_list()
    return M.get_component("commit_list")
end

---@return ReviewLayoutComponent|nil
function M.get_branch_list()
    return M.get_component("branch_list")
end

---@return ReviewLayoutComponent|nil
function M.get_comment_list()
    return M.get_component("comment_list")
end

---@return ReviewLayoutComponent|nil
function M.get_diff_view()
    return M.get_component("diff_view")
end

return M
