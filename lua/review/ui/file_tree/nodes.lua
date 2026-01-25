local NuiTree = require("nui.tree")
local state = require("review.state")

local M = {}

---@class FileNode
---@field id string
---@field text string
---@field path string
---@field is_file boolean
---@field reviewed boolean

---Create a flat list of file nodes
---@param files string[]
---@return NuiTreeNode[]
function M.create_flat_nodes(files)
    local nodes = {}

    for _, file in ipairs(files) do
        local reviewed = state.is_reviewed(file)
        local icon = reviewed and "  " or "  "
        local hl = reviewed and "ReviewFileReviewed" or "ReviewFileModified"

        local node = NuiTree.Node({
            id = file,
            text = icon .. file,
            path = file,
            is_file = true,
            reviewed = reviewed,
            _highlight = hl,
        })
        table.insert(nodes, node)
    end

    return nodes
end

---Build a directory tree structure from file paths
---@param files string[]
---@return table
local function build_tree_structure(files)
    local tree = {}

    for _, file in ipairs(files) do
        local parts = vim.split(file, "/", { plain = true })
        local current = tree

        for i, part in ipairs(parts) do
            local is_file = (i == #parts)

            if not current[part] then
                current[part] = {
                    _name = part,
                    _path = table.concat({ unpack(parts, 1, i) }, "/"),
                    _is_file = is_file,
                }
            end

            if not is_file then
                current[part]._children = current[part]._children or {}
                current = current[part]._children
            end
        end
    end

    return tree
end

---Convert tree structure to NuiTree nodes
---@param tree table
---@param parent_path string|nil
---@return NuiTreeNode[]
local function tree_to_nodes(tree, parent_path)
    local nodes = {}

    -- Collect and sort entries
    local entries = {}
    for name, entry in pairs(tree) do
        if type(entry) == "table" and entry._name then
            table.insert(entries, { name = name, entry = entry })
        end
    end

    -- Sort: directories first, then alphabetically
    table.sort(entries, function(a, b)
        local a_is_dir = not a.entry._is_file
        local b_is_dir = not b.entry._is_file
        if a_is_dir ~= b_is_dir then
            return a_is_dir
        end
        return a.name < b.name
    end)

    for _, item in ipairs(entries) do
        local entry = item.entry
        local path = entry._path

        if entry._is_file then
            local reviewed = state.is_reviewed(path)
            local icon = reviewed and "  " or "  "
            local hl = reviewed and "ReviewFileReviewed" or "ReviewFileModified"

            local node = NuiTree.Node({
                id = path,
                text = icon .. entry._name,
                path = path,
                is_file = true,
                reviewed = reviewed,
                _highlight = hl,
            })
            table.insert(nodes, node)
        else
            -- Directory node
            local children = tree_to_nodes(entry._children or {}, path)
            local node = NuiTree.Node({
                id = path,
                text = "  " .. entry._name,
                path = path,
                is_file = false,
                reviewed = false,
                _highlight = "ReviewTreeDirectory",
            }, children)
            table.insert(nodes, node)
        end
    end

    return nodes
end

---Create a tree view of file nodes
---@param files string[]
---@return NuiTreeNode[]
function M.create_tree_nodes(files)
    local tree_structure = build_tree_structure(files)
    return tree_to_nodes(tree_structure, nil)
end

---Refresh node reviewed status
---@param node NuiTreeNode
function M.refresh_node(node)
    local data = node
    if data.is_file then
        local reviewed = state.is_reviewed(data.path)
        data.reviewed = reviewed
        local icon = reviewed and "  " or "  "
        data.text = icon .. vim.fn.fnamemodify(data.path, ":t")
        data._highlight = reviewed and "ReviewFileReviewed" or "ReviewFileModified"
    end
end

return M
