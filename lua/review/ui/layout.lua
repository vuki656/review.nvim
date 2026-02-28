local config = require("review.config")

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

---Apply file tree window options
---@param winid number
local function apply_tree_win_options(winid)
    vim.api.nvim_win_set_option(winid, "number", false)
    vim.api.nvim_win_set_option(winid, "relativenumber", false)
    vim.api.nvim_win_set_option(winid, "cursorline", true)
    vim.api.nvim_win_set_option(winid, "signcolumn", "no")
    vim.api.nvim_win_set_option(winid, "wrap", false)
    vim.api.nvim_win_set_option(
        winid,
        "winhighlight",
        "Normal:Normal,CursorLine:ReviewSelected,WinBar:ReviewWinBar,WinBarNC:ReviewWinBar,WinSeparator:ReviewWinSeparator"
    )
    vim.api.nvim_win_set_option(winid, "winfixwidth", true)
    vim.wo[winid].fillchars = "horiz:─,horizup:┴,horizdown:┬,vert:│,vertleft:┤,vertright:├,verthoriz:┼"
end

---Create the main layout with file tree and diff view in a new tab
---@return ReviewLayout
function M.create()
    local opts = config.get()
    local file_tree_width = opts.ui.file_tree_width

    -- Save current tab
    M.prev_tab = vim.api.nvim_get_current_tabpage()

    -- Create new tab
    vim.cmd("tabnew")

    -- Create buffers for file tree, commit list, branch list, and diff view
    local tree_buf = vim.api.nvim_create_buf(false, true)
    local commit_list_buf = vim.api.nvim_create_buf(false, true)
    local branch_list_buf = vim.api.nvim_create_buf(false, true)
    local diff_buf = vim.api.nvim_create_buf(false, true)

    -- Set buffer options for file tree
    vim.bo[tree_buf].buftype = "nofile"
    vim.bo[tree_buf].swapfile = false
    vim.bo[tree_buf].filetype = "review-tree"
    vim.bo[tree_buf].modifiable = true
    vim.bo[tree_buf].readonly = false

    -- Set buffer options for commit list
    vim.bo[commit_list_buf].buftype = "nofile"
    vim.bo[commit_list_buf].swapfile = false
    vim.bo[commit_list_buf].filetype = "review-commits"
    vim.bo[commit_list_buf].modifiable = true
    vim.bo[commit_list_buf].readonly = false

    -- Set buffer options for branch list
    vim.bo[branch_list_buf].buftype = "nofile"
    vim.bo[branch_list_buf].swapfile = false
    vim.bo[branch_list_buf].filetype = "review-branches"
    vim.bo[branch_list_buf].modifiable = true
    vim.bo[branch_list_buf].readonly = false

    -- Set buffer options for diff view
    vim.bo[diff_buf].buftype = "nofile"
    vim.bo[diff_buf].swapfile = false
    vim.bo[diff_buf].filetype = "review-diff"
    vim.bo[diff_buf].modifiable = true
    vim.bo[diff_buf].readonly = false

    -- Current window becomes diff view
    vim.api.nvim_win_set_buf(0, diff_buf)
    local diff_win = vim.api.nvim_get_current_win()

    -- Set diff view window options
    vim.api.nvim_win_set_option(diff_win, "number", true)
    vim.api.nvim_win_set_option(diff_win, "relativenumber", false)
    vim.api.nvim_win_set_option(diff_win, "cursorline", true)
    vim.api.nvim_win_set_option(diff_win, "signcolumn", "yes")
    vim.api.nvim_win_set_option(diff_win, "wrap", false)
    vim.api.nvim_win_set_option(diff_win, "winhighlight", "Normal:Normal,CursorLine:ReviewSelected")

    -- Create vertical split on left for file tree
    local width = math.floor(vim.o.columns * file_tree_width / 100)
    vim.cmd("topleft " .. width .. "vsplit")
    vim.api.nvim_win_set_buf(0, tree_buf)
    local tree_win = vim.api.nvim_get_current_win()

    -- Set file tree window options
    apply_tree_win_options(tree_win)

    -- Create horizontal split below tree for commit list
    local saved_ea = vim.o.equalalways
    vim.o.equalalways = false
    vim.api.nvim_set_current_win(tree_win)
    vim.cmd("belowright split")
    vim.api.nvim_win_set_buf(0, commit_list_buf)
    local commit_list_win = vim.api.nvim_get_current_win()

    local commit_list_height = 15
    vim.api.nvim_win_set_height(commit_list_win, commit_list_height)

    -- Apply window options (same as tree)
    apply_tree_win_options(commit_list_win)

    -- Create horizontal split below commit list for branch list
    vim.api.nvim_set_current_win(commit_list_win)
    vim.cmd("belowright split")
    vim.api.nvim_win_set_buf(0, branch_list_buf)
    local branch_list_win = vim.api.nvim_get_current_win()

    -- Set branch list window height
    local branch_list_height = 10
    vim.api.nvim_win_set_height(branch_list_win, branch_list_height)

    -- Apply window options (same as tree)
    apply_tree_win_options(branch_list_win)

    vim.o.equalalways = saved_ea

    vim.wo[tree_win].winbar = "%#ReviewWinBar#  Files%*"
    vim.wo[commit_list_win].winbar = "%#ReviewWinBar#  Commits%*"
    vim.wo[branch_list_win].winbar = "%#ReviewWinBar#  Branches%*"

    M.current = {
        file_tree = { bufnr = tree_buf, winid = tree_win },
        commit_list = { bufnr = commit_list_buf, winid = commit_list_win },
        branch_list = { bufnr = branch_list_buf, winid = branch_list_win },
        diff_view = { bufnr = diff_buf, winid = diff_win },
    }

    return M.current
end

---Check if file tree is currently visible
---@return boolean
function M.is_file_tree_visible()
    if not M.current then
        return false
    end
    return vim.api.nvim_win_is_valid(M.current.file_tree.winid)
end

---Hide the file tree panel (and commit list)
function M.hide_file_tree()
    if not M.current then
        return
    end

    -- Focus diff view before closing windows
    local diff_win = M.current.diff_view.winid
    if vim.api.nvim_win_is_valid(diff_win) then
        vim.api.nvim_set_current_win(diff_win)
    end

    -- Close branch list window
    local branch_list = M.current.branch_list
    if branch_list and vim.api.nvim_win_is_valid(branch_list.winid) then
        vim.api.nvim_win_close(branch_list.winid, true)
    end

    -- Close commit list window
    local commit_list = M.current.commit_list
    if commit_list and vim.api.nvim_win_is_valid(commit_list.winid) then
        vim.api.nvim_win_close(commit_list.winid, true)
    end

    -- Close tree window
    local tree = M.current.file_tree
    if vim.api.nvim_win_is_valid(tree.winid) then
        vim.api.nvim_win_close(tree.winid, true)
    end
end

---Show the file tree panel (re-open the window with the existing buffer)
function M.show_file_tree()
    if not M.current then
        return
    end

    local tree = M.current.file_tree

    -- Already visible
    if vim.api.nvim_win_is_valid(tree.winid) then
        return
    end

    local saved_ea = vim.o.equalalways
    vim.o.equalalways = false

    local opts = config.get()
    local width = math.floor(vim.o.columns * opts.ui.file_tree_width / 100)

    -- Open split on the left
    vim.cmd("topleft " .. width .. "vsplit")
    vim.api.nvim_win_set_buf(0, tree.bufnr)
    local new_win = vim.api.nvim_get_current_win()

    -- Update stored winid
    M.current.file_tree.winid = new_win

    -- Reapply window options
    apply_tree_win_options(new_win)

    -- Disable spell check
    vim.wo[new_win].spell = false
    vim.wo[new_win].winbar = "%#ReviewWinBar#  Files%*"

    -- Re-open commit list below tree
    local commit_list = M.current.commit_list
    if commit_list and not vim.api.nvim_win_is_valid(commit_list.winid) then
        vim.api.nvim_set_current_win(new_win)
        vim.cmd("belowright split")
        vim.api.nvim_win_set_buf(0, commit_list.bufnr)
        local commit_list_win = vim.api.nvim_get_current_win()

        local commit_list_height = 15
        vim.api.nvim_win_set_height(commit_list_win, commit_list_height)

        apply_tree_win_options(commit_list_win)
        vim.wo[commit_list_win].winbar = "%#ReviewWinBar#  Commits%*"
        M.current.commit_list.winid = commit_list_win

        -- Re-open branch list below commit list
        local branch_list = M.current.branch_list
        if branch_list and not vim.api.nvim_win_is_valid(branch_list.winid) then
            vim.api.nvim_set_current_win(commit_list_win)
            vim.cmd("belowright split")
            vim.api.nvim_win_set_buf(0, branch_list.bufnr)
            local branch_list_win = vim.api.nvim_get_current_win()

            local branch_list_height = 10
            vim.api.nvim_win_set_height(branch_list_win, branch_list_height)

            apply_tree_win_options(branch_list_win)
            vim.wo[branch_list_win].winbar = "%#ReviewWinBar#  Branches%*"
            M.current.branch_list.winid = branch_list_win
        end
    end

    vim.o.equalalways = saved_ea
end

---Toggle the file tree panel visibility
function M.toggle_file_tree()
    if M.is_file_tree_visible() then
        M.hide_file_tree()
    else
        M.show_file_tree()
    end
end

---Apply diff view window options
---@param winid number
local function apply_diff_win_options(winid)
    vim.api.nvim_win_set_option(winid, "number", true)
    vim.api.nvim_win_set_option(winid, "relativenumber", false)
    vim.api.nvim_win_set_option(winid, "cursorline", true)
    vim.api.nvim_win_set_option(winid, "signcolumn", "yes")
    vim.api.nvim_win_set_option(winid, "wrap", false)
    vim.api.nvim_win_set_option(winid, "winhighlight", "Normal:Normal,CursorLine:ReviewSelected")
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
    local saved_ea = vim.o.equalalways
    vim.o.equalalways = false

    vim.api.nvim_set_current_win(diff_win)

    local old_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[old_buf].buftype = "nofile"
    vim.bo[old_buf].swapfile = false
    vim.bo[old_buf].modifiable = true
    vim.bo[old_buf].readonly = false

    vim.cmd("vsplit")
    local old_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(old_win, old_buf)

    apply_diff_win_options(old_win)

    local new_win = diff_win

    vim.wo[old_win].scrollbind = true
    vim.wo[old_win].cursorbind = true
    vim.wo[new_win].scrollbind = true
    vim.wo[new_win].cursorbind = true
    vim.cmd("syncbind")

    M.current.diff_view_old = { bufnr = old_buf, winid = old_win }
    M.current.diff_view_new = { bufnr = M.current.diff_view.bufnr, winid = new_win }

    vim.o.equalalways = saved_ea

    if vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
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

    local saved_ea = vim.o.equalalways
    vim.o.equalalways = false

    local old_component = M.current.diff_view_old
    local new_win = M.current.diff_view_new and M.current.diff_view_new.winid

    if new_win and vim.api.nvim_win_is_valid(new_win) then
        vim.wo[new_win].scrollbind = false
        vim.wo[new_win].cursorbind = false
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

    M.current.diff_view_old = nil
    M.current.diff_view_new = nil

    vim.o.equalalways = saved_ea
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

---Mount the layout (no-op in tab-based approach, create() does everything)
function M.mount()
    -- Layout is already mounted when create() is called
end

---Unmount the layout
function M.unmount()
    if M.current then
        -- Clean up split mode if active
        if M.is_split_mode() then
            M.exit_split_mode()
        end

        -- Store buffer references before closing
        local tree_buf = M.current.file_tree.bufnr
        local commit_list_buf = M.current.commit_list and M.current.commit_list.bufnr
        local branch_list_buf = M.current.branch_list and M.current.branch_list.bufnr
        local diff_buf = M.current.diff_view.bufnr
        local prev_tab = M.prev_tab

        M.current = nil
        M.prev_tab = nil

        -- Close the review tab
        pcall(function()
            vim.cmd("tabclose")
        end)

        -- Return to previous tab if it exists
        if prev_tab and vim.api.nvim_tabpage_is_valid(prev_tab) then
            vim.api.nvim_set_current_tabpage(prev_tab)
        end

        -- Delete buffers asynchronously to avoid delay
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
