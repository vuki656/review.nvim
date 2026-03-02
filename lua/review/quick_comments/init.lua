local comment_types_module = require("review.comment_types")
local config = require("review.config")
local markdown = require("review.quick_comments.markdown")
local panel = require("review.quick_comments.panel")
local persistence = require("review.quick_comments.persistence")
local qc_state = require("review.quick_comments.state")
local signs = require("review.quick_comments.signs")
local ui_util = require("review.ui.util")

local M = {}

local comment_types = comment_types_module.TYPES
local comment_type_order = comment_types_module.ORDER

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

    -- Create floating input window
    local type_info = comment_types[comment_type_order[1]]
    local input_buf = ui_util.create_comment_input_buffer()

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

    ui_util.disable_cmp_for_buffer()

    vim.api.nvim_set_option_value(
        "winhighlight",
        "FloatBorder:" .. type_info.border_hl .. ",FloatTitle:" .. type_info.title_hl,
        { win = input_win }
    )
    vim.wo[input_win].wrap = true
    vim.wo[input_win].linebreak = true

    local get_current_type =
        ui_util.setup_comment_type_cycling(input_buf, input_win, comment_types, comment_type_order)

    local function close_input()
        if vim.api.nvim_win_is_valid(input_win) then
            vim.api.nvim_win_close(input_win, true)
        end
        if vim.api.nvim_buf_is_valid(input_buf) then
            vim.api.nvim_buf_delete(input_buf, { force = true })
        end
    end

    local function submit()
        local input_lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)

        while #input_lines > 0 and input_lines[#input_lines]:match("^%s*$") do
            table.remove(input_lines)
        end

        vim.cmd("stopinsert")
        close_input()

        local text = table.concat(input_lines, "\n")
        if text ~= "" then
            qc_state.add(file, line_num, get_current_type(), text, context)
            persistence.save()
            signs.update(bufnr)

            if panel.is_open() then
                panel.render()
            else
                panel.open()
            end
        end
    end

    vim.keymap.set("i", "<CR>", submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("n", "<CR>", submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("i", "<Esc>", submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("i", "<C-c>", submit, { buffer = input_buf, nowait = true })
    vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = input_buf, nowait = true })

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
    local content = markdown.build(comments)
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
