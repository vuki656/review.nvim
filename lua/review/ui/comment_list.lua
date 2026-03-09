local comment_types_module = require("review.comment_types")
local paths = require("review.core.paths")
local state = require("review.state")
local ui_util = require("review.ui.util")

local has_devicons, devicons = pcall(require, "nvim-web-devicons")

---@param filename string
---@return string icon, string|nil highlight
local function get_file_icon(filename)
    if paths.is_test_file(filename) then
        return "\u{f0668}", "ReviewFileModified"
    end
    if has_devicons then
        local icon, highlight = devicons.get_icon(filename, vim.fn.fnamemodify(filename, ":e"), { default = true })
        return (icon or "") .. " ", highlight
    end
    return "", nil
end

local comment_types = comment_types_module.TYPES

local M = {}

---@class CommentListComponent
---@field bufnr number
---@field winid number

---@type CommentListComponent|nil
M.current = nil

---@type table
local callbacks = {}

local active_timers = {
    scroll_timer = nil,
}

---@type "flat"|"tree"
local view_mode = "flat"

local collapsed_dirs = {}

local highlight_ns = vim.api.nvim_create_namespace("review_comment_list")

local INDENT_PIPE = "\u{2502} "
local INDENT_TEE = "\u{251c} "
local INDENT_ELBOW = "\u{2514} "
local INDENT_SPACE = "  "

local FOLDER_ICON = "\u{f07b} "

---@class CommentListNode
---@field type "file_header"|"dir_header"|"comment"
---@field comment ReviewComment|nil
---@field path string|nil
---@field dir_path string|nil
---@field depth number
---@field is_last boolean
---@field parent_last boolean[]

---Truncate text to fit within a width, adding ellipsis
---@param text string
---@param max_width number
---@return string
local function truncate_text(text, max_width)
    local single_line = text:gsub("\n", " ")
    if #single_line > max_width then
        return single_line:sub(1, max_width - 1) .. "\u{2026}"
    end
    return single_line
end

---Build flat view nodes from comments
---@param comments ReviewComment[]
---@return CommentListNode[]
local function build_flat_nodes(comments)
    local nodes = {}
    local grouped = {}
    local file_order = {}

    for _, comment in ipairs(comments) do
        if not grouped[comment.file] then
            grouped[comment.file] = {}
            table.insert(file_order, comment.file)
        end
        table.insert(grouped[comment.file], comment)
    end

    for _, file_path in ipairs(file_order) do
        table.insert(nodes, {
            type = "file_header",
            path = file_path,
            depth = 0,
            is_last = false,
            parent_last = {},
        })

        local file_comments = grouped[file_path]
        for _, comment in ipairs(file_comments) do
            table.insert(nodes, {
                type = "comment",
                comment = comment,
                depth = 0,
                is_last = false,
                parent_last = {},
            })
        end
    end

    return nodes
end

---Split a path into directory parts and filename
---@param file_path string
---@return string[] parts
local function split_path(file_path)
    local parts = {}
    for segment in file_path:gmatch("[^/]+") do
        table.insert(parts, segment)
    end
    return parts
end

---Build tree structure from comments
---@param comments ReviewComment[]
---@return CommentListNode[]
local function build_tree_nodes(comments)
    local grouped = {}
    local file_order = {}

    for _, comment in ipairs(comments) do
        if not grouped[comment.file] then
            grouped[comment.file] = {}
            table.insert(file_order, comment.file)
        end
        table.insert(grouped[comment.file], comment)
    end

    local tree = {}

    local function ensure_dir(parts, depth)
        local current = tree
        for index = 1, depth do
            local part = parts[index]
            if not current[part] then
                current[part] = { _children = {}, _order = {} }
            end
            if not current._order then
                current._order = {}
            end
            local found = false
            for _, existing in ipairs(current._order or {}) do
                if existing == part then
                    found = true
                    break
                end
            end
            if not found then
                table.insert(current._order or {}, part)
            end
            current = current[part]
        end
        return current
    end

    tree._order = {}
    tree._children = {}

    for _, file_path in ipairs(file_order) do
        local parts = split_path(file_path)
        if #parts > 1 then
            local dir_node = ensure_dir(parts, #parts - 1)
            if not dir_node._files then
                dir_node._files = {}
                dir_node._file_order = {}
            end
            dir_node._files[file_path] = grouped[file_path]
            table.insert(dir_node._file_order, file_path)
        else
            if not tree._files then
                tree._files = {}
                tree._file_order = {}
            end
            tree._files[file_path] = grouped[file_path]
            table.insert(tree._file_order, file_path)
        end
    end

    local nodes = {}

    local function flatten(node, depth, parent_last)
        local items = {}

        if node._order then
            for _, dir_name in ipairs(node._order) do
                table.insert(items, { type = "dir", name = dir_name, child = node[dir_name] })
            end
        end

        if node._file_order then
            for _, file_path in ipairs(node._file_order) do
                table.insert(items, { type = "file", path = file_path, comments = node._files[file_path] })
            end
        end

        for item_index, item in ipairs(items) do
            local is_last = item_index == #items

            if item.type == "dir" then
                    local comment_count = 0
                local function count_comments(sub_node)
                    if sub_node._files then
                        for _, file_comments in pairs(sub_node._files) do
                            comment_count = comment_count + #file_comments
                        end
                    end
                    if sub_node._order then
                        for _, child_name in ipairs(sub_node._order) do
                            count_comments(sub_node[child_name])
                        end
                    end
                end
                count_comments(item.child)

                table.insert(nodes, {
                    type = "dir_header",
                    dir_path = item.name,
                    path = item.name,
                    depth = depth,
                    is_last = is_last,
                    parent_last = vim.deepcopy(parent_last),
                    comment_count = comment_count,
                })

                if not collapsed_dirs[item.name] then
                    local child_parent_last = vim.deepcopy(parent_last)
                    table.insert(child_parent_last, is_last)
                    flatten(item.child, depth + 1, child_parent_last)
                end
            elseif item.type == "file" then
                table.insert(nodes, {
                    type = "file_header",
                    path = item.path,
                    depth = depth,
                    is_last = is_last and #item.comments == 0,
                    parent_last = vim.deepcopy(parent_last),
                })

                local comment_parent_last = vim.deepcopy(parent_last)
                table.insert(comment_parent_last, is_last)

                for comment_index, comment in ipairs(item.comments) do
                    local is_last_comment = comment_index == #item.comments
                    table.insert(nodes, {
                        type = "comment",
                        comment = comment,
                        depth = depth + 1,
                        is_last = is_last_comment,
                        parent_last = vim.deepcopy(comment_parent_last),
                    })
                end
            end
        end
    end

    flatten(tree, 0, {})
    return nodes
end

---Build indent prefix for tree view
---@param node CommentListNode
---@return string
local function tree_indent(node)
    if node.depth == 0 then
        return ""
    end

    local prefix = ""
    for depth_index = 1, node.depth - 1 do
        if node.parent_last[depth_index] then
            prefix = prefix .. INDENT_SPACE
        else
            prefix = prefix .. INDENT_PIPE
        end
    end

    if node.is_last then
        prefix = prefix .. INDENT_ELBOW
    else
        prefix = prefix .. INDENT_TEE
    end

    return prefix
end

---Render the comment list to the buffer
---@param bufnr number
---@param nodes CommentListNode[]
---@return table<number, CommentListNode>
local function render(bufnr, nodes)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return {}
    end

    local lines = {}
    local highlights = {}
    local line_map = {}

    if #nodes == 0 then
        ui_util.with_modifiable(bufnr, function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "  No comments" })
            vim.api.nvim_buf_clear_namespace(bufnr, highlight_ns, 0, -1)
            vim.api.nvim_buf_add_highlight(bufnr, highlight_ns, "ReviewCommentListEmpty", 0, 0, -1)
        end)
        return {}
    end

    for index, node in ipairs(nodes) do
        if view_mode == "flat" then
            if node.type == "file_header" then
                local file_icon, file_icon_highlight = get_file_icon(node.path)
                local line = "  " .. file_icon .. node.path
                table.insert(lines, line)
                if file_icon_highlight and #file_icon > 0 then
                    table.insert(highlights, {
                        line = index - 1,
                        group = file_icon_highlight,
                        col_start = 2,
                        col_end = 2 + #file_icon,
                    })
                end
                table.insert(highlights, {
                    line = index - 1,
                    group = "ReviewCommentListFile",
                    col_start = 2 + #file_icon,
                    col_end = -1,
                })
                line_map[index] = node
            elseif node.type == "comment" then
                local comment = node.comment
                local type_info = comment_types[comment.type]
                local icon = type_info and type_info.icon or "?"
                local text = truncate_text(comment.text, 40)
                local line = "    " .. icon .. " " .. text
                table.insert(lines, line)

                local icon_highlight = type_info and type_info.highlight or "ReviewCommentNote"
                table.insert(highlights, {
                    line = index - 1,
                    group = icon_highlight,
                    col_start = 4,
                    col_end = 4 + #icon,
                })
                table.insert(highlights, {
                    line = index - 1,
                    group = "ReviewCommentText",
                    col_start = 4 + #icon + 1,
                    col_end = -1,
                })
                line_map[index] = node
            end
        else
            local prefix = tree_indent(node)
            if node.type == "dir_header" then
                local count_str = " (" .. (node.comment_count or 0) .. ")"
                local collapsed_marker = collapsed_dirs[node.dir_path] and " \u{f054}" or ""
                local line = "  " .. prefix .. FOLDER_ICON .. node.path .. count_str .. collapsed_marker
                table.insert(lines, line)
                table.insert(highlights, {
                    line = index - 1,
                    group = "ReviewTreeDirectory",
                    col_start = 0,
                    col_end = -1,
                })
                if #prefix > 0 then
                    table.insert(highlights, {
                        line = index - 1,
                        group = "ReviewTreeIndent",
                        col_start = 2,
                        col_end = 2 + #prefix,
                    })
                end
                line_map[index] = node
            elseif node.type == "file_header" then
                local filename = vim.fn.fnamemodify(node.path, ":t")
                local file_icon, file_icon_highlight = get_file_icon(node.path)
                local line = "  " .. prefix .. file_icon .. filename
                table.insert(lines, line)
                local content_start = 2 + #prefix
                if file_icon_highlight and #file_icon > 0 then
                    table.insert(highlights, {
                        line = index - 1,
                        group = file_icon_highlight,
                        col_start = content_start,
                        col_end = content_start + #file_icon,
                    })
                end
                table.insert(highlights, {
                    line = index - 1,
                    group = "ReviewCommentListFile",
                    col_start = content_start + #file_icon,
                    col_end = -1,
                })
                if #prefix > 0 then
                    table.insert(highlights, {
                        line = index - 1,
                        group = "ReviewTreeIndent",
                        col_start = 2,
                        col_end = 2 + #prefix,
                    })
                end
                line_map[index] = node
            elseif node.type == "comment" then
                local comment = node.comment
                local type_info = comment_types[comment.type]
                local icon = type_info and type_info.icon or "?"
                local text = truncate_text(comment.text, 35)
                local line = "  " .. prefix .. icon .. " " .. text
                table.insert(lines, line)

                local icon_highlight = type_info and type_info.highlight or "ReviewCommentNote"
                local icon_start = 2 + #prefix
                table.insert(highlights, {
                    line = index - 1,
                    group = icon_highlight,
                    col_start = icon_start,
                    col_end = icon_start + #icon,
                })
                table.insert(highlights, {
                    line = index - 1,
                    group = "ReviewCommentText",
                    col_start = icon_start + #icon + 1,
                    col_end = -1,
                })
                if #prefix > 0 then
                    table.insert(highlights, {
                        line = index - 1,
                        group = "ReviewTreeIndent",
                        col_start = 2,
                        col_end = 2 + #prefix,
                    })
                end
                line_map[index] = node
            end
        end
    end

    ui_util.with_modifiable(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_clear_namespace(bufnr, highlight_ns, 0, -1)

        for _, highlight in ipairs(highlights) do
            vim.api.nvim_buf_add_highlight(
                bufnr,
                highlight_ns,
                highlight.group,
                highlight.line,
                highlight.col_start,
                highlight.col_end
            )
        end
    end)

    return line_map
end

---@type table<number, CommentListNode>
local current_line_map = {}

---@type CommentListNode[]
local current_nodes = {}

---Build nodes from current state
---@return CommentListNode[]
local function build_nodes()
    local comments = state.get_all_comments()
    if view_mode == "flat" then
        return build_flat_nodes(comments)
    else
        return build_tree_nodes(comments)
    end
end

---Setup keymaps for the comment list buffer
---@param bufnr number
local function setup_keymaps(bufnr)
    local map = ui_util.create_buffer_mapper(bufnr)

    map("j", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local line_count = vim.api.nvim_buf_line_count(M.current.bufnr)
        local next_line = line + 1

        if next_line <= line_count then
            vim.api.nvim_win_set_cursor(0, { next_line, 0 })
        end
    end, { nowait = true, desc = "Next item" })

    map("k", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local prev_line = line - 1

        if prev_line >= 1 then
            vim.api.nvim_win_set_cursor(0, { prev_line, 0 })
        end
    end, { nowait = true, desc = "Previous item" })

    map("<CR>", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local node = current_line_map[line]
        if not node then
            return
        end

        if node.type == "dir_header" and node.dir_path then
            if collapsed_dirs[node.dir_path] then
                collapsed_dirs[node.dir_path] = nil
            else
                collapsed_dirs[node.dir_path] = true
            end
            M.refresh()
            return
        end

        if node.type == "comment" and node.comment then
            if callbacks.on_comment_select then
                callbacks.on_comment_select(node.comment)
            end
        end
    end, { nowait = true, desc = "Go to comment" })

    map("d", function()
        if not M.current then
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local node = current_line_map[line]
        if not node or node.type ~= "comment" or not node.comment then
            return
        end

        ui_util.confirm("Delete comment?", function()
            if callbacks.on_comment_delete then
                callbacks.on_comment_delete(node.comment)
            end

            M.refresh()
        end)
    end, { nowait = true, desc = "Delete comment" })

    map("t", function()
        if view_mode == "flat" then
            view_mode = "tree"
        else
            view_mode = "flat"
        end
        M.refresh()
    end, { nowait = true, desc = "Toggle flat/tree" })

    local panel_keymaps = require("review.ui.panel_keymaps")
    panel_keymaps.setup(bufnr, {
        tab_target = "get_file_tree",
        h_target = "get_commit_list",
        l_target = nil,
    }, function()
        if callbacks.on_close then
            callbacks.on_close()
        end
    end, active_timers, map, callbacks.on_escape)
end

---Create the comment list component
---@param layout_component ReviewLayoutComponent
---@param cbs table
---@return CommentListComponent
function M.create(layout_component, cbs)
    callbacks = cbs

    M.current = {
        bufnr = layout_component.bufnr,
        winid = layout_component.winid,
    }

    current_nodes = build_nodes()
    current_line_map = render(layout_component.bufnr, current_nodes)
    setup_keymaps(layout_component.bufnr)

    vim.wo[layout_component.winid].spell = false

    return M.current
end

---Refresh the comment list (re-fetch and re-render)
function M.refresh()
    if not M.current then
        return
    end

    if not vim.api.nvim_buf_is_valid(M.current.bufnr) then
        return
    end

    current_nodes = build_nodes()
    current_line_map = render(M.current.bufnr, current_nodes)
end

---Destroy the component
function M.destroy()
    ui_util.destroy_timers(active_timers)
    callbacks = {}
    current_line_map = {}
    current_nodes = {}
    collapsed_dirs = {}
    view_mode = "flat"
    M.current = nil
end

return M
