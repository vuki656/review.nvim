local config = require("review.config")
local log = require("review.core.log")

local M = {}

---@class ReviewLayoutComponent
---@field bufnr number
---@field winid number

---@class ReviewLayout
---@field file_tree ReviewLayoutComponent
---@field commit_list ReviewLayoutComponent
---@field branch_list ReviewLayoutComponent
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

local SIDEBAR_PANEL_COUNT = 3
local SIDEBAR_BORDER_ROWS = SIDEBAR_PANEL_COUNT * 2

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
    local sidebar_panels = { M.current.file_tree, M.current.commit_list, M.current.branch_list }
    for _, component in ipairs(sidebar_panels) do
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

        local available_content = total_height - SIDEBAR_BORDER_ROWS
        local panel_height = math.floor(available_content / SIDEBAR_PANEL_COUNT)
        local remainder = available_content - (panel_height * SIDEBAR_PANEL_COUNT)

        local file_tree_height = panel_height + remainder
        local commit_height = panel_height
        local branch_height = panel_height

        local file_tree_outer = file_tree_height + 2
        local commit_outer = commit_height + 2

        positions.file_tree = {
            row = 0,
            col = 0,
            width = sidebar_content_width,
            height = file_tree_height,
        }

        positions.commit_list = {
            row = file_tree_outer,
            col = 0,
            width = sidebar_content_width,
            height = commit_height,
        }

        positions.branch_list = {
            row = file_tree_outer + commit_outer,
            col = 0,
            width = sidebar_content_width,
            height = branch_height,
        }

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

    local tree_buf = create_panel_buffer("review-tree")
    local commit_list_buf = create_panel_buffer("review-commits")
    local branch_list_buf = create_panel_buffer("review-branches")
    local diff_buf = create_panel_buffer("review-diff")

    local positions = calculate_positions(true)

    local tree_win = open_float(tree_buf, positions.file_tree, " Files")
    apply_tree_win_options(tree_win)

    local commit_list_win = open_float(commit_list_buf, positions.commit_list, " Commits")
    apply_tree_win_options(commit_list_win)

    local branch_list_win = open_float(branch_list_buf, positions.branch_list, " Branches")
    apply_tree_win_options(branch_list_win)

    local diff_win = open_float(diff_buf, positions.diff_view, nil)
    apply_diff_win_options(diff_win)

    M.current = {
        file_tree = { bufnr = tree_buf, winid = tree_win },
        commit_list = { bufnr = commit_list_buf, winid = commit_list_win },
        branch_list = { bufnr = branch_list_buf, winid = branch_list_win },
        diff_view = { bufnr = diff_buf, winid = diff_win },
    }

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
        local panels = {
            { component = M.current.file_tree, pos = positions.file_tree, title = " Files" },
            { component = M.current.commit_list, pos = positions.commit_list, title = " Commits" },
            { component = M.current.branch_list, pos = positions.branch_list, title = " Branches" },
        }
        for _, panel in ipairs(panels) do
            if panel.component and vim.api.nvim_win_is_valid(panel.component.winid) then
                vim.api.nvim_win_set_config(panel.component.winid, {
                    relative = "editor",
                    row = panel.pos.row,
                    col = panel.pos.col,
                    width = math.max(panel.pos.width, 1),
                    height = math.max(panel.pos.height, 1),
                    title = " " .. panel.title .. " ",
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
    local components = { "file_tree", "commit_list", "branch_list", "diff_view", "diff_view_old", "diff_view_new" }
    for _, name in ipairs(components) do
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

    local sidebar_panels = { "branch_list", "commit_list", "file_tree" }
    for _, name in ipairs(sidebar_panels) do
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

    local tree_win = open_float(tree.bufnr, positions.file_tree, " Files")
    apply_tree_win_options(tree_win)
    M.current.file_tree.winid = tree_win

    local commit_list = M.current.commit_list
    if commit_list then
        local commit_win = open_float(commit_list.bufnr, positions.commit_list, " Commits")
        apply_tree_win_options(commit_win)
        M.current.commit_list.winid = commit_win
    end

    local branch_list = M.current.branch_list
    if branch_list then
        local branch_win = open_float(branch_list.bufnr, positions.branch_list, " Branches")
        apply_tree_win_options(branch_win)
        M.current.branch_list.winid = branch_win
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

        local tree_buf = M.current.file_tree.bufnr
        local commit_list_buf = M.current.commit_list and M.current.commit_list.bufnr
        local branch_list_buf = M.current.branch_list and M.current.branch_list.bufnr
        local diff_buf = M.current.diff_view.bufnr
        local prev_tab = M.prev_tab

        local float_wins = {}
        local components = { "file_tree", "commit_list", "branch_list", "diff_view" }
        for _, name in ipairs(components) do
            local component = M.current[name]
            if component and vim.api.nvim_win_is_valid(component.winid) then
                table.insert(float_wins, component.winid)
            end
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
            pcall(function()
                if vim.api.nvim_buf_is_valid(tree_buf) then
                    vim.api.nvim_buf_delete(tree_buf, { force = true })
                end
            end)
            pcall(function()
                if commit_list_buf and vim.api.nvim_buf_is_valid(commit_list_buf) then
                    vim.api.nvim_buf_delete(commit_list_buf, { force = true })
                end
            end)
            pcall(function()
                if branch_list_buf and vim.api.nvim_buf_is_valid(branch_list_buf) then
                    vim.api.nvim_buf_delete(branch_list_buf, { force = true })
                end
            end)
            pcall(function()
                if vim.api.nvim_buf_is_valid(diff_buf) then
                    vim.api.nvim_buf_delete(diff_buf, { force = true })
                end
            end)
        end)
    end
end

---Check if layout is mounted
---@return boolean
function M.is_mounted()
    return M.current ~= nil
end

---Get the file tree component
---@return ReviewLayoutComponent|nil
function M.get_file_tree()
    return M.current and M.current.file_tree
end

---Get the commit list component
---@return ReviewLayoutComponent|nil
function M.get_commit_list()
    return M.current and M.current.commit_list
end

---Get the branch list component
---@return ReviewLayoutComponent|nil
function M.get_branch_list()
    return M.current and M.current.branch_list
end

---Get the diff view component
---@return ReviewLayoutComponent|nil
function M.get_diff_view()
    return M.current and M.current.diff_view
end

return M
