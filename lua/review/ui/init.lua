local diff_view = require("review.ui.diff_view")
local file_tree = require("review.ui.file_tree")
local git = require("review.core.git")
local highlights = require("review.ui.highlights")
local layout = require("review.ui.layout")
local state = require("review.state")

local M = {}

-- Store original tabline setting
local saved_showtabline = nil

---Initialize the UI
function M.setup()
    highlights.setup()
end

---Open the review UI
function M.open()
    if state.state.is_open then
        return
    end

    -- Hide tabline
    saved_showtabline = vim.o.showtabline
    vim.o.showtabline = 0

    -- Create and mount layout
    local l = layout.create()
    layout.mount()

    state.state.is_open = true

    -- Initialize file tree
    file_tree.create(l.file_tree, {
        on_file_select = function(path)
            M.show_diff(path)
        end,
        on_close = function(send_comments)
            M.close(send_comments)
        end,
        on_refresh = function()
            -- Refresh diff view if a file is selected
            if state.state.current_file then
                M.show_diff(state.state.current_file)
            end
        end,
    })

    -- Focus file tree
    if l.file_tree and l.file_tree.winid then
        vim.api.nvim_set_current_win(l.file_tree.winid)
    end

    -- Auto-select first file if exists (use nodes to respect section ordering)
    local ft = file_tree.get()
    if ft and ft.nodes then
        -- Find first file node (respects section ordering: unstaged first, then staged)
        for _, node in ipairs(ft.nodes) do
            if node.is_file then
                M.show_diff(node.path)
                break
            end
        end
    else
        -- Show welcome message if no files
        M.show_welcome()
    end
end

---Show welcome message in diff view
function M.show_welcome()
    local diff_split = layout.get_diff_view()
    if not diff_split then
        return
    end

    local bufnr = diff_split.bufnr
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true

    local welcome = {
        "",
        "  Review Mode",
        "",
        "  Select a file from the left panel to view changes.",
        "",
        "  Keybindings:",
        "    <CR>   - Select file",
        "    r      - Mark as reviewed (stage)",
        "    u      - Unmark (unstage)",
        "    R      - Refresh file list",
        "    q/<Esc> - Close review",
        "",
        "  In diff view:",
        "    c      - Add comment",
        "    dc     - Delete comment",
        "    ]c/[c  - Next/prev hunk",
        "    ]f/[f  - Next/prev file",
        "",
    }

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, welcome)
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true

    -- Apply title highlight
    vim.api.nvim_buf_add_highlight(bufnr, -1, "ReviewTitle", 1, 0, -1)
end

---Show diff for a file
---@param path string
function M.show_diff(path)
    state.state.current_file = path

    local diff_split = layout.get_diff_view()
    if not diff_split then
        return
    end

    -- Create or update diff view
    diff_view.create(diff_split, path, {
        on_close = function(send_comments)
            M.close(send_comments)
        end,
    })
end

---Perform the actual close operation
---@param action? string "exit" | "copy" | "copy_and_send"
local function do_close(action)
    if not state.state.is_open then
        return
    end

    -- Handle export based on action
    if action == "copy" or action == "copy_and_send" then
        local all_comments = state.get_all_comments()
        if #all_comments > 0 then
            local export = require("review.export.markdown")
            -- Copy to clipboard
            local content = export.generate()
            vim.fn.setreg("+", content)
            vim.fn.setreg("*", content)

            if action == "copy_and_send" then
                -- Try to send to tmux
                export.to_tmux(nil, true)
            end
        end
    end

    -- Destroy components
    file_tree.destroy()
    diff_view.destroy()

    -- Unmount layout
    layout.unmount()

    -- Restore tabline
    if saved_showtabline ~= nil then
        vim.o.showtabline = saved_showtabline
        saved_showtabline = nil
    end

    state.reset()
end

---Show exit popup with options
local function show_exit_popup()
    local all_comments = state.get_all_comments()
    local has_comments = #all_comments > 0

    local items = {
        { label = "Exit", action = "exit" },
        { label = "Exit & Copy", action = "copy" },
        { label = "Exit, Copy & Send to tmux", action = "copy_and_send" },
    }

    -- Add comment count hint
    local prompt = "Close review"
    if has_comments then
        prompt = prompt .. string.format(" (%d comment%s)", #all_comments, #all_comments == 1 and "" or "s")
    end

    vim.ui.select(items, {
        prompt = prompt,
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if choice then
            do_close(choice.action)
        end
    end)
end

---Close the review UI
---@param show_popup? boolean Whether to show exit popup (default true)
function M.close(show_popup)
    if not state.state.is_open then
        return
    end

    if show_popup == false then
        -- Direct close without popup (used by pick_commit)
        do_close("exit")
    else
        show_exit_popup()
    end
end

---Toggle the review UI
function M.toggle()
    if state.state.is_open then
        M.close()
    else
        M.open()
    end
end

---Check if UI is open
---@return boolean
function M.is_open()
    return state.state.is_open
end

---Check if we're in history mode (comparing against a commit other than HEAD)
---@return boolean
function M.is_history_mode()
    return state.state.base ~= nil and state.state.base ~= "HEAD"
end

---Show commit picker and open review with selected base
---@param count? number Number of commits to show (default 20)
function M.pick_commit(count)
    count = count or 20
    local commits = git.get_recent_commits(count)

    if #commits == 0 then
        vim.notify("No commits found", vim.log.levels.WARN)
        return
    end

    -- Add HEAD option at the top
    local items = {
        { display = "HEAD (working changes)", hash = "HEAD" },
    }

    for _, commit in ipairs(commits) do
        table.insert(items, {
            display = string.format("%s %s (%s)", commit.short_hash, commit.subject, commit.date),
            hash = commit.hash,
        })
    end

    vim.ui.select(items, {
        prompt = "Select base commit to diff against:",
        format_item = function(item)
            return item.display
        end,
    }, function(choice)
        if choice then
            -- Close existing review if open
            if state.state.is_open then
                M.close(false)
            end
            -- Set base and open
            state.state.base = choice.hash
            M.open()
        end
    end)
end

return M
