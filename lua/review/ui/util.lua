local M = {}

---Smooth scroll the diff view from any panel
---@param active_timers table Table with scroll_timer field for cleanup
---@param direction "up"|"down"
function M.smooth_scroll(active_timers, direction)
    if active_timers.scroll_timer then
        active_timers.scroll_timer:stop()
        active_timers.scroll_timer:close()
        active_timers.scroll_timer = nil
    end

    local diff_split = require("review.ui.layout").get_diff_view()
    if not diff_split or not diff_split.winid or not vim.api.nvim_win_is_valid(diff_split.winid) then
        return
    end

    local lines = 15
    local delay = 2
    local cmd = direction == "down" and "normal! \x05" or "normal! \x19"

    local iteration = 0
    active_timers.scroll_timer = vim.loop.new_timer()
    active_timers.scroll_timer:start(
        0,
        delay,
        vim.schedule_wrap(function()
            if iteration >= lines then
                if active_timers.scroll_timer then
                    active_timers.scroll_timer:stop()
                    active_timers.scroll_timer:close()
                    active_timers.scroll_timer = nil
                end
                return
            end
            if vim.api.nvim_win_is_valid(diff_split.winid) then
                vim.api.nvim_win_call(diff_split.winid, function()
                    vim.cmd(cmd)
                end)
            end
            iteration = iteration + 1
        end)
    )
end

---Stop and close all timers in a table, setting entries to nil
---@param timers table<string, userdata|nil>
function M.destroy_timers(timers)
    for name, timer in pairs(timers) do
        if timer then
            timer:stop()
            timer:close()
            timers[name] = nil
        end
    end
end

---Temporarily make a buffer modifiable, run fn, then lock it again
---@param bufnr number
---@param fn function
function M.with_modifiable(bufnr, fn)
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true
    fn()
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
end

---Create a scratch buffer configured for comment input
---@return number bufnr
function M.create_comment_input_buffer()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].completefunc = ""
    vim.bo[bufnr].omnifunc = ""
    vim.b[bufnr].copilot_enabled = false
    return bufnr
end

---Disable nvim-cmp for the current buffer
function M.disable_cmp_for_buffer()
    local ok_cmp, cmp = pcall(require, "cmp")
    if ok_cmp then
        cmp.setup.buffer({ enabled = false })
    end
end

---Set up comment type cycling (Tab/S-Tab) and title updating on a comment input window
---@param input_buf number
---@param input_win number
---@param comment_types table
---@param comment_type_order string[]
---@return fun(): string get_current_type Returns current comment type key
function M.setup_comment_type_cycling(input_buf, input_win, comment_types, comment_type_order)
    local type_idx = 1
    local current_type = comment_type_order[type_idx]

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

    vim.keymap.set("i", "<Tab>", function()
        type_idx = (type_idx % #comment_type_order) + 1
        current_type = comment_type_order[type_idx]
        update_title()
    end, { buffer = input_buf, nowait = true })

    vim.keymap.set("i", "<S-Tab>", function()
        type_idx = type_idx - 1
        if type_idx < 1 then
            type_idx = #comment_type_order
        end
        current_type = comment_type_order[type_idx]
        update_title()
    end, { buffer = input_buf, nowait = true })

    return function()
        return current_type
    end
end

---Create a keymap helper that optionally registers keymaps for help display
---@param bufnr number Primary buffer to bind keymaps to
---@param registered_keymaps? table If provided, keymaps with desc+group are tracked here
---@return fun(lhs: string, rhs: string|function, opts: table, extra_bufnrs?: number[])
function M.create_buffer_mapper(bufnr, registered_keymaps)
    return function(lhs, rhs, opts, extra_bufnrs)
        local group = opts.group
        opts.group = nil

        if registered_keymaps and opts.desc and group then
            table.insert(registered_keymaps, { lhs = lhs, desc = opts.desc, group = group })
        end

        if extra_bufnrs then
            for _, target_bufnr in ipairs(extra_bufnrs) do
                local keymap_opts = vim.tbl_extend("force", opts, { buffer = target_bufnr })
                vim.keymap.set("n", lhs, rhs, keymap_opts)
            end
        else
            opts.buffer = bufnr
            vim.keymap.set("n", lhs, rhs, opts)
        end
    end
end

---Custom floating select dialog that sizes to content
---@param opts { title?: string, prompt?: string, items: string[], on_select: fun(index: number, item: string) }
function M.select(opts)
    local items = opts.items
    local padding = 4
    local hint_text = "<CR> select  <Esc> cancel"

    local max_item_width = 0
    for _, item in ipairs(items) do
        max_item_width = math.max(max_item_width, #item)
    end

    local content_width = max_item_width + padding + 2
    if opts.prompt then
        content_width = math.max(content_width, #opts.prompt + padding)
    end
    if opts.title then
        content_width = math.max(content_width, #opts.title + padding)
    end
    content_width = math.max(content_width, #hint_text + padding)

    local max_width = math.floor(vim.o.columns * 0.8)
    content_width = math.min(content_width, max_width)

    local lines = {}
    local namespace = vim.api.nvim_create_namespace("review_select")

    table.insert(lines, "")

    if opts.prompt then
        table.insert(lines, "  " .. opts.prompt)
        table.insert(lines, "")
    end

    local item_start_line = #lines
    for index, item in ipairs(items) do
        local prefix = index == 1 and "  > " or "    "
        table.insert(lines, prefix .. item)
    end

    table.insert(lines, "")
    table.insert(lines, "  " .. hint_text)
    table.insert(lines, "")

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    local height = #lines
    local row = math.floor((vim.o.lines - height) / 2) - 1
    local col = math.floor((vim.o.columns - content_width) / 2)

    local win_opts = {
        relative = "editor",
        row = row,
        col = col,
        width = content_width,
        height = height,
        style = "minimal",
        border = "rounded",
        focusable = true,
    }

    if opts.title then
        win_opts.title = " " .. opts.title .. " "
        win_opts.title_pos = "center"
    end

    local winid = vim.api.nvim_open_win(bufnr, true, win_opts)

    vim.api.nvim_set_option_value(
        "winhighlight",
        "FloatBorder:ReviewFloatBorder,FloatTitle:ReviewFloatTitle,Normal:Normal",
        { win = winid }
    )
    vim.wo[winid].cursorline = false

    local saved_guicursor = vim.o.guicursor
    vim.o.guicursor = "a:Cursor/lCursor-blinkwait0-blinkon0-blinkoff0"
    vim.api.nvim_set_hl(0, "Cursor", { blend = 100 })
    vim.schedule(function()
        vim.cmd("redraw")
    end)

    local hint_line = #lines - 2
    vim.api.nvim_buf_add_highlight(bufnr, namespace, "ReviewSelectHint", hint_line, 0, -1)

    local selected = 1

    local function render_items()
        vim.bo[bufnr].modifiable = true
        for index, item in ipairs(items) do
            local line_index = item_start_line + index - 1
            local prefix = index == selected and "  > " or "    "
            vim.api.nvim_buf_set_lines(bufnr, line_index, line_index + 1, false, { prefix .. item })
        end
        vim.bo[bufnr].modifiable = false

        vim.api.nvim_buf_clear_namespace(bufnr, namespace, item_start_line, item_start_line + #items)
        local selected_line = item_start_line + selected - 1
        vim.api.nvim_buf_add_highlight(bufnr, namespace, "ReviewSelectItem", selected_line, 0, -1)
    end

    render_items()

    local closed = false

    local function close_dialog()
        if closed then
            return
        end
        closed = true
        vim.o.guicursor = saved_guicursor
        vim.api.nvim_set_hl(0, "Cursor", { blend = 0 })
        vim.cmd("redraw")
        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
    end

    local function select_item()
        local index = selected
        local item = items[index]
        close_dialog()
        vim.schedule(function()
            opts.on_select(index, item)
        end)
    end

    local keymap_opts = { buffer = bufnr, nowait = true, silent = true }

    vim.keymap.set("n", "j", function()
        if selected < #items then
            selected = selected + 1
            render_items()
        end
    end, keymap_opts)

    vim.keymap.set("n", "<Down>", function()
        if selected < #items then
            selected = selected + 1
            render_items()
        end
    end, keymap_opts)

    vim.keymap.set("n", "k", function()
        if selected > 1 then
            selected = selected - 1
            render_items()
        end
    end, keymap_opts)

    vim.keymap.set("n", "<Up>", function()
        if selected > 1 then
            selected = selected - 1
            render_items()
        end
    end, keymap_opts)

    vim.keymap.set("n", "<CR>", select_item, keymap_opts)
    vim.keymap.set("n", "<Esc>", close_dialog, keymap_opts)
    vim.keymap.set("n", "q", close_dialog, keymap_opts)

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = bufnr,
        once = true,
        callback = close_dialog,
    })
end

---Show a Yes/No confirmation popup and invoke callback on "Yes"
---@param prompt string
---@param on_confirm function
function M.confirm(prompt, on_confirm)
    M.select({
        title = "Confirm",
        prompt = prompt,
        items = { "Yes", "No" },
        on_select = function(index)
            if index == 1 then
                on_confirm()
            end
        end,
    })
end

return M
