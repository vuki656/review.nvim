local config = require("review.config")
local panel = require("review.quick_comments.panel")
local persistence = require("review.quick_comments.persistence")
local qc_state = require("review.quick_comments.state")
local signs = require("review.quick_comments.signs")

local M = {}

---Comment type info for input window
local comment_types = {
    note = {
        label = "Note",
        icon = "󰍩",
        border_hl = "ReviewInputBorderNote",
        title_hl = "ReviewInputTitleNote",
    },
    fix = {
        label = "Fix",
        icon = "󰁨",
        border_hl = "ReviewInputBorderFix",
        title_hl = "ReviewInputTitleFix",
    },
    question = {
        label = "Question",
        icon = "󰋗",
        border_hl = "ReviewInputBorderQuestion",
        title_hl = "ReviewInputTitleQuestion",
    },
}

---Comment type order for cycling
local comment_type_order = { "fix", "note", "question" }

---Add a quick comment at the current cursor position
function M.add()
    local bufnr = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(bufnr)

    if file == "" then
        vim.notify("Cannot add comment to unsaved buffer", vim.log.levels.WARN)
        return
    end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_num = cursor[1]

    -- Get line content for context
    local lines = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)
    local context = lines[1] or ""

    -- Current type index (default to fix)
    local type_idx = 1
    local current_type = comment_type_order[type_idx]
    local type_info = comment_types[current_type]

    -- Create floating input window
    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[input_buf].buftype = "nofile"
    vim.bo[input_buf].filetype = "markdown"
    vim.bo[input_buf].completefunc = ""
    vim.bo[input_buf].omnifunc = ""
    vim.b[input_buf].copilot_enabled = false

    -- Calculate window position
    local win_width = 60
    local win_row = vim.fn.winline()
    local win_opts = {
        relative = "win",
        win = vim.api.nvim_get_current_win(),
        row = win_row,
        col = 0,
        width = win_width,
        height = 5,
        style = "minimal",
        border = { "┏", "━", "┓", "┃", "┛", "━", "┗", "┃" },
        title = " " .. type_info.icon .. " " .. type_info.label .. " ",
        title_pos = "left",
    }

    local input_win = vim.api.nvim_open_win(input_buf, true, win_opts)

    -- Disable cmp if present
    local ok_cmp, cmp = pcall(require, "cmp")
    if ok_cmp then
        cmp.setup.buffer({ enabled = false })
    end

    -- Set window options
    vim.api.nvim_set_option_value(
        "winhighlight",
        "FloatBorder:" .. type_info.border_hl .. ",FloatTitle:" .. type_info.title_hl,
        { win = input_win }
    )
    vim.wo[input_win].wrap = true
    vim.wo[input_win].linebreak = true

    -- Close input window
    local function close_input()
        if vim.api.nvim_win_is_valid(input_win) then
            vim.api.nvim_win_close(input_win, true)
        end
        if vim.api.nvim_buf_is_valid(input_buf) then
            vim.api.nvim_buf_delete(input_buf, { force = true })
        end
    end

    -- Update window title with current type
    local function update_title()
        local info = comment_types[current_type]
        vim.api.nvim_win_set_config(input_win, {
            title = " " .. info.icon .. " " .. info.label .. " ",
        })
        vim.api.nvim_set_option_value(
            "winhighlight",
            "FloatBorder:" .. info.border_hl .. ",FloatTitle:" .. info.title_hl,
            { win = input_win }
        )
    end

    -- Submit the comment
    local function submit()
        local input_lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)

        -- Trim trailing empty lines
        while #input_lines > 0 and input_lines[#input_lines]:match("^%s*$") do
            table.remove(input_lines)
        end

        vim.cmd("stopinsert")
        close_input()

        local text = table.concat(input_lines, "\n")
        if text ~= "" then
            qc_state.add(file, line_num, current_type, text, context)
            persistence.save()
            signs.update(bufnr)

            -- Open or refresh panel
            if panel.is_open() then
                panel.render()
            else
                panel.open()
            end
        end
    end

    -- Enter to submit
    vim.keymap.set("i", "<CR>", submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("n", "<CR>", submit, { buffer = input_buf, nowait = true })

    -- Escape and Ctrl-C to submit
    vim.keymap.set("i", "<Esc>", submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("i", "<C-c>", submit, { buffer = input_buf, nowait = true })

    -- Shift-Enter for new line
    vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = input_buf, nowait = true })

    -- Tab to cycle type forward
    vim.keymap.set("i", "<Tab>", function()
        type_idx = (type_idx % #comment_type_order) + 1
        current_type = comment_type_order[type_idx]
        update_title()
    end, { buffer = input_buf, nowait = true })

    -- Shift-Tab to cycle type backward
    vim.keymap.set("i", "<S-Tab>", function()
        type_idx = type_idx - 1
        if type_idx < 1 then
            type_idx = #comment_type_order
        end
        current_type = comment_type_order[type_idx]
        update_title()
    end, { buffer = input_buf, nowait = true })

    -- Start in insert mode
    vim.cmd("startinsert")
end

---Toggle the quick comments panel
function M.toggle_panel()
    panel.toggle()
end

---Open the quick comments panel
function M.open_panel()
    panel.open()
end

---Close the quick comments panel
function M.close_panel()
    panel.close()
end

---Generate markdown content from comments and copy to clipboard
---@param comments QuickComment[]
---@return number comment_count
local function copy_to_clipboard(comments)
    local lines = { "# Quick Comments" }
    local current_file = nil

    for _, comment in ipairs(comments) do
        if comment.file ~= current_file then
            current_file = comment.file
            local cwd = vim.fn.getcwd()
            local rel_path = comment.file
            if rel_path:sub(1, #cwd) == cwd then
                rel_path = rel_path:sub(#cwd + 2)
            end
            table.insert(lines, "")
            table.insert(lines, "## " .. rel_path)
        end

        local type_info = comment_types[comment.type]
        table.insert(lines, "")
        table.insert(lines, string.format("**Line %d** - %s %s", comment.line, type_info.icon, type_info.label))
        if comment.context then
            table.insert(lines, "```")
            table.insert(lines, comment.context)
            table.insert(lines, "```")
        end
        table.insert(lines, comment.text)
    end

    local content = table.concat(lines, "\n")
    vim.fn.setreg("+", content)

    return #comments
end

---Export comments to clipboard
function M.export()
    local comments = qc_state.get_all_flat()
    if #comments == 0 then
        vim.notify("No comments to export", vim.log.levels.INFO)
        return
    end

    local count = copy_to_clipboard(comments)
    vim.notify("Exported " .. count .. " comment(s) to clipboard", vim.log.levels.INFO)
end

---Copy comments to clipboard, clear state, and notify
function M.copy()
    local comments = qc_state.get_all_flat()
    if #comments == 0 then
        vim.notify("No quick comments to copy", vim.log.levels.INFO)
        return
    end

    local comment_count = copy_to_clipboard(comments)

    -- Clear signs from all buffers that have comments
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            signs.clear(bufnr)
        end
    end

    -- Clear state
    qc_state.clear()
    persistence.save()

    -- Close panel if open
    if panel.is_open() then
        panel.close()
    end

    vim.notify("Copied " .. comment_count .. " quick comment(s) to clipboard and cleared", vim.log.levels.INFO)
end

---Set up the quick comments feature
function M.setup()
    local cfg = config.get()

    -- Set up sign definitions
    signs.setup()

    -- Load persisted comments
    persistence.load()

    -- Set up autosave
    persistence.setup_autosave()

    -- Set up signs autocmd
    if cfg.quick_comments and cfg.quick_comments.signs and cfg.quick_comments.signs.enabled then
        signs.setup_autocmd()
    end

    -- Set up keymaps
    if cfg.quick_comments and cfg.quick_comments.keymaps then
        local keymaps = cfg.quick_comments.keymaps

        if keymaps.add then
            vim.keymap.set("n", keymaps.add, function()
                M.add()
            end, { desc = "Add quick comment" })
        end

        if keymaps.toggle_panel then
            vim.keymap.set("n", keymaps.toggle_panel, function()
                M.toggle_panel()
            end, { desc = "Toggle quick comments panel" })
        end
    end
end

---Get the state module (for external access)
---@return table
function M.get_state()
    return qc_state
end

---Get the panel module (for external access)
---@return table
function M.get_panel()
    return panel
end

return M
