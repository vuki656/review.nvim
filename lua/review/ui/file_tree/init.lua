local NuiTree = require("nui.tree")
local nodes_mod = require("review.ui.file_tree.nodes")
local keymaps = require("review.ui.file_tree.keymaps")
local git = require("review.core.git")
local state = require("review.state")

local M = {}

---@class FileTreeComponent
---@field split NuiSplit
---@field tree NuiTree
---@field bufnr number
---@field is_tree_view boolean
---@field files string[]

---@type FileTreeComponent|nil
M.current = nil

---Create prepare_node function for highlighting
---@return function
local function create_prepare_node()
    return function(node)
        local line = NuiTree.Node({})
        line.text = node.text

        if node._highlight then
            line._highlight = node._highlight
        end

        return line
    end
end

---Create the file tree component
---@param split NuiSplit
---@param callbacks table
---@return FileTreeComponent
function M.create(split, callbacks)
    local bufnr = split.bufnr

    -- Get changed files
    local files = git.get_changed_files(state.state.base)

    -- Initialize file states
    for _, file in ipairs(files) do
        local is_staged = git.is_staged(file)
        state.set_reviewed(file, is_staged)
    end

    -- Create tree with flat view by default
    local tree_nodes = nodes_mod.create_flat_nodes(files)

    local tree = NuiTree({
        bufnr = bufnr,
        nodes = tree_nodes,
        prepare_node = function(node)
            return node
        end,
    })

    M.current = {
        split = split,
        tree = tree,
        bufnr = bufnr,
        is_tree_view = false,
        files = files,
    }

    -- Render the tree
    M.render()

    -- Set up keymaps
    keymaps.setup(M.current, {
        on_file_select = callbacks.on_file_select,
        on_close = callbacks.on_close,
        on_toggle_view = function()
            M.toggle_view()
        end,
        on_refresh = function()
            M.refresh()
            if callbacks.on_refresh then
                callbacks.on_refresh()
            end
        end,
    })

    -- Set buffer name
    vim.api.nvim_buf_set_name(bufnr, "Review: Files")

    return M.current
end

---Render the tree with proper highlights
function M.render()
    if not M.current then
        return
    end

    local tree = M.current.tree
    local bufnr = M.current.bufnr

    -- Enable modification temporarily
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true

    -- Render tree
    tree:render()

    -- Apply highlights to each line
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, _ in ipairs(lines) do
        local node = tree:get_node(i)
        if node and node._highlight then
            vim.api.nvim_buf_add_highlight(bufnr, -1, node._highlight, i - 1, 0, -1)
        end
    end

    -- Disable modification
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
end

---Toggle between tree and flat view
function M.toggle_view()
    if not M.current then
        return
    end

    M.current.is_tree_view = not M.current.is_tree_view

    local new_nodes
    if M.current.is_tree_view then
        new_nodes = nodes_mod.create_tree_nodes(M.current.files)
    else
        new_nodes = nodes_mod.create_flat_nodes(M.current.files)
    end

    -- Recreate tree with new nodes
    M.current.tree = NuiTree({
        bufnr = M.current.bufnr,
        nodes = new_nodes,
        prepare_node = function(node)
            return node
        end,
    })

    M.render()
end

---Refresh the file list
function M.refresh()
    if not M.current then
        return
    end

    -- Get updated file list
    M.current.files = git.get_changed_files(state.state.base)

    -- Update reviewed states
    for _, file in ipairs(M.current.files) do
        local is_staged = git.is_staged(file)
        state.set_reviewed(file, is_staged)
    end

    -- Recreate nodes
    local new_nodes
    if M.current.is_tree_view then
        new_nodes = nodes_mod.create_tree_nodes(M.current.files)
    else
        new_nodes = nodes_mod.create_flat_nodes(M.current.files)
    end

    -- Recreate tree
    M.current.tree = NuiTree({
        bufnr = M.current.bufnr,
        nodes = new_nodes,
        prepare_node = function(node)
            return node
        end,
    })

    M.render()
end

---Get the current component
---@return FileTreeComponent|nil
function M.get()
    return M.current
end

---Destroy the component
function M.destroy()
    M.current = nil
end

return M
