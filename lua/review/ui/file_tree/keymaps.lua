local git = require("review.core.git")
local state = require("review.state")

local M = {}

---@param file_tree_component table The file tree component
---@param callbacks table Callback functions
function M.setup(file_tree_component, callbacks)
    local bufnr = file_tree_component.bufnr

    -- Select file / toggle directory
    vim.keymap.set("n", "<CR>", function()
        local node = file_tree_component.tree:get_node()
        if not node then
            return
        end

        if node.is_file then
            if callbacks.on_file_select then
                callbacks.on_file_select(node.path)
            end
        else
            -- Toggle directory expansion
            if node:is_expanded() then
                node:collapse()
            else
                node:expand()
            end
            file_tree_component.tree:render()
        end
    end, { buffer = bufnr, desc = "Select file / toggle directory" })

    -- Toggle tree/flat view
    vim.keymap.set("n", "<Tab>", function()
        if callbacks.on_toggle_view then
            callbacks.on_toggle_view()
        end
    end, { buffer = bufnr, desc = "Toggle tree/flat view" })

    -- Mark as reviewed (stage file)
    vim.keymap.set("n", "r", function()
        local node = file_tree_component.tree:get_node()
        if not node or not node.is_file then
            return
        end

        if git.stage_file(node.path) then
            state.set_reviewed(node.path, true)
            if callbacks.on_refresh then
                callbacks.on_refresh()
            end
            vim.notify("Marked as reviewed: " .. node.path, vim.log.levels.INFO)
        else
            vim.notify("Failed to stage file: " .. node.path, vim.log.levels.ERROR)
        end
    end, { buffer = bufnr, desc = "Mark as reviewed" })

    -- Unmark (unstage file)
    vim.keymap.set("n", "u", function()
        local node = file_tree_component.tree:get_node()
        if not node or not node.is_file then
            return
        end

        if git.unstage_file(node.path) then
            state.set_reviewed(node.path, false)
            if callbacks.on_refresh then
                callbacks.on_refresh()
            end
            vim.notify("Unmarked: " .. node.path, vim.log.levels.INFO)
        else
            vim.notify("Failed to unstage file: " .. node.path, vim.log.levels.ERROR)
        end
    end, { buffer = bufnr, desc = "Unmark (unstage)" })

    -- Refresh file list
    vim.keymap.set("n", "R", function()
        if callbacks.on_refresh then
            callbacks.on_refresh()
        end
    end, { buffer = bufnr, desc = "Refresh file list" })

    -- Close review UI
    vim.keymap.set("n", "q", function()
        if callbacks.on_close then
            callbacks.on_close()
        end
    end, { buffer = bufnr, desc = "Close review UI" })

    -- Navigate with j/k (default behavior, but ensure cursor stays in bounds)
    vim.keymap.set("n", "j", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local line_count = vim.api.nvim_buf_line_count(0)
        if line < line_count then
            vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
        end
    end, { buffer = bufnr, desc = "Move down" })

    vim.keymap.set("n", "k", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        if line > 1 then
            vim.api.nvim_win_set_cursor(0, { line - 1, 0 })
        end
    end, { buffer = bufnr, desc = "Move up" })
end

return M
