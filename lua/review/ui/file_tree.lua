local git = require("review.core.git")
local state = require("review.state")

local M = {}

-- Optional devicons support
local has_devicons, devicons = pcall(require, "nvim-web-devicons")

---Get file icon from devicons or fallback
---@param filename string
---@return string icon, string|nil highlight
local function get_file_icon(filename)
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
---@field checkbox_start number
---@field checkbox_end number
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
        checkbox_start = 0,
        checkbox_end = 0,
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

    -- Checkbox for reviewed status (hidden in history mode)
    local checkbox = reviewed and "[x]" or "[ ]"

    -- Get just the filename
    local filename = vim.fn.fnamemodify(file, ":t")
    -- Get the directory path (empty if file is in root)
    local dir = vim.fn.fnamemodify(file, ":h")
    local path_suffix = dir ~= "." and ("  " .. file) or ""

    -- For renamed files, show old path as suffix instead
    if old_path then
        path_suffix = "  ← " .. old_path
    end

    -- Build text: "  ● file_icon [x] filename  path" (with left padding)
    -- In history mode, skip checkbox: "  ● file_icon filename  path"
    local padding = "  "
    local dot_part = "● "
    local file_icon_part = file_icon .. " "
    local checkbox_part = is_history_mode and "" or (checkbox .. " ")
    local filename_part = filename
    local text = padding .. dot_part .. file_icon_part .. checkbox_part .. filename_part .. path_suffix

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
        checkbox_start = offset + #dot_part + #file_icon_part,
        checkbox_end = offset + #dot_part + #file_icon_part + #checkbox_part,
        filename_start = offset + #dot_part + #file_icon_part + #checkbox_part,
        filename_end = offset + #dot_part + #file_icon_part + #checkbox_part + #filename_part,
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
        checkbox_start = 0,
        checkbox_end = 0,
        filename_start = 0,
        filename_end = 0,
    }
end

---Create file nodes from file list
---@param files string[]
---@param base string|nil Base commit for comparison
---@param base_end string|nil End of commit range
---@return FileNode[]
local function create_nodes(files, base, base_end)
    local is_history_mode = base ~= nil and base ~= "HEAD"

    -- Batch fetch all git statuses in one call (major perf win)
    local status_map, rename_map = git.get_all_file_statuses(files, base, base_end)
    -- Batch fetch unstaged files set
    local unstaged_set = not is_history_mode and git.get_unstaged_files() or {}

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
---@return FileNode[]
local function create_tree_nodes(files, base, base_end)
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

    -- Flatten tree into nodes with indentation
    local nodes = {}

    -- Indent markers
    local INDENT_MARKER_PIPE = "│ " -- continuing line
    local INDENT_MARKER_BRANCH = "├ " -- branch (has siblings after)
    local INDENT_MARKER_LAST = "└ " -- last item (no siblings after)
    local INDENT_MARKER_SPACE = "  " -- empty space

    local function add_tree_entry(name, entry, depth, indent_stack, is_last)
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

            local checkbox = is_history_mode and "" or (reviewed and "[x] " or "[ ] ")
            local dot_part = "● "
            local left_pad = " "
            local text = left_pad .. indent .. dot_part .. file_icon .. " " .. checkbox .. name

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
                checkbox_start = offset + #dot_part + #file_icon + 1,
                checkbox_end = offset + #dot_part + #file_icon + 1 + #checkbox,
                filename_start = offset + #dot_part + #file_icon + 1 + #checkbox,
                filename_end = #text,
            })
        else
            -- It's a directory (using nf-md-folder U+F024B)
            local folder_icon = "󰉋"
            local left_pad = " "
            local text = left_pad .. indent .. folder_icon .. " " .. name

            local offset = #left_pad + #indent
            table.insert(nodes, {
                path = nil,
                text = text,
                is_file = false,
                is_separator = false,
                is_directory = true,
                is_tree_view = true,
                reviewed = false,
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
                add_tree_entry(child.name, child.entry, depth + 1, child_indent_stack, child_is_last)
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
        add_tree_entry(item.name, item.entry, 0, {}, is_last)
    end

    return nodes
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
                vim.api.nvim_buf_add_highlight(
                    bufnr,
                    -1,
                    "ReviewTreeDirectory",
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

            -- Checkbox - green if reviewed, orange if not
            local checkbox_hl = node.reviewed and "ReviewFileReviewed" or "ReviewFileModified"
            vim.api.nvim_buf_add_highlight(bufnr, -1, checkbox_hl, i - 1, node.checkbox_start, node.checkbox_end)

            -- Filename and path coloring
            local filename_hl = node.is_non_important and "ReviewFileFaded" or "ReviewFilePath"
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
        -- "  ↑ " is prefix, then count highlighted in blue, rest in gray
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

---Commit staged changes with input prompt and spinner
---@param callbacks table
local function commit_flow(callbacks)
    if state.state.base ~= nil and state.state.base ~= "HEAD" then
        vim.notify("Cannot commit in history mode", vim.log.levels.WARN)
        return
    end

    vim.ui.input({ prompt = "Commit message: " }, function(message)
        if not message or message == "" then
            return
        end

        -- Spinner animation
        local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
        local frame = 0
        local spinner_buf = vim.api.nvim_create_buf(false, true)
        local width = #message + 16
        local spinner_win = vim.api.nvim_open_win(spinner_buf, false, {
            relative = "editor",
            row = math.floor(vim.o.lines / 2) - 1,
            col = math.floor((vim.o.columns - width) / 2),
            width = width,
            height = 1,
            style = "minimal",
            border = "rounded",
            title = " Committing ",
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
                frame = (frame % #spinner_frames) + 1
                local text = " " .. spinner_frames[frame] .. " Committing..."
                vim.api.nvim_buf_set_lines(spinner_buf, 0, -1, false, { text })
            end)
        )

        git.commit(message, function(success, err)
            timer:stop()
            timer:close()
            if vim.api.nvim_win_is_valid(spinner_win) then
                vim.api.nvim_win_close(spinner_win, true)
            end
            if vim.api.nvim_buf_is_valid(spinner_buf) then
                vim.api.nvim_buf_delete(spinner_buf, { force = true })
            end

            if success then
                vim.notify("Committed: " .. message, vim.log.levels.INFO)
                M.refresh()
                if callbacks.on_refresh then
                    callbacks.on_refresh()
                end
            else
                vim.notify("Commit failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
            end
        end)
    end)
end

---Push to remote with spinner animation in footer
local function push_flow()
    if state.state.is_pushing then
        vim.notify("Already pushing...", vim.log.levels.WARN)
        return
    end

    if state.state.base ~= nil and state.state.base ~= "HEAD" then
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

    ---Helper to set a keymap and register it for help display
    ---@param lhs string
    ---@param rhs string|function
    ---@param opts table opts.group is used for help grouping (not passed to vim.keymap.set)
    local function map(lhs, rhs, opts)
        local group = opts.group
        opts.group = nil
        opts.buffer = bufnr
        if opts.desc and group then
            table.insert(registered_keymaps, { lhs = lhs, desc = opts.desc, group = group })
        end
        vim.keymap.set("n", lhs, rhs, opts)
    end

    -- Check if we're in history mode (can't stage)
    local function is_history_mode()
        return state.state.base ~= nil and state.state.base ~= "HEAD"
    end

    -- Toggle stage with space
    local function toggle_stage()
        if is_history_mode() then
            vim.notify("Cannot stage in history mode", vim.log.levels.WARN)
            return
        end

        local line = vim.api.nvim_win_get_cursor(0)[1]
        local node = M.get_node_at_line(line)
        if not node or not node.is_file then
            return
        end

        local staged_file = node.path
        local was_staged = node.reviewed

        if node.reviewed then
            -- Unstage
            if git.unstage_file(node.path) then
                state.set_reviewed(node.path, false)
                M.refresh()
                if callbacks.on_refresh then
                    callbacks.on_refresh()
                end
            end
        else
            -- Stage
            if git.stage_file(node.path) then
                state.set_reviewed(node.path, true)
                M.refresh()
                if callbacks.on_refresh then
                    callbacks.on_refresh()
                end
            end
        end

        -- After staging (not unstaging), cursor stays on same line but file moved to bottom
        -- Find and select the next available file at cursor position or nearby
        if not was_staged and M.current and M.current.nodes then
            local current_node = M.get_node_at_line(line)
            -- If cursor is now on a different file, select it
            if current_node and current_node.is_file and current_node.path ~= staged_file then
                if callbacks.on_file_select then
                    callbacks.on_file_select(current_node.path)
                end
            -- If cursor is on a separator/header, find next file
            elseif not current_node or not current_node.is_file then
                local line_count = vim.api.nvim_buf_line_count(M.current.bufnr)
                for i = line, line_count do
                    local n = M.get_node_at_line(i)
                    if n and n.is_file and n.path ~= staged_file then
                        if vim.api.nvim_win_is_valid(M.current.winid) then
                            vim.api.nvim_win_set_cursor(M.current.winid, { i, 0 })
                        end
                        if callbacks.on_file_select then
                            callbacks.on_file_select(n.path)
                        end
                        break
                    end
                end
            end
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

    -- Select file and focus diff view
    map("<CR>", function()
        local line = vim.api.nvim_win_get_cursor(0)[1]
        local node = M.get_node_at_line(line)
        if node and node.is_file and callbacks.on_file_select then
            callbacks.on_file_select(node.path)
            -- Focus the diff view
            local layout = require("review.ui.layout")
            local diff_view = layout.get_diff_view()
            if diff_view and diff_view.winid and vim.api.nvim_win_is_valid(diff_view.winid) then
                vim.api.nvim_set_current_win(diff_view.winid)
            end
        end
    end, { nowait = true, desc = "Focus diff view", group = "Navigation" })

    -- Smooth scroll diff view with J/K (uses module-level timer for cleanup)
    local function smooth_scroll(direction)
        -- Cancel any existing scroll
        if active_timers.scroll_timer then
            active_timers.scroll_timer:stop()
            active_timers.scroll_timer:close()
            active_timers.scroll_timer = nil
        end

        local layout = require("review.ui.layout")
        local dv = layout.get_diff_view()
        if not dv or not dv.winid or not vim.api.nvim_win_is_valid(dv.winid) then
            return
        end

        local lines = 15
        local delay = 2 -- ms between each line (fast)
        local cmd = direction == "down" and "normal! \x05" or "normal! \x19"

        local i = 0
        active_timers.scroll_timer = vim.loop.new_timer()
        active_timers.scroll_timer:start(
            0,
            delay,
            vim.schedule_wrap(function()
                if i >= lines then
                    if active_timers.scroll_timer then
                        active_timers.scroll_timer:stop()
                        active_timers.scroll_timer:close()
                        active_timers.scroll_timer = nil
                    end
                    return
                end
                if vim.api.nvim_win_is_valid(dv.winid) then
                    vim.api.nvim_win_call(dv.winid, function()
                        vim.cmd(cmd)
                    end)
                end
                i = i + 1
            end)
        )
    end

    map("J", function()
        smooth_scroll("down")
    end, { nowait = true, desc = "Scroll diff down", group = "Navigation" })

    map("K", function()
        smooth_scroll("up")
    end, { nowait = true, desc = "Scroll diff up", group = "Navigation" })

    -- Prevent horizontal movement
    vim.keymap.set("n", "h", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "l", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Left>", "<Nop>", { buffer = bufnr, nowait = true })
    vim.keymap.set("n", "<Right>", "<Nop>", { buffer = bufnr, nowait = true })

    -- Toggle stage with space
    map("<Space>", toggle_stage, { nowait = true, desc = "Toggle stage", group = "Review" })

    -- Refresh
    map("R", function()
        M.refresh()
        if callbacks.on_refresh then
            callbacks.on_refresh()
        end
    end, { desc = "Refresh file list", group = "Review" })

    -- Show full path
    map("L", show_full_path, { desc = "Show full path", group = "Review" })

    -- Pick base commit
    map("B", function()
        local ui = require("review.ui")
        ui.pick_commit()
    end, { desc = "Pick base commit", group = "Git" })

    -- Commit staged changes
    map("C", function()
        commit_flow(callbacks)
    end, { desc = "Commit staged changes", group = "Git" })

    -- Push to remote
    map("P", function()
        push_flow()
    end, { desc = "Push to remote", group = "Git" })

    -- Toggle list/tree view
    map("`", function()
        M.view_mode = M.view_mode == "list" and "tree" or "list"
        M.refresh()
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
    map("E", function()
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

    -- Get changed files
    local files = git.get_changed_files(state.state.base, state.state.base_end)

    -- Initialize file states
    -- A file is only considered "reviewed/staged" if it's staged AND has no additional unstaged changes
    if not state.state.base_end then
        local unstaged_set = git.get_unstaged_files()
        for _, file in ipairs(files) do
            local is_staged = git.is_staged(file)
            local has_unstaged = unstaged_set[file] or false
            state.set_reviewed(file, is_staged and not has_unstaged)
        end
    end

    -- Create nodes based on view mode
    local nodes
    if M.view_mode == "tree" then
        nodes = create_tree_nodes(files, state.state.base, state.state.base_end)
    else
        nodes = create_nodes(files, state.state.base, state.state.base_end)
    end

    M.current = {
        bufnr = bufnr,
        winid = layout_component.winid,
        files = files,
        nodes = nodes,
    }

    -- Render
    render_to_buffer(bufnr, nodes, layout_component.winid)

    -- Setup keymaps
    setup_keymaps(bufnr, callbacks)

    -- Disable spell check on file tree
    vim.wo[layout_component.winid].spell = false

    -- Position cursor on first file
    for i, node in ipairs(nodes) do
        if node.is_file then
            vim.api.nvim_win_set_cursor(layout_component.winid, { i, 0 })
            break
        end
    end

    -- Fetch and render unpushed count
    update_footer()

    return M.current
end

---Refresh the file list
function M.refresh()
    if not M.current then
        return
    end

    -- Get updated file list
    M.current.files = git.get_changed_files(state.state.base, state.state.base_end)

    -- Update reviewed states (only in normal mode, not in history/range mode)
    -- A file is only considered "reviewed/staged" if it's staged AND has no additional unstaged changes
    local is_history_mode = state.state.base ~= nil and state.state.base ~= "HEAD"
    if not is_history_mode and not state.state.base_end then
        local unstaged_set = git.get_unstaged_files()
        for _, file in ipairs(M.current.files) do
            local is_staged = git.is_staged(file)
            local has_unstaged = unstaged_set[file] or false
            state.set_reviewed(file, is_staged and not has_unstaged)
        end
    end

    -- Recreate nodes and render based on view mode
    if M.view_mode == "tree" then
        M.current.nodes = create_tree_nodes(M.current.files, state.state.base, state.state.base_end)
    else
        M.current.nodes = create_nodes(M.current.files, state.state.base, state.state.base_end)
    end
    render_to_buffer(M.current.bufnr, M.current.nodes, M.current.winid)

    -- Refresh unpushed count
    update_footer()
end

---Get the current component
---@return FileTreeComponent|nil
function M.get()
    return M.current
end

---Destroy the component
function M.destroy()
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
    M.current = nil
end

return M
