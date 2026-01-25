local state = require("review.state")

local M = {}

---@param diff_view_component table
---@param callbacks table
function M.setup(diff_view_component, callbacks)
    local bufnr = diff_view_component.bufnr

    -- Add comment at cursor line
    vim.keymap.set("n", "c", function()
        if callbacks.on_add_comment then
            callbacks.on_add_comment()
        end
    end, { buffer = bufnr, desc = "Add comment" })

    -- Delete comment at cursor line
    vim.keymap.set("n", "dc", function()
        if callbacks.on_delete_comment then
            callbacks.on_delete_comment()
        end
    end, { buffer = bufnr, desc = "Delete comment" })

    -- Toggle unified/split view
    vim.keymap.set("n", "<leader>d", function()
        if callbacks.on_toggle_mode then
            callbacks.on_toggle_mode()
        end
    end, { buffer = bufnr, desc = "Toggle diff view mode" })

    -- Next hunk
    vim.keymap.set("n", "]c", function()
        if callbacks.on_next_hunk then
            callbacks.on_next_hunk()
        end
    end, { buffer = bufnr, desc = "Next hunk" })

    -- Previous hunk
    vim.keymap.set("n", "[c", function()
        if callbacks.on_prev_hunk then
            callbacks.on_prev_hunk()
        end
    end, { buffer = bufnr, desc = "Previous hunk" })

    -- Next file
    vim.keymap.set("n", "]f", function()
        if callbacks.on_next_file then
            callbacks.on_next_file()
        end
    end, { buffer = bufnr, desc = "Next file" })

    -- Previous file
    vim.keymap.set("n", "[f", function()
        if callbacks.on_prev_file then
            callbacks.on_prev_file()
        end
    end, { buffer = bufnr, desc = "Previous file" })

    -- Close
    vim.keymap.set("n", "q", function()
        if callbacks.on_close then
            callbacks.on_close()
        end
    end, { buffer = bufnr, desc = "Close review UI" })
end

return M
