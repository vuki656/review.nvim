local async = require("review.core.async")
local git = require("review.core.git")
local state = require("review.state")
local ui_util = require("review.ui.util")

local M = {}

-- Generation counter for discarding stale async results
local generation = 0

-- Tracks which directory paths are collapsed in tree view
local collapsed_dirs = {}

-- Optional devicons support
local has_devicons, devicons = pcall(require, "nvim-web-devicons")

---Check if a filename is a test or spec file
---@param filename string
---@return boolean
local function is_test_file(filename)
    local basename = vim.fn.fnamemodify(filename, ":t")
    return basename:match("^test[_.]")
        or basename:match("[_.]test%.")
        or basename:match("[_.]spec%.")
        or basename:match("^spec[_.]")
        or basename:match("_test%.")
        or basename:match("_spec%.")
        ~= nil
end

---Get file icon from devicons or fallback
---@param filename string
---@return string icon, string|nil highlight
local function get_file_icon(filename)
    if is_test_file(filename) then
        return "󰂓", "ReviewFileModified"
    end
    if has_devicons then
        local icon, hl = devicons.get_icon(filename, vim.fn.fnamemodify(filename, ":e"), { default = true })
        return icon or "", hl
    end
    return "", nil
end

---@class FileTreeComponent
---@field bufnr number
---@field winid number
---@field files string[]
---@field nodes table[]

---@type FileTreeComponent|nil
M.current = nil

---@type "list"|"tree"
M.view_mode = "list"

-- Active timers (for cleanup on destroy)
local active_timers = {
    select_timer = nil,
    scroll_timer = nil,
    push_timer = nil,
}

-- Footer state
local footer_state = { unpushed_count = nil, spinner_frame = 0 }
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@class FileNode
---@field path string|nil
---@field dir_path string|nil
---@field text string
---@field is_file boolean
---@field is_separator boolean
---@field reviewed boolean
---@field in_reviewed_section boolean
---@field in_deleted_section boolean
---@field git_status_hl string
---@field file_icon_hl string|nil
---@field dot_start number
---@field dot_end number
---@field file_icon_start number
---@field file_icon_end number
---@field filename_start number
---@field filename_end number

---Check if a file is "non-important" (tests, index/barrel, config, type defs)
---@param path string
---@return boolean
local function is_non_important_file(path)
    local basename = vim.fn.fnamemodify(path, ":t")

    -- Test files
    if path:match("test/") or path:match("tests/") or path:match("__tests__/") then
        return true
    end
    if basename:match("%.test%.") or basename:match("%.spec%.") then
        return true
    end

    -- Index/barrel files
    if
        basename == "index.ts"
        or basename == "index.js"
        or basename == "index.tsx"
        or basename == "index.jsx"
        or basename == "index.mjs"
        or basename == "index.cjs"
    then
        return true
    end

    -- Lockfiles
    if
        basename == "package-lock.json"
        or basename == "yarn.lock"
        or basename == "pnpm-lock.yaml"
        or basename == "bun.lock"
    then
        return true
    end

    -- Config files
    if basename:match("%.config%.") then
        return true
    end
    if basename:match("^tsconfig.*%.json$") then
        return true
    end
    if basename == "package.json" then
        return true
    end
    if basename:match("^%.eslintrc") or basename:match("^%.prettierrc") then
        return true
    end

    -- Type definition files
    if basename:match("%.d%.ts$") or basename:match("%.d%.mts$") or basename:match("%.d%.cts$") then
        return true
    end

    return false
end

---Partition a file list into regular and non-important files
---@param file_list string[]
---@return string[] regular
---@return string[] non_important
local function partition_files(file_list)
    local regular = {}
    local non_important = {}
    for _, file in ipairs(file_list) do
        if is_non_important_file(file) then
            table.insert(non_important, file)
        else
            table.insert(regular, file)
        end
    end
    return regular, non_important
end

---Create a sub-separator node for non-important files
---@param count number
---@return FileNode
local function create_sub_separator_node()
    local label = "  Other"
    return {
        path = nil,
        text = label,
        is_file = false,
        is_separator = true,
        is_sub_separator = true,
        reviewed = false,
        in_reviewed_section = false,
        in_deleted_section = false,
        git_status_hl = "ReviewFileFaded",
        file_icon_hl = nil,
        dot_start = 0,
        dot_end = 0,
        file_icon_start = 0,
        file_icon_end = 0,
        filename_start = 0,
        filename_end = 0,
    }
end

---Get git status highlight
---@param git_status string "added"|"modified"|"deleted"|"renamed"
---@return string highlight
local function get_git_status_hl(git_status)
    if git_status == "added" then
        return "ReviewGitAdded"
    elseif git_status == "deleted" then
        return "ReviewGitDeleted"
    elseif git_status == "renamed" then
        return "ReviewGitRenamed"
    else
        return "ReviewGitModified"
    end
end

---Create a single file node
---@param file string
---@param in_reviewed_section boolean Whether file is in the reviewed section (filename faded)
---@param in_deleted_section boolean Whether file is in the deleted section
---@param base string|nil Base commit for git status comparison
---@param git_status GitFileStatus|nil Pre-fetched git status (avoids subprocess call if provided)
---@param old_path string|nil Original path for renamed files
---@return FileNode
local function create_file_node(file, in_reviewed_section, in_deleted_section, base, git_status, old_path)
    local is_history_mode = base ~= nil and base ~= "HEAD"
    -- In history mode, don't show reviewed state
    local reviewed = not is_history_mode and state.is_reviewed(file)
    local file_icon, file_icon_hl = get_file_icon(file)

    -- Use provided status or fetch it (fallback for backwards compatibility)
    git_status = git_status or git.get_file_status(file, base)
    local git_status_hl = get_git_status_hl(git_status)

    -- Get just the filename
    local filename = vim.fn.fnamemodify(file, ":t")
    -- Get the directory path (empty if file is in root)
    local dir = vim.fn.fnamemodify(file, ":h")
    local path_suffix = dir ~= "." and ("  " .. file) or ""

    -- For renamed files, show old path as suffix instead
    if old_path then
        path_suffix = "  ← " .. old_path
    end

    local padding = "  "
    local dot_part = "● "
    local file_icon_part = file_icon .. " "
    local filename_part = filename
    local text = padding .. dot_part .. file_icon_part .. filename_part .. path_suffix

    local offset = #padding
    return {
        path = file,
        text = text,
        is_file = true,
        is_separator = false,
        reviewed = reviewed,
        in_reviewed_section = in_reviewed_section,
        in_deleted_section = in_deleted_section or false,
        git_status_hl = git_status_hl,
        file_icon_hl = file_icon_hl,
        -- Byte offsets for highlighting
        dot_start = offset,
        dot_end = offset + #dot_part,
        file_icon_start = offset + #dot_part,
        file_icon_end = offset + #dot_part + #file_icon_part,
        filename_start = offset + #dot_part + #file_icon_part,
        filename_end = offset + #dot_part + #file_icon_part + #filename_part,
    }
end

---Create a left-aligned separator line
---@param label string The label text (e.g., "󰏫 Changes (5)")
---@param width number The total width
---@param char string The separator character (─ or ═)
---@return string
local function create_left_aligned_separator(label, width, char)
    local prefix = "  "
    local label_display_width = vim.fn.strdisplaywidth(label)
    local remaining = width - #prefix - label_display_width - 1
    if remaining < 2 then
        return prefix .. label
    end
    return prefix .. label .. " " .. string.rep(char, remaining)
end

---Create a header node
---@param icon string
---@param title string
---@param count number
---@param hl string
---@param char string separator character
---@return FileNode
local function create_header_node(icon, title, count, hl, char)
    return {
        path = nil,
        separator_label = icon .. " " .. title .. " (" .. count .. ")",
        separator_char = char,
        text = "", -- Will be filled in render
        is_file = false,
        is_separator = true,
        is_header = true,
        header_hl = hl,
        reviewed = false,
        in_reviewed_section = false,
        in_deleted_section = false,
        git_status_hl = hl,
        file_icon_hl = nil,
        dot_start = 0,
        dot_end = 0,
        file_icon_start = 0,
        file_icon_end = 0,
        filename_start = 0,
        filename_end = 0,
    }
end

---Create file nodes from file list
---@param files string[]
---@param base string|nil Base commit for comparison
---@param base_end string|nil End of commit range
---@param cached_unstaged_set table<string, boolean>|nil Pre-fetched unstaged set (avoids duplicate call)
---@return FileNode[]
local function create_nodes(files, base, base_end, cached_unstaged_set)
    local is_history_mode = base ~= nil and base ~= "HEAD"

    -- Batch fetch all git statuses in one call (major perf win)
    local status_map, rename_map = git.get_all_file_statuses(files, base, base_end)
    -- Use cached unstaged set or fetch if not provided
    local unstaged_set = cached_unstaged_set or (not is_history_mode and git.get_unstaged_files() or {})

    -- Categorize files by git status and staged status
    local unstaged_modified = {} -- modified, not staged
    local unstaged_added = {} -- added/new, not staged
    local unstaged_deleted = {} -- deleted, not staged
    local unstaged_renamed = {} -- renamed, not staged
    local staged_files = {} -- all staged files

    for _, file in ipairs(files) do
        local git_status = status_map[file] or "modified"

        if is_history_mode then
            -- In history mode, no staging - just group by status
            if git_status == "deleted" then
                table.insert(unstaged_deleted, file)
            elseif git_status == "added" then
                table.insert(unstaged_added, file)
            elseif git_status == "renamed" then
                table.insert(unstaged_renamed, file)
            else
                table.insert(unstaged_modified, file)
            end
        else
            -- Normal mode: check staging
            -- A file is only "fully staged" if it has staged changes AND no unstaged changes
            local is_staged = state.is_reviewed(file)
            local has_unstaged = unstaged_set[file] or false

            if is_staged and not has_unstaged then
                -- Fully staged (no additional unstaged modifications)
                table.insert(staged_files, file)
            elseif git_status == "deleted" then
                table.insert(unstaged_deleted, file)
            elseif git_status == "added" then
                table.insert(unstaged_added, file)
            elseif git_status == "renamed" then
                table.insert(unstaged_renamed, file)
            else
                table.insert(unstaged_modified, file)
            end
        end
    end

    local nodes = {}

    ---Insert file nodes for a group, partitioned into regular and non-important
    ---@param file_list string[]
    ---@param in_reviewed boolean
    ---@param in_deleted boolean
    ---@param use_rename boolean
    local function insert_partitioned_files(file_list, in_reviewed, in_deleted, use_rename)
        local regular, non_important = partition_files(file_list)
        for _, file in ipairs(regular) do
            local old_path = use_rename and rename_map[file] or nil
            table.insert(nodes, create_file_node(file, in_reviewed, in_deleted, base, status_map[file], old_path))
        end
        if #non_important > 0 then
            table.insert(nodes, create_sub_separator_node())
            for _, file in ipairs(non_important) do
                local old_path = use_rename and rename_map[file] or nil
                local node = create_file_node(file, in_reviewed, in_deleted, base, status_map[file], old_path)
                node.is_non_important = true
                table.insert(nodes, node)
            end
        end
    end

    -- 1. Modified files (unstaged)
    if #unstaged_modified > 0 then
        table.insert(nodes, create_header_node("󰏫", "Changes", #unstaged_modified, "ReviewGitModified", "═"))
        insert_partitioned_files(unstaged_modified, false, false, false)
    end

    -- 2. New/Added files (unstaged)
    if #unstaged_added > 0 then
        table.insert(nodes, create_header_node("󰐕", "New", #unstaged_added, "ReviewGitAdded", "═"))
        insert_partitioned_files(unstaged_added, false, false, false)
    end

    -- 3. Renamed files (unstaged)
    if #unstaged_renamed > 0 then
        table.insert(nodes, create_header_node("󰁔", "Renamed", #unstaged_renamed, "ReviewGitRenamed", "═"))
        insert_partitioned_files(unstaged_renamed, false, false, true)
    end

    -- 4. Deleted files (unstaged)
    if #unstaged_deleted > 0 then
        table.insert(nodes, create_header_node("󰩹", "Deleted", #unstaged_deleted, "ReviewGitDeleted", "═"))
        insert_partitioned_files(unstaged_deleted, false, true, false)
    end

    -- 5. Staged files - with double border (only in normal mode)
    if #staged_files > 0 then
        table.insert(nodes, create_header_node("󰄬", "Staged", #staged_files, "ReviewFileReviewed", "═"))
        insert_partitioned_files(staged_files, true, false, false)
    end

    return nodes
end

---Create tree nodes from file list (hierarchical directory view)
---@param files string[]
---@param base string|nil Base commit for comparison
---@param base_end string|nil End of commit range
---@param _cached_unstaged_set table<string, boolean>|nil Pre-fetched unstaged set (unused in tree view, kept for API consistency)
---@return FileNode[]
local function create_tree_nodes(files, base, base_end, _cached_unstaged_set)
    local is_history_mode = base ~= nil and base ~= "HEAD"

    -- Batch fetch all git statuses in one call (major perf win)
    local status_map = git.get_all_file_statuses(files, base, base_end)

    -- Build directory tree structure
    local tree = {}
    for _, file in ipairs(files) do
        local parts = {}
        for part in file:gmatch("[^/]+") do
            table.insert(parts, part)
        end

        local current = tree
        for i, part in ipairs(parts) do
            if i == #parts then
                -- File
                current[part] = { __file = file }
            else
                -- Directory
                current[part] = current[part] or {}
                current = current[part]
            end
        end
    end

    local function count_dir_files(entry)
        local total = 0
        local staged = 0
        for key, value in pairs(entry) do
            if key ~= "__file" then
                if value.__file then
                    total = total + 1
                    if not is_history_mode and state.is_reviewed(value.__file) then
                        staged = staged + 1
                    end
                else
                    local child_total, child_staged = count_dir_files(value)
                    total = total + child_total
                    staged = staged + child_staged
                end
            end
        end
        return total, staged
    end

    -- Flatten tree into nodes with indentation
    local nodes = {}

    -- Indent markers
    local INDENT_MARKER_PIPE = "│ " -- continuing line
    local INDENT_MARKER_BRANCH = "├ " -- branch (has siblings after)
    local INDENT_MARKER_LAST = "└ " -- last item (no siblings after)
    local INDENT_MARKER_SPACE = "  " -- empty space

    local function add_tree_entry(name, entry, depth, indent_stack, is_last, parent_path)
        -- Build indent string with markers
        local indent_parts = {}
        local indent_ranges = {} -- Track positions for highlighting
        local left_pad_len = 1 -- 1 char left padding
        local pos = left_pad_len

        for _, marker in ipairs(indent_stack) do
            table.insert(indent_parts, marker)
            table.insert(indent_ranges, { start = pos, finish = pos + #marker })
            pos = pos + #marker
        end

        -- Add current level marker
        if depth > 0 then
            local marker = is_last and INDENT_MARKER_LAST or INDENT_MARKER_BRANCH
            table.insert(indent_parts, marker)
            table.insert(indent_ranges, { start = pos, finish = pos + #marker })
        end

        local indent = table.concat(indent_parts)

        if entry.__file then
            -- It's a file
            local file = entry.__file
            local git_status = status_map[file] or "modified"
            local git_status_hl = get_git_status_hl(git_status)
            local reviewed = not is_history_mode and state.is_reviewed(file)
            local file_icon, file_icon_hl = get_file_icon(file)

            local dot_part = "● "
            local left_pad = " "
            local text = left_pad .. indent .. dot_part .. file_icon .. " " .. name

            local offset = #left_pad + #indent
            table.insert(nodes, {
                path = file,
                text = text,
                is_file = true,
                is_separator = false,
                is_directory = false,
                is_tree_view = true,
                reviewed = reviewed,
                in_reviewed_section = false,
                in_deleted_section = git_status == "deleted",
                git_status_hl = git_status_hl,
                file_icon_hl = file_icon_hl,
                indent_ranges = indent_ranges,
                dot_start = offset,
                dot_end = offset + #dot_part,
                file_icon_start = offset + #dot_part,
                file_icon_end = offset + #dot_part + #file_icon + 1,
                filename_start = offset + #dot_part + #file_icon + 1,
                filename_end = #text,
            })
        else
            -- It's a directory
            local dir_path = parent_path and (parent_path .. "/" .. name) or name
            local is_collapsed = collapsed_dirs[dir_path] or false
            local folder_icon = is_collapsed and "󰉖" or "󰉋"
            local dir_total, dir_staged = count_dir_files(entry)
            local dir_all_staged = dir_total > 0 and dir_staged == dir_total
            local left_pad = " "
            local text = left_pad .. indent .. folder_icon .. " " .. name

            local offset = #left_pad + #indent
            table.insert(nodes, {
                path = nil,
                dir_path = dir_path,
                text = text,
                is_file = false,
                is_separator = false,
                is_directory = true,
                is_tree_view = true,
                reviewed = dir_all_staged,
                dir_partially_staged = dir_staged > 0 and not dir_all_staged,
                in_reviewed_section = false,
                in_deleted_section = false,
                git_status_hl = "ReviewTreeDirectory",
                file_icon_hl = nil,
                indent_ranges = indent_ranges,
                dir_icon_start = offset,
                dir_icon_end = offset + #folder_icon,
                dirname_start = offset + #folder_icon + 1,
                dirname_end = #text,
            })

            if not is_collapsed then
                -- Sort entries: directories first, then files
                local dirs, files_list = {}, {}
                for k, v in pairs(entry) do
                    if v.__file then
                        table.insert(files_list, { name = k, entry = v })
                    else
                        table.insert(dirs, { name = k, entry = v })
                    end
                end
                table.sort(dirs, function(a, b)
                    return a.name < b.name
                end)
                table.sort(files_list, function(a, b)
                    return a.name < b.name
                end)

                -- Build new indent stack for children
                local child_indent_stack = { unpack(indent_stack) }
                if depth > 0 then
                    -- Add continuation marker or space depending on whether parent has more siblings
                    table.insert(child_indent_stack, is_last and INDENT_MARKER_SPACE or INDENT_MARKER_PIPE)
                end

                local all_children = {}
                for _, d in ipairs(dirs) do
                    table.insert(all_children, { name = d.name, entry = d.entry })
                end
                for _, f in ipairs(files_list) do
                    table.insert(all_children, { name = f.name, entry = f.entry })
                end

                for i, child in ipairs(all_children) do
                    local child_is_last = (i == #all_children)
                    add_tree_entry(child.name, child.entry, depth + 1, child_indent_stack, child_is_last, dir_path)
                end
            end
        end
    end

    -- Sort root level
    local root_dirs, root_files = {}, {}
    for k, v in pairs(tree) do
        if v.__file then
            table.insert(root_files, { name = k, entry = v })
        else
            table.insert(root_dirs, { name = k, entry = v })
        end
    end
    table.sort(root_dirs, function(a, b)
        return a.name < b.name
    end)
    table.sort(root_files, function(a, b)
        return a.name < b.name
    end)

    local all_root = {}
    for _, d in ipairs(root_dirs) do
        table.insert(all_root, { name = d.name, entry = d.entry })
    end
    for _, f in ipairs(root_files) do
        table.insert(all_root, { name = f.name, entry = f.entry })
    end

    for i, item in ipairs(all_root) do
        local is_last = (i == #all_root)
        add_tree_entry(item.name, item.entry, 0, {}, is_last, nil)
    end

    return nodes
end

---Update the file tree winbar with file count
---@param winid number
---@param file_count number
local function update_winbar(winid, file_count, is_refreshing)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end
    local suffix = is_refreshing and " %#ReviewWinBarCount#[refreshing...]%*" or ""
    vim.wo[winid].winbar = "%#ReviewWinBar#  Files%* %#ReviewWinBarCount#(" .. file_count .. ")%*" .. suffix
end

---Render the file tree to buffer
---@param bufnr number
---@param nodes FileNode[]
---@param winid number|nil
local function render_to_buffer(bufnr, nodes, winid)
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true

    -- Get window width for centered separators
    local width = 40 -- default
    if winid and vim.api.nvim_win_is_valid(winid) then
        width = vim.api.nvim_win_get_width(winid)
    end

    local lines = {}
    local separator_info = {} -- Store info for highlighting separators

    for idx, node in ipairs(nodes) do
        if node.is_separator and node.separator_label and not node.is_sub_separator then
            -- Generate left-aligned separator for main headers
            local sep_text = create_left_aligned_separator(node.separator_label, width, node.separator_char or "─")
            table.insert(lines, sep_text)
            -- Find label position for highlighting
            local label_start = sep_text:find(node.separator_label, 1, true)
            if label_start then
                local icon = node.separator_label:match("^[^ ]+") or ""
                local icon_byte_len = #icon
                separator_info[idx] = {
                    label_start = label_start - 1,
                    icon_end = label_start - 1 + icon_byte_len,
                    label_end = label_start - 1 + #node.separator_label,
                }
            end
        else
            table.insert(lines, node.text)
        end
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    -- Apply highlights
    for i, node in ipairs(nodes) do
        if node.is_separator then
            -- Separator line - faded for dashes
            vim.api.nvim_buf_add_highlight(bufnr, -1, "ReviewFileFaded", i - 1, 0, -1)
            local info = separator_info[i]
            if info and not node.is_sub_separator then
                if node.is_logo then
                    -- Logo: color entire label with header_hl
                    vim.api.nvim_buf_add_highlight(
                        bufnr,
                        -1,
                        node.header_hl or "ReviewLogo",
                        i - 1,
                        info.label_start,
                        info.label_end
                    )
                else
                    -- Color the icon
                    if node.header_hl then
                        vim.api.nvim_buf_add_highlight(
                            bufnr,
                            -1,
                            node.header_hl,
                            i - 1,
                            info.label_start,
                            info.icon_end
                        )
                    end
                    -- Title and count in visible color (after icon)
                    vim.api.nvim_buf_add_highlight(bufnr, -1, "ReviewFilePath", i - 1, info.icon_end, info.label_end)
                end
            end
        elseif node.is_directory then
            -- Directory node (tree view)
            -- Indent markers
            if node.indent_ranges then
                for _, range in ipairs(node.indent_ranges) do
                    vim.api.nvim_buf_add_highlight(bufnr, -1, "ReviewTreeIndent", i - 1, range.start, range.finish)
                end
            end
            -- Folder icon and name
            if node.dir_icon_start then
                vim.api.nvim_buf_add_highlight(
                    bufnr,
                    -1,
                    "ReviewTreeDirectory",
                    i - 1,
                    node.dir_icon_start,
                    node.dir_icon_end
                )
            end
            if node.dirname_start then
                local dirname_hl = node.reviewed and "ReviewFileReviewed"
                    or (node.dir_partially_staged and "ReviewFileModified" or "ReviewTreeDirectory")
                vim.api.nvim_buf_add_highlight(
                    bufnr,
                    -1,
                    dirname_hl,
                    i - 1,
                    node.dirname_start,
                    node.dirname_end
                )
            end
        else
            -- File node
            -- Indent markers (tree view)
            if node.indent_ranges then
                for _, range in ipairs(node.indent_ranges) do
                    vim.api.nvim_buf_add_highlight(bufnr, -1, "ReviewTreeIndent", i - 1, range.start, range.finish)
                end
            end

            -- Git status dot - colored by status (green=added, orange=modified, red=deleted)
            vim.api.nvim_buf_add_highlight(bufnr, -1, node.git_status_hl, i - 1, node.dot_start, node.dot_end)

            -- File type icon (devicons color if available)
            if node.file_icon_hl then
                vim.api.nvim_buf_add_highlight(
                    bufnr,
                    -1,
                    node.file_icon_hl,
                    i - 1,
                    node.file_icon_start,
                    node.file_icon_end
                )
            end

            -- Filename and path coloring (green if reviewed)
            local filename_hl = node.reviewed and "ReviewFileReviewed"
                or (node.is_non_important and "ReviewFileFaded" or "ReviewFilePath")
            vim.api.nvim_buf_add_highlight(bufnr, -1, filename_hl, i - 1, node.filename_start, node.filename_end)
            vim.api.nvim_buf_add_highlight(bufnr, -1, "ReviewFilePathFaded", i - 1, node.filename_end, -1)
        end
    end

    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
end

---Render the footer (unpushed count or push spinner) below file nodes
---@param bufnr number
local function render_footer(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    if not M.current or not M.current.nodes then
        return
    end

    local node_count = #M.current.nodes
    local footer_lines = {}
    local footer_hls = {} -- { line_offset, hl_group, col_start, col_end }

    if state.state.is_pushing then
        footer_state.spinner_frame = (footer_state.spinner_frame % #SPINNER_FRAMES) + 1
        local text = "  " .. SPINNER_FRAMES[footer_state.spinner_frame] .. " Pushing..."
        table.insert(footer_lines, "")
        table.insert(footer_lines, text)
        table.insert(footer_hls, { 1, "ReviewFooterText", 0, -1 })
    elseif footer_state.unpushed_count and footer_state.unpushed_count > 0 then
        local count_str = tostring(footer_state.unpushed_count)
        local text = "  ↑ " .. count_str .. " unpushed"
        table.insert(footer_lines, "")
        table.insert(footer_lines, text)
        local prefix = "  ↑ "
        local prefix_len = #prefix
        table.insert(footer_hls, { 1, "ReviewFooterText", 0, prefix_len })
        table.insert(footer_hls, { 1, "ReviewFooterCount", prefix_len, prefix_len + #count_str })
        table.insert(footer_hls, { 1, "ReviewFooterText", prefix_len + #count_str, -1 })
    end

    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true

    -- Clear any existing footer lines (everything after node_count)
    local current_line_count = vim.api.nvim_buf_line_count(bufnr)
    if current_line_count > node_count then
        vim.api.nvim_buf_set_lines(bufnr, node_count, current_line_count, false, {})
    end

    -- Append footer lines
    if #footer_lines > 0 then
        vim.api.nvim_buf_set_lines(bufnr, node_count, node_count, false, footer_lines)
        for _, hl in ipairs(footer_hls) do
            local line_idx = node_count + hl[1]
            vim.api.nvim_buf_add_highlight(bufnr, -1, hl[2], line_idx, hl[3], hl[4])
        end
    end

    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].readonly = true
end

---Fetch unpushed count and re-render footer
local function update_footer()
    if not M.current then
        return
    end

    git.get_unpushed_count(function(count)
        footer_state.unpushed_count = count
        if M.current then
            render_footer(M.current.bufnr)
        end
    end)
end

---Show full path in floating window
local function show_full_path()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local node = M.get_node_at_line(line)
    if not node or not node.is_file then
        return
    end

    vim.lsp.util.open_floating_preview({ node.path }, "text", {
        border = "rounded",
        title = " Path ",
        title_pos = "center",
    })
end

---@type {lhs: string, desc: string, group: string}[]
local registered_keymaps = {}

---Get the registered keymaps for external use (e.g., welcome screen)
---@return {lhs: string, desc: string, group: string}[]
function M.get_registered_keymaps()
    return registered_keymaps
end

---Show help popup
local function show_help()
    local help = require("review.ui.help")
    help.show("File Tree", registered_keymaps)
end

---Create a centered spinner popup
---@param title string Window title
---@param message string Spinner text to display
---@param width number Window width
---@return { stop: fun() }
local function create_spinner(title, message, width)
    local frame = 0
    local spinner_buf = vim.api.nvim_create_buf(false, true)
    local spinner_win = vim.api.nvim_open_win(spinner_buf, false, {
        relative = "editor",
        row = math.floor(vim.o.lines / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = 1,
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
    })

    local timer = vim.uv.new_timer()
    timer:start(
        0,
        80,
        vim.schedule_wrap(function()
            if not vim.api.nvim_buf_is_valid(spinner_buf) then
                timer:stop()
                timer:close()
                return
            end
            frame = (frame % #SPINNER_FRAMES) + 1
            local text = " " .. SPINNER_FRAMES[frame] .. " " .. message
            vim.api.nvim_buf_set_lines(spinner_buf, 0, -1, false, { text })
        end)
    )

    return {
        stop = function()
            timer:stop()
            timer:close()
            if vim.api.nvim_win_is_valid(spinner_win) then
                vim.api.nvim_win_close(spinner_win, true)
            end
            if vim.api.nvim_buf_is_valid(spinner_buf) then
                vim.api.nvim_buf_delete(spinner_buf, { force = true })
            end
        end,
    }
end

local PROGRESS_WIDTH = 72
local PROGRESS_LOG_LINES = 12
local PROGRESS_HEIGHT = 1 + 1 + PROGRESS_LOG_LINES

local function create_commit_progress(title, message)
    local frame = 0
    local log_lines = {}
    local progress_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[progress_buf].bufhidden = "wipe"

    local separator = string.rep("─", PROGRESS_WIDTH)

    local initial_lines = { " " .. SPINNER_FRAMES[1] .. " " .. message, separator }
    for _ = 1, PROGRESS_LOG_LINES do
        table.insert(initial_lines, "")
    end
    vim.api.nvim_buf_set_lines(progress_buf, 0, -1, false, initial_lines)

    local progress_win = vim.api.nvim_open_win(progress_buf, false, {
        relative = "editor",
        row = math.floor((vim.o.lines - PROGRESS_HEIGHT) / 2) - 1,
        col = math.floor((vim.o.columns - PROGRESS_WIDTH) / 2),
        width = PROGRESS_WIDTH,
        height = PROGRESS_HEIGHT,
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
    })

    local timer = vim.uv.new_timer()
    timer:start(
        0,
        80,
        vim.schedule_wrap(function()
            if not vim.api.nvim_buf_is_valid(progress_buf) then
                timer:stop()
                timer:close()
                return
            end
            frame = (frame % #SPINNER_FRAMES) + 1
            local spinner_text = " " .. SPINNER_FRAMES[frame] .. " " .. message
            vim.api.nvim_buf_set_lines(progress_buf, 0, 1, false, { spinner_text })
        end)
    )

    return {
        stop = function()
            timer:stop()
            timer:close()
            if vim.api.nvim_win_is_valid(progress_win) then
                vim.api.nvim_win_close(progress_win, true)
            end
            if vim.api.nvim_buf_is_valid(progress_buf) then
                vim.api.nvim_buf_delete(progress_buf, { force = true })
            end
        end,
        add_line = function(line)
            if not vim.api.nvim_buf_is_valid(progress_buf) then
                return
            end
            table.insert(log_lines, " " .. line)
            local visible_lines = {}
            local start_index = math.max(1, #log_lines - PROGRESS_LOG_LINES + 1)
            for index = start_index, #log_lines do
                table.insert(visible_lines, log_lines[index])
            end
            while #visible_lines < PROGRESS_LOG_LINES do
                table.insert(visible_lines, "")
            end
            vim.api.nvim_buf_set_lines(progress_buf, 2, 2 + PROGRESS_LOG_LINES, false, visible_lines)
        end,
    }
end

---Open a floating commit popup with subject line and description area
---@param callbacks table
local function commit_flow(callbacks)
    if state.is_history_mode() then
        vim.notify("Cannot commit in history mode", vim.log.levels.WARN)
        return
    end

    local popup_width = 72
    local popup_height = 12
    local separator = string.rep("─", popup_width)

    local commit_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(commit_buf, 0, -1, false, { "", separator, "" })
    vim.bo[commit_buf].buftype = "acwrite"
    vim.bo[commit_buf].filetype = "gitcommit"

    local commit_win = vim.api.nvim_open_win(commit_buf, true, {
        relative = "editor",
        row = math.floor((vim.o.lines - popup_height) / 2),
        col = math.floor((vim.o.columns - popup_width) / 2),
        width = popup_width,
        height = popup_height,
        style = "minimal",
        border = "rounded",
        title = " Commit ",
        title_pos = "center",
        footer = " <CR> confirm │ <Tab> switch │ q/Esc cancel ",
        footer_pos = "center",
    })
    vim.wo[commit_win].cursorline = false
    vim.wo[commit_win].wrap = true

    local ns = vim.api.nvim_create_namespace("review_commit_popup")

    local function render_separator_highlight()
        vim.api.nvim_buf_clear_namespace(commit_buf, ns, 0, -1)
        local lines = vim.api.nvim_buf_get_lines(commit_buf, 0, -1, false)
        for index, line in ipairs(lines) do
            if line == separator then
                vim.api.nvim_buf_add_highlight(commit_buf, ns, "ReviewBorder", index - 1, 0, -1)
            end
        end
    end

    render_separator_highlight()

    local function make_separator_readonly()
        vim.api.nvim_buf_attach(commit_buf, false, {
            on_lines = function()
                vim.schedule(function()
                    if not vim.api.nvim_buf_is_valid(commit_buf) then
                        return
                    end
                    local lines = vim.api.nvim_buf_get_lines(commit_buf, 0, -1, false)
                    local has_separator = false
                    for _, line in ipairs(lines) do
                        if line == separator then
                            has_separator = true
                            break
                        end
                    end
                    if not has_separator then
                        local subject = lines[1] or ""
                        local description_lines = {}
                        for index = 2, #lines do
                            table.insert(description_lines, lines[index])
                        end
                        local restored = { subject, separator }
                        vim.list_extend(restored, description_lines)
                        vim.api.nvim_buf_set_lines(commit_buf, 0, -1, false, restored)
                    end
                    render_separator_highlight()
                end)
            end,
        })
    end

    make_separator_readonly()

    vim.cmd("startinsert")

    local closed = false

    local function close_popup()
        if closed then
            return
        end
        closed = true
        if vim.api.nvim_win_is_valid(commit_win) then
            vim.api.nvim_win_close(commit_win, true)
        end
        if vim.api.nvim_buf_is_valid(commit_buf) then
            vim.api.nvim_buf_delete(commit_buf, { force = true })
        end
    end

    local function confirm_commit()
        if closed then
            return
        end
        local lines = vim.api.nvim_buf_get_lines(commit_buf, 0, -1, false)
        local subject = vim.trim(lines[1] or "")

        if subject == "" then
            vim.notify("Commit message cannot be empty", vim.log.levels.WARN)
            return
        end

        local description_lines = {}
        local past_separator = false
        for index = 2, #lines do
            if lines[index] == separator then
                past_separator = true
            elseif past_separator then
                table.insert(description_lines, lines[index])
            end
        end

        while #description_lines > 0 and vim.trim(description_lines[#description_lines]) == "" do
            table.remove(description_lines)
        end
        local description = table.concat(description_lines, "\n")

        close_popup()

        local progress = create_commit_progress("Committing", "Committing...")

        git.commit_streaming(subject, progress.add_line, function(success, err)
            progress.stop()

            if success then
                vim.notify("Committed: " .. subject, vim.log.levels.INFO)
                if callbacks.on_commit_complete then
                    callbacks.on_commit_complete()
                end
            else
                vim.notify("Commit failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
            end
        end, description)
    end

    local function toggle_section()
        local cursor_row = vim.api.nvim_win_get_cursor(commit_win)[1]
        local lines = vim.api.nvim_buf_get_lines(commit_buf, 0, -1, false)
        local separator_row = nil
        for index, line in ipairs(lines) do
            if line == separator then
                separator_row = index
                break
            end
        end
        if not separator_row then
            return
        end
        if cursor_row <= separator_row then
            local target_row = separator_row + 1
            if target_row > #lines then
                vim.api.nvim_buf_set_lines(commit_buf, #lines, #lines, false, { "" })
            end
            vim.api.nvim_win_set_cursor(commit_win, { separator_row + 1, 0 })
        else
            vim.api.nvim_win_set_cursor(commit_win, { 1, 0 })
        end
        vim.cmd("startinsert!")
    end

    local function confirm_if_in_title()
        local cursor_row = vim.api.nvim_win_get_cursor(commit_win)[1]
        if cursor_row == 1 then
            confirm_commit()
        else
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
        end
    end

    local keymap_options = { buffer = commit_buf, nowait = true }
    vim.keymap.set("n", "q", close_popup, keymap_options)
    vim.keymap.set("n", "<Esc>", close_popup, keymap_options)
    vim.keymap.set("i", "<CR>", confirm_if_in_title, keymap_options)
    vim.keymap.set({ "n", "i" }, "<Tab>", toggle_section, keymap_options)

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = commit_buf,
        callback = confirm_commit,
    })
end

---Push to remote with spinner animation in footer
local function push_flow()
    if state.state.is_pushing then
        vim.notify("Already pushing...", vim.log.levels.WARN)
        return
    end

    if state.is_history_mode() then
        vim.notify("Cannot push in history mode", vim.log.levels.WARN)
        return
    end

    state.state.is_pushing = true
    footer_state.spinner_frame = 0

    -- Start spinner animation timer
    if active_timers.push_timer then
        active_timers.push_timer:stop()
        active_timers.push_timer:close()
    end
    active_timers.push_timer = vim.uv.new_timer()
    active_timers.push_timer:start(
        0,
        80,
        vim.schedule_wrap(function()
            if not state.state.is_pushing then
                return
            end
            if M.current then
                render_footer(M.current.bufnr)
            end
        end)
    )

    git.push(function(success, err)
        -- Stop spinner
        if active_timers.push_timer then
            active_timers.push_timer:stop()
            active_timers.push_timer:close()
            active_timers.push_timer = nil
        end
        state.state.is_pushing = false

        if success then
            vim.notify("Pushed successfully", vim.log.levels.INFO)
        else
            vim.notify("Push failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
        end

        update_footer()
    end)
end

---Setup keymaps for the file tree
---@param bufnr number
---@param callbacks table
local function setup_keymaps(bufnr, callbacks)
    registered_keymaps = {}

    local map = ui_util.create_buffer_mapper(bufnr, registered_keymaps)

    local function get_child_files_of_directory(dir_path)
        if not M.current or not M.current.nodes then
            return {}
        end
        local prefix = dir_path .. "/"
        local child_files = {}
        for _, file_node in ipairs(M.current.nodes) do
            if file_node.is_file and file_node.path and file_node.path:sub(1, #prefix) == prefix then
                table.insert(child_files, file_node)
            end
        end
        return child_files
    end

    local function sync_diff_to_cursor()
        if not M.current or not M.current.winid or not vim.api.nvim_win_is_valid(M.current.winid) then
            return
        end
        local line = vim.api.nvim_win_get_cursor(M.current.winid)[1]
        local node = M.get_node_at_line(line)
        if node and node.is_file and callbacks.on_file_select then
            callbacks.on_file_select(node.path)
        end
    end

    local function refresh_and_sync()
        M.refresh(function()
            if callbacks.on_refresh then
                callbacks.on_refresh()
            end
            sync_diff_to_cursor()
        end)
    end

    local function stage_single_file(node)
        if node.reviewed then
            if git.unstage_file(node.path) then
                state.set_reviewed(node.path, false)
                refresh_and_sync()
            end
        else
            if git.stage_file(node.path) then
                state.set_reviewed(node.path, true)
                refresh_and_sync()
            end
        end
    end

    local function stage_directory(dir_path)
        local child_files = get_child_files_of_directory(dir_path)
        if #child_files == 0 then
            return
        end

        local all_staged = true
        for _, file_node in ipairs(child_files) do
            if not file_node.reviewed then
                all_staged = false
                break
            end
        end

        local should_stage = not all_staged
        for _, file_node in ipairs(child_files) do
            if should_stage and not file_node.reviewed then
                if git.stage_file(file_node.path) then
                    state.set_reviewed(file_node.path, true)
                end
            elseif not should_stage and file_node.reviewed then
                if git.unstage_file(file_node.path) then
                    state.set_reviewed(file_node.path, false)
                end
            end
        end

        refresh_and_sync()
    end

    -- Toggle stage with space
    local function toggle_stage()
        if state.is_history_mode() then
            vim.notify("Cannot stage in history mode", vim.log.levels.WARN)
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local node = M.get_node_at_line(line)
        if not node then
            return
        end

        if node.is_directory and node.dir_path then
            stage_directory(node.dir_path)
        elseif node.is_file then
            stage_single_file(node)
        end
    end

    -- Debounced file selection (uses module-level timer for cleanup)
    local function select_current_file()
        -- Cancel pending selection
        if active_timers.select_timer then
            active_timers.select_timer:stop()
            active_timers.select_timer:close()
            active_timers.select_timer = nil
        end

        -- Debounce: wait 50ms before loading diff
        active_timers.select_timer = vim.loop.new_timer()
        active_timers.select_timer:start(
            50,
            0,
            vim.schedule_wrap(function()
                if active_timers.select_timer then
                    active_timers.select_timer:stop()
                    active_timers.select_timer:close()
                    active_timers.select_timer = nil
                end
                local line = vim.api.nvim_win_get_cursor(0)[1]
                local node = M.get_node_at_line(line)
                if node and node.is_file and callbacks.on_file_select then
                    callbacks.on_file_select(node.path)
                end
            end)
        )
    end

    -- Helper to check if node should be skipped during navigation
    local function should_skip_node(node)
        return not node or node.is_separator
    end

    -- Navigate and auto-select (skip separators and logo)
    map("j", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local line_count = vim.api.nvim_buf_line_count(0)
        local next_line = line + 1

        -- Skip non-navigable lines
        while next_line <= line_count do
            local node = M.get_node_at_line(next_line)
            if not should_skip_node(node) then
                break
            end
            next_line = next_line + 1
        end

        if next_line <= line_count then
            vim.api.nvim_win_set_cursor(0, { next_line, 0 })
            select_current_file()
        end
    end, { nowait = true, desc = "Next file", group = "Navigation" })

    map("k", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local prev_line = line - 1

        -- Skip non-navigable lines
        while prev_line >= 1 do
            local node = M.get_node_at_line(prev_line)
            if not should_skip_node(node) then
                break
            end
            prev_line = prev_line - 1
        end

        if prev_line >= 1 then
            vim.api.nvim_win_set_cursor(0, { prev_line, 0 })
            select_current_file()
        end
    end, { nowait = true, desc = "Previous file", group = "Navigation" })

    -- Select file and focus diff view, or toggle directory collapse
    map("<CR>", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local node = M.get_node_at_line(line)
        if not node then
            return
        end

        if node.is_directory and node.dir_path then
            local target_dir_path = node.dir_path
            if collapsed_dirs[target_dir_path] then
                collapsed_dirs[target_dir_path] = nil
            else
                collapsed_dirs[target_dir_path] = true
            end
            M.refresh(function()
                if M.current and M.current.nodes then
                    for index, refreshed_node in ipairs(M.current.nodes) do
                        if refreshed_node.dir_path == target_dir_path then
                            vim.api.nvim_win_set_cursor(0, { index, 0 })
                            break
                        end
                    end
                end
                sync_diff_to_cursor()
            end)
        elseif node.is_file and callbacks.on_file_select then
            callbacks.on_file_select(node.path)
            -- Focus the diff view
            local layout = require("review.ui.layout")
            local diff_view = layout.get_diff_view()
            if diff_view and diff_view.winid and vim.api.nvim_win_is_valid(diff_view.winid) then
                vim.api.nvim_set_current_win(diff_view.winid)
            end
        end
    end, { nowait = true, desc = "Focus diff view", group = "Navigation" })

    local ui_util = require("review.ui.util")

    map("J", function()
        ui_util.smooth_scroll(active_timers, "down")
    end, { nowait = true, desc = "Scroll diff down", group = "Navigation" })

    map("K", function()
        ui_util.smooth_scroll(active_timers, "up")
    end, { nowait = true, desc = "Scroll diff up", group = "Navigation" })

    -- Panel navigation (file_tree is topmost, so h is nop)
    vim.keymap.set("n", "h", "<Nop>", { buffer = bufnr, nowait = true })
    map("l", function()
        local current_layout = require("review.ui.layout")
        local commit_list_component = current_layout.get_commit_list()
        if
            commit_list_component
            and commit_list_component.winid
            and vim.api.nvim_win_is_valid(commit_list_component.winid)
        then
            vim.api.nvim_set_current_win(commit_list_component.winid)
        end
    end, { nowait = true, desc = "Next panel", group = "Navigation" })
    vim.keymap.set("n", "<Left>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Right>", "<Nop>", { buffer = bufnr, nowait = true })

    -- Toggle stage with space
    map("<Space>", toggle_stage, { nowait = true, desc = "Toggle stage", group = "Review" })

    -- Refresh
    map("R", function()
        refresh_and_sync()
    end, { desc = "Refresh file list", group = "Review" })

    -- Show full path
    map("L", show_full_path, { desc = "Show full path", group = "Review" })

    -- Focus commit list
    map("B", function()
        local current_layout = require("review.ui.layout")
        local commit_list_component = current_layout.get_commit_list()
        if
            commit_list_component
            and commit_list_component.winid
            and vim.api.nvim_win_is_valid(commit_list_component.winid)
        then
            vim.api.nvim_set_current_win(commit_list_component.winid)
        end
    end, { desc = "Focus commit list", group = "Git" })

    -- Cycle to next left pane (file_tree → commit_list)
    map("<Tab>", function()
        local current_layout = require("review.ui.layout")
        local commit_list_component = current_layout.get_commit_list()
        if
            commit_list_component
            and commit_list_component.winid
            and vim.api.nvim_win_is_valid(commit_list_component.winid)
        then
            vim.api.nvim_set_current_win(commit_list_component.winid)
        end
    end, { desc = "Next pane", group = "View" })

    -- Commit staged changes
    map("c", function()
        local commit_callbacks = vim.tbl_extend("force", callbacks, {
            on_commit_complete = refresh_and_sync,
        })
        commit_flow(commit_callbacks)
    end, { desc = "Commit staged changes", group = "Git" })

    map("A", function()
        if state.is_history_mode() then
            vim.notify("Cannot amend in history mode", vim.log.levels.WARN)
            return
        end

        vim.ui.select({ { label = "Yes" }, { label = "No" } }, {
            prompt = "Amend last commit?",
            format_item = function(item)
                return item.label
            end,
        }, function(choice)
            if not choice or choice.label ~= "Yes" then
                return
            end

            if not git.stage_all() then
                vim.notify("Failed to stage changes", vim.log.levels.ERROR)
                return
            end

            local progress = create_commit_progress("Amending", "Amending...")

            git.amend_no_edit_streaming(progress.add_line, function(success, err)
                progress.stop()

                if success then
                    vim.notify("Amended all changes to last commit", vim.log.levels.INFO)
                    refresh_and_sync()
                else
                    vim.notify("Amend failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
                end
            end)
        end)
    end, { desc = "Amend all changes to last commit", group = "Git" })

    -- Push to remote
    map("P", function()
        push_flow()
    end, { desc = "Push to remote", group = "Git" })

    -- Toggle list/tree view
    map("`", function()
        M.view_mode = M.view_mode == "list" and "tree" or "list"
        refresh_and_sync()
    end, { desc = "Toggle list/tree view", group = "View" })

    -- Toggle file tree
    map("<C-n>", function()
        local ui = require("review.ui")
        ui.toggle_file_tree()
    end, { desc = "Toggle file tree", group = "View" })

    -- Toggle split/unified diff
    map("S", function()
        local diff_view = require("review.ui.diff_view")
        diff_view.toggle_diff_mode({
            on_close = function(send_comments)
                if callbacks.on_close then
                    callbacks.on_close(send_comments)
                end
            end,
        })
    end, { desc = "Toggle split/unified diff", group = "View" })

    -- Expand/shrink diff context
    map("}", function()
        state.state.diff_context = state.state.diff_context + 1
        local ui = require("review.ui")
        if state.state.current_file then
            ui.show_diff(state.state.current_file)
        end
    end, { desc = "Expand diff context", group = "View" })

    map("{", function()
        state.state.diff_context = math.max(0, state.state.diff_context - 1)
        local ui = require("review.ui")
        if state.state.current_file then
            ui.show_diff(state.state.current_file)
        end
    end, { desc = "Shrink diff context", group = "View" })

    -- Open file at first change
    map("e", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local node = M.get_node_at_line(line)

        if not node or not node.is_file or not node.path then
            return
        end

        if node.in_deleted_section then
            vim.notify("Cannot open deleted file", vim.log.levels.WARN)
            return
        end

        local diff = require("review.core.diff")
        local diff_result = git.get_diff(node.path, state.state.base, state.state.base_end)
        local first_changed_line = nil

        if diff_result.success and diff_result.output ~= "" then
            local parsed = diff.parse(diff_result.output)

            if parsed.hunks[1] then
                for _, hunk_line in ipairs(parsed.hunks[1].lines) do
                    if hunk_line.type == "add" then
                        first_changed_line = hunk_line.new_line
                        break
                    elseif hunk_line.type == "delete" then
                        first_changed_line = hunk_line.old_line
                        break
                    end
                end

                if not first_changed_line then
                    first_changed_line = parsed.hunks[1].new_start
                end
            end
        end

        local absolute_path = git.get_root() .. "/" .. node.path

        local ui = require("review.ui")
        ui.close(false)

        vim.cmd("edit " .. vim.fn.fnameescape(absolute_path))

        if first_changed_line then
            vim.api.nvim_win_set_cursor(0, { first_changed_line, 0 })
        end
    end, { desc = "Open file at first change", group = "Navigation" })

    -- Revert file changes
    map("D", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local node = M.get_node_at_line(line)

        if not node or not node.is_file or not node.path then
            return
        end

        vim.ui.select({ { label = "Yes" }, { label = "No" } }, {
            prompt = "Revert all changes to " .. node.path .. "?",
            format_item = function(item)
                return item.label
            end,
        }, function(choice)
            if not choice or choice.label ~= "Yes" then
                return
            end

            if git.restore_file(node.path) then
                state.set_reviewed(node.path, false)
                refresh_and_sync()
                vim.notify("Reverted " .. node.path, vim.log.levels.INFO)
            else
                vim.notify("Failed to revert " .. node.path, vim.log.levels.ERROR)
            end
        end)
    end, { desc = "Revert file changes", group = "Git" })

    -- Close (shows exit popup)
    local function close_review()
        if callbacks.on_close then
            callbacks.on_close()
        end
    end

    map("q", close_review, { nowait = true, desc = "Close review", group = "General" })
    map("<Esc>", close_review, { nowait = true, desc = "Close review", group = "General" })
    map("?", show_help, { desc = "Show help", group = "General" })
end

---Get node at a specific line (1-indexed)
---@param line number
---@return FileNode|nil
function M.get_node_at_line(line)
    if not M.current or not M.current.nodes then
        return nil
    end
    return M.current.nodes[line]
end

---Create the file tree component
---@param layout_component table { bufnr: number, winid: number }
---@param callbacks table
---@return FileTreeComponent
function M.create(layout_component, callbacks)
    local bufnr = layout_component.bufnr

    -- Initialize M.current immediately so keymaps and UI work
    M.current = {
        bufnr = bufnr,
        winid = layout_component.winid,
        files = {},
        nodes = {},
    }

    -- Setup keymaps right away
    setup_keymaps(bufnr, callbacks)

    -- Disable spell check on file tree
    vim.wo[layout_component.winid].spell = false

    -- Show loading state
    update_winbar(layout_component.winid, 0, true)

    generation = generation + 1
    local current_generation = generation

    async.run(function()
        local files = git.get_changed_files_async(state.state.base, state.state.base_end)

        -- Fetch staged + unstaged sets concurrently
        local unstaged_set = {}
        local staged_set = {}
        if not state.state.base_end then
            local batch_results = async.all({
                function()
                    return git.get_unstaged_files_async()
                end,
                function()
                    return git.get_staged_files_async()
                end,
            })
            unstaged_set = batch_results[1]
            staged_set = batch_results[2]
        end

        -- Discard stale results
        if current_generation ~= generation then
            return
        end
        if not state.state.is_open or not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        -- Initialize reviewed state from staged/unstaged sets
        if not state.state.base_end then
            for _, file in ipairs(files) do
                local is_staged = staged_set[file] or false
                local has_unstaged = unstaged_set[file] or false
                state.set_reviewed(file, is_staged and not has_unstaged)
            end
        end

        -- Create nodes (sync — just CPU, no I/O)
        local nodes
        if M.view_mode == "tree" then
            nodes = create_tree_nodes(files, state.state.base, state.state.base_end, unstaged_set)
        else
            nodes = create_nodes(files, state.state.base, state.state.base_end, unstaged_set)
        end

        -- Final staleness check before rendering
        if current_generation ~= generation then
            return
        end
        if not state.state.is_open or not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        M.current.files = files
        M.current.nodes = nodes

        render_to_buffer(bufnr, nodes, layout_component.winid)
        update_winbar(layout_component.winid, #files)

        -- Position cursor on first file and load its diff
        if vim.api.nvim_win_is_valid(layout_component.winid) then
            for node_index, node in ipairs(nodes) do
                if node.is_file then
                    vim.api.nvim_win_set_cursor(layout_component.winid, { node_index, 0 })
                    if callbacks.on_file_select then
                        callbacks.on_file_select(node.path)
                    end
                    break
                end
            end
        end

        update_footer()
    end)

    return M.current
end

---Refresh the file list
---@param on_complete? fun() Called after async refresh finishes
function M.refresh(on_complete)
    if not M.current then
        return
    end

    local bufnr = M.current.bufnr
    local winid = M.current.winid

    -- Show refreshing indicator while keeping stale content visible
    update_winbar(winid, #M.current.files, true)

    generation = generation + 1
    local current_generation = generation

    async.run(function()
        local files = git.get_changed_files_async(state.state.base, state.state.base_end)

        local history_mode = state.is_history_mode()
        local unstaged_set = {}
        if not history_mode and not state.state.base_end then
            local batch_results = async.all({
                function()
                    return git.get_unstaged_files_async()
                end,
                function()
                    return git.get_staged_files_async()
                end,
            })
            unstaged_set = batch_results[1]
            local staged_set = batch_results[2]

            -- Discard stale results before mutating state
            if current_generation ~= generation then
                return
            end
            if not state.state.is_open or not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end

            for _, file in ipairs(files) do
                local is_staged = staged_set[file] or false
                local has_unstaged = unstaged_set[file] or false
                state.set_reviewed(file, is_staged and not has_unstaged)
            end
        else
            if current_generation ~= generation then
                return
            end
            if not state.state.is_open or not vim.api.nvim_buf_is_valid(bufnr) then
                return
            end
        end

        -- Create nodes (sync — just CPU, no I/O)
        local nodes
        if M.view_mode == "tree" then
            nodes = create_tree_nodes(files, state.state.base, state.state.base_end, unstaged_set)
        else
            nodes = create_nodes(files, state.state.base, state.state.base_end, unstaged_set)
        end

        -- Final staleness check
        if current_generation ~= generation then
            return
        end
        if not state.state.is_open or not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end

        M.current.files = files
        M.current.nodes = nodes

        render_to_buffer(bufnr, nodes, winid)
        update_winbar(winid, #files)

        update_footer()

        if on_complete then
            on_complete()
        end
    end)
end

---Get the current component
---@return FileTreeComponent|nil
function M.get()
    return M.current
end

---Destroy the component
function M.destroy()
    -- Bump generation to discard any in-flight async results
    generation = generation + 1
    -- Clean up any active timers
    for name, timer in pairs(active_timers) do
        if timer then
            timer:stop()
            timer:close()
            active_timers[name] = nil
        end
    end
    -- Reset footer state
    footer_state = { unpushed_count = nil, spinner_frame = 0 }
    collapsed_dirs = {}
    M.current = nil
end

return M
