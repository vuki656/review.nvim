local Popup = require("nui.popup")
local Input = require("nui.input")
local types = require("review.ui.comment.types")
local state = require("review.state")

local M = {}

---@type NuiPopup|nil
M.type_popup = nil

---@type NuiInput|nil
M.text_input = nil

---Open the comment input popup
---@param file string
---@param line number
---@param original_line number|nil
---@param on_complete function|nil
function M.open(file, line, original_line, on_complete)
    -- First show type selection popup
    M.show_type_selection(function(selected_type)
        if selected_type then
            M.show_text_input(file, line, original_line, selected_type, on_complete)
        end
    end)
end

---Show type selection popup
---@param on_select function
function M.show_type_selection(on_select)
    local popup = Popup({
        relative = "cursor",
        position = {
            row = 1,
            col = 0,
        },
        size = {
            width = 30,
            height = 7,
        },
        border = {
            style = "rounded",
            text = {
                top = " Comment Type ",
                top_align = "center",
            },
        },
        buf_options = {
            modifiable = false,
            readonly = true,
        },
        win_options = {
            cursorline = true,
            winhighlight = "Normal:Normal,FloatBorder:ReviewBorder,CursorLine:ReviewSelected",
        },
    })

    popup:mount()
    M.type_popup = popup

    -- Set content
    local lines = {
        "",
        "  1/n  Note",
        "  2/f  Fix",
        "  3/q  Question",
        "",
        "  <Esc> Cancel",
    }

    vim.api.nvim_buf_set_option(popup.bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(popup.bufnr, "modifiable", false)

    -- Apply highlights
    vim.api.nvim_buf_add_highlight(popup.bufnr, -1, "ReviewCommentNote", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(popup.bufnr, -1, "ReviewCommentFix", 2, 0, -1)
    vim.api.nvim_buf_add_highlight(popup.bufnr, -1, "ReviewCommentQuestion", 3, 0, -1)

    -- Set up keymaps
    local function close_and_select(type_id)
        popup:unmount()
        M.type_popup = nil
        on_select(type_id)
    end

    local function close_cancel()
        popup:unmount()
        M.type_popup = nil
        on_select(nil)
    end

    -- Type selection keys
    vim.keymap.set("n", "1", function()
        close_and_select("note")
    end, { buffer = popup.bufnr })
    vim.keymap.set("n", "n", function()
        close_and_select("note")
    end, { buffer = popup.bufnr })

    vim.keymap.set("n", "2", function()
        close_and_select("fix")
    end, { buffer = popup.bufnr })
    vim.keymap.set("n", "f", function()
        close_and_select("fix")
    end, { buffer = popup.bufnr })

    vim.keymap.set("n", "3", function()
        close_and_select("question")
    end, { buffer = popup.bufnr })
    vim.keymap.set("n", "q", function()
        close_and_select("question")
    end, { buffer = popup.bufnr })

    -- Cancel
    vim.keymap.set("n", "<Esc>", close_cancel, { buffer = popup.bufnr })

    -- Also allow Enter on selected line
    vim.keymap.set("n", "<CR>", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local row = cursor[1]
        if row == 2 then
            close_and_select("note")
        elseif row == 3 then
            close_and_select("fix")
        elseif row == 4 then
            close_and_select("question")
        end
    end, { buffer = popup.bufnr })

    -- Position cursor on first option
    vim.api.nvim_win_set_cursor(popup.winid, { 2, 0 })
end

---Show text input for comment
---@param file string
---@param line number
---@param original_line number|nil
---@param comment_type "note"|"fix"|"question"
---@param on_complete function|nil
function M.show_text_input(file, line, original_line, comment_type, on_complete)
    local type_info = types.get(comment_type)
    local title = type_info and type_info.label or "Comment"

    local input = Input({
        relative = "cursor",
        position = {
            row = 1,
            col = 0,
        },
        size = {
            width = 60,
        },
        border = {
            style = "rounded",
            text = {
                top = " " .. title .. " ",
                top_align = "center",
            },
        },
        win_options = {
            winhighlight = "Normal:Normal,FloatBorder:ReviewBorder",
        },
    }, {
        prompt = " ",
        on_submit = function(text)
            if text and text ~= "" then
                state.add_comment(file, line, comment_type, text, original_line)
                vim.notify("Comment added", vim.log.levels.INFO)
            end
            M.text_input = nil
            if on_complete then
                on_complete()
            end
        end,
        on_close = function()
            M.text_input = nil
        end,
    })

    input:mount()
    M.text_input = input

    -- Start in insert mode
    vim.cmd("startinsert")

    -- Add escape to cancel
    vim.keymap.set("i", "<Esc>", function()
        input:unmount()
        M.text_input = nil
    end, { buffer = input.bufnr })
end

---Close any open input popups
function M.close()
    if M.type_popup then
        M.type_popup:unmount()
        M.type_popup = nil
    end
    if M.text_input then
        M.text_input:unmount()
        M.text_input = nil
    end
end

return M
