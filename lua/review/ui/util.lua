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

---Show a Yes/No confirmation popup and invoke callback on "Yes"
---@param prompt string
---@param on_confirm function
function M.confirm(prompt, on_confirm)
    vim.ui.select({ { label = "Yes" }, { label = "No" } }, {
        prompt = prompt,
        format_item = function(item)
            return item.label
        end,
    }, function(choice)
        if choice and choice.label == "Yes" then
            on_confirm()
        end
    end)
end

return M
