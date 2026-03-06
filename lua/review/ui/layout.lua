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
M.base_winid = nil

---@type number|nil
local resize_autocmd_id = nil

---@class SidebarPanelDef
---@field name string Key in ReviewLayout
---@field title string Display title for float border
---@field filetype string Buffer filetype
---@field is_interactive boolean Whether this panel gets cursorline/active highlight
---@field height_weight number|nil Weight for height calculation (default 1.0)

local SIDEBAR_PANELS = {
    { name = "branch_info", title = "Branch", filetype = "review-branch-info", is_interactive = false },
    { name = "file_tree", title = "Files", filetype = "review-tree", is_interactive = true },
    { name = "branch_list", title = "Branches", filetype = "review-branches", is_interactive = true },
    { name = "commit_list", title = "Commits", filetype = "review-commits", is_interactive = true },
    {
        name = "comment_list", title = "Comments", filetype = "review-comments",
        is_interactive = true, height_weight = 0.5,
    },
}

local INTERACTIVE_SIDEBAR_PANELS = {}
for _, panel in ipairs(SIDEBAR_PANELS) do
    if panel.is_interactive then
        table.insert(INTERACTIVE_SIDEBAR_PANELS, panel)
    end
end

local SIDEBAR_PANEL_COUNT = #INTERACTIVE_SIDEBAR_PANELS
local BRANCH_INFO_HEIGHT = 1
local BRANCH_INFO_OUTER_HEIGHT = BRANCH_INFO_HEIGHT + 2
local SIDEBAR_BORDER_ROWS = (SIDEBAR_PANEL_COUNT + 1) * 2

---@type number|nil
local focus_autocmd_id = nil

local INACTIVE_WINHIGHLIGHT = "NormalFloat:Normal,FloatBorder:ReviewFloatBorder,FloatTitle:ReviewFloatTitle"
local ACTIVE_SIDEBAR_WINHIGHLIGHT = "NormalFloat:Normal,FloatBorder:ReviewFloatBorderActive,"
    .. "FloatTitle:ReviewFloatTitleActive,CursorLine:ReviewSelected"
local ACTIVE_DIFF_WINHIGHLIGHT = "NormalFloat:Normal,FloatBorder:ReviewFloatBorderActive,"
    .. "FloatTitle:ReviewFloatTitleActive"

---Update border highlights based on the currently focused window
local function update_border_highlights()
    if not M.current then
        return
    end
    local current_win = vim.api.nvim_get_current_win()
    for _, panel_def in ipairs(INTERACTIVE_SIDEBAR_PANELS) do
        local component = M.current[panel_def.name]
        if component and vim.api.nvim_win_is_valid(component.winid) then
            if component.winid == current_win then
                vim.wo[component.winid].winhighlight = ACTIVE_SIDEBAR_WINHIGHLIGHT
                vim.wo[component.winid].cursorline = true
            else
                local base = INACTIVE_WINHIGHLIGHT .. ",CursorLine:ReviewSelected"
                vim.wo[component.winid].winhighlight = base
                vim.wo[component.winid].cursorline = false
            end
        end
    end
    local branch_info = M.current.branch_info
    if branch_info and vim.api.nvim_win_is_valid(branch_info.winid) then
        vim.wo[branch_info.winid].winhighlight = INACTIVE_WINHIGHLIGHT
        vim.wo[branch_info.winid].cursorline = false
    end
    local diff_panels = { M.current.diff_view, M.current.diff_view_old, M.current.diff_view_new }
    for _, component in ipairs(diff_panels) do
        if component and vim.api.nvim_win_is_valid(component.winid) then
            if component.winid == current_win then
                vim.wo[component.winid].winhighlight = ACTIVE_DIFF_WINHIGHLIGHT
            else
                vim.wo[component.winid].winhighlight = INACTIVE_WINHIGHLIGHT
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
        local sidebar_outer_width = sidebar_content_width + 2
        local diff_content_width = columns - sidebar_outer_width - 2
        local diff_col = sidebar_outer_width

        local available_content = total_height - SIDEBAR_BORDER_ROWS - BRANCH_INFO_HEIGHT

        local total_weight = 0
        for _, panel in ipairs(INTERACTIVE_SIDEBAR_PANELS) do
            total_weight = total_weight + (panel.height_weight or 1.0)
        end

        local panel_heights = {}
        local allocated = 0
        for panel_index, panel in ipairs(INTERACTIVE_SIDEBAR_PANELS) do
            local weight = panel.height_weight or 1.0
            local height
            if panel_index == 1 then
                local base = math.floor(available_content * weight / total_weight)
                height = base
            else
                height = math.floor(available_content * weight / total_weight)
            end
            panel_heights[panel.name] = height
            allocated = allocated + height
        end

        local remainder = available_content - allocated
        if remainder > 0 then
            panel_heights[INTERACTIVE_SIDEBAR_PANELS[1].name] = panel_heights[INTERACTIVE_SIDEBAR_PANELS[1].name]
                + remainder
        end

        positions.branch_info = {
            row = 0,
            col = 0,
            width = sidebar_content_width,
            height = BRANCH_INFO_HEIGHT,
        }

        local current_row = BRANCH_INFO_OUTER_HEIGHT
        for _, panel in ipairs(INTERACTIVE_SIDEBAR_PANELS) do
            local height = panel_heights[panel.name]
            positions[panel.name] = {
                row = current_row,
                col = 0,
                width = sidebar_content_width,
                height = height,
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
    vim.api.nvim_win_set_option(winid, "number", false)
    vim.api.nvim_win_set_option(winid, "relativenumber", false)
    vim.api.nvim_win_set_option(winid, "cursorline", true)
    vim.api.nvim_win_set_option(winid, "signcolumn", "no")
    vim.api.nvim_win_set_option(winid, "wrap", false)
    vim.wo[winid].winhighlight = INACTIVE_WINHIGHLIGHT .. ",CursorLine:ReviewSelected"
end

---Apply diff view window options
---@param winid number
local function apply_diff_win_options(winid)
    vim.api.nvim_win_set_option(winid, "number", true)
    vim.api.nvim_win_set_option(winid, "relativenumber", false)
    vim.api.nvim_win_set_option(winid, "cursorline", false)
    vim.api.nvim_win_set_option(winid, "signcolumn", "yes")
    vim.api.nvim_win_set_option(winid, "wrap", false)
    vim.wo[winid].winhighlight = INACTIVE_WINHIGHLIGHT
end

---Create a scratch buffer with the given filetype
---@param filetype string
---@return number bufnr
local function create_panel_buffer(filetype)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = filetype
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].readonly = false
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

    local base_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[base_buf].buftype = "nofile"
    local base_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(base_win, base_buf)
    M.base_winid = base_win

    local positions = calculate_positions(true)

    M.current = {}

    for _, panel_def in ipairs(SIDEBAR_PANELS) do
        local bufnr = create_panel_buffer(panel_def.filetype)
        local winid = open_float(bufnr, positions[panel_def.name], " " .. panel_def.title)
        apply_tree_win_options(winid)
        if not panel_def.is_interactive then
            vim.wo[winid].cursorline = false
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

    focus_autocmd_id = vim.api.nvim_create_autocmd("WinEnter", {
        callback = function()
            if M.current and M.is_layout_window(vim.api.nvim_get_current_win()) then
                update_border_highlights()
            end
        end,
    })

    return M.current
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
        for _, panel_def in ipairs(SIDEBAR_PANELS) do
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

    if M.is_split_mode() then
        local diff_pos = positions.diff_view
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
            local diff_pos = positions.diff_view
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
    for _, panel_def in ipairs(SIDEBAR_PANELS) do
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

    local diff_win = M.current.diff_view.winid
    if vim.api.nvim_win_is_valid(diff_win) then
        vim.api.nvim_set_current_win(diff_win)
    end

    for _, panel_def in ipairs(SIDEBAR_PANELS) do
        local name = panel_def.name
        local component = M.current[name]
        if component and vim.api.nvim_win_is_valid(component.winid) then
            vim.api.nvim_win_close(component.winid, true)
        end
    end

    local positions = calculate_positions(false)
    local diff_pos = positions.diff_view
    if vim.api.nvim_win_is_valid(diff_win) then
        vim.api.nvim_win_set_config(diff_win, {
            relative = "editor",
            row = diff_pos.row,
            col = diff_pos.col,
            width = math.max(diff_pos.width, 1),
            height = math.max(diff_pos.height, 1),
        })
    end
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

    for _, panel_def in ipairs(SIDEBAR_PANELS) do
        local component = M.current[panel_def.name]
        local pos = positions[panel_def.name]
        if component and pos then
            local winid = open_float(component.bufnr, pos, " " .. panel_def.title)
            apply_tree_win_options(winid)
            if not panel_def.is_interactive then
                vim.wo[winid].cursorline = false
            end
            component.winid = winid
        end
    end

    local diff_pos = positions.diff_view
    local diff_win = M.current.diff_view.winid
    if vim.api.nvim_win_is_valid(diff_win) then
        vim.api.nvim_win_set_config(diff_win, {
            relative = "editor",
            row = diff_pos.row,
            col = diff_pos.col,
            width = math.max(diff_pos.width, 1),
            height = math.max(diff_pos.height, 1),
        })
    end
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

    local diff_win = M.current.diff_view.winid
    if not vim.api.nvim_win_is_valid(diff_win) then
        return
    end

    local prev_win = vim.api.nvim_get_current_win()

    vim.api.nvim_win_close(diff_win, true)

    local sidebar_visible = M.is_file_tree_visible()
    local positions = calculate_positions(sidebar_visible)
    local diff_pos = positions.diff_view

    local half_width = math.floor(diff_pos.width / 2)

    local old_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[old_buf].buftype = "nofile"
    vim.bo[old_buf].swapfile = false
    vim.bo[old_buf].modifiable = true
    vim.bo[old_buf].readonly = false

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

    vim.wo[old_win].scrollbind = true
    vim.wo[old_win].cursorbind = true
    vim.wo[new_win].scrollbind = true
    vim.wo[new_win].cursorbind = true

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

    if new_component and vim.api.nvim_win_is_valid(new_component.winid) then
        vim.wo[new_component.winid].scrollbind = false
        vim.wo[new_component.winid].cursorbind = false
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
function M.mount()
end

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

        local prev_tab = M.prev_tab

        local float_wins = {}
        local panel_buffers = {}
        for _, panel_def in ipairs(SIDEBAR_PANELS) do
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

        for _, winid in ipairs(float_wins) do
            pcall(vim.api.nvim_win_close, winid, true)
        end

        pcall(function()
            vim.cmd("tabclose")
        end)

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
