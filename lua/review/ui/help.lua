local M = {}

---Deduplicate keymaps by combining lhs values that share the same group+desc
---@param keymaps {lhs: string, desc: string, group: string}[]
---@return {lhs: string, desc: string, group: string}[]
local function deduplicate(keymaps)
    local result = {}
    local last = nil

    for _, entry in ipairs(keymaps) do
        if last and last.group == entry.group and last.desc == entry.desc then
            last.lhs = last.lhs .. "/" .. entry.lhs
        else
            last = { lhs = entry.lhs, desc = entry.desc, group = entry.group }
            table.insert(result, last)
        end
    end

    return result
end

---Show a help popup with grouped keymaps
---@param title string
---@param keymaps {lhs: string, desc: string, group: string}[]
function M.show(title, keymaps)
    local entries = deduplicate(keymaps)

    local max_lhs_width = 0
    for _, entry in ipairs(entries) do
        max_lhs_width = math.max(max_lhs_width, #entry.lhs)
    end

    local groups_seen = {}
    local groups_order = {}
    local groups_map = {}

    for _, entry in ipairs(entries) do
        if not groups_seen[entry.group] then
            groups_seen[entry.group] = true
            table.insert(groups_order, entry.group)
            groups_map[entry.group] = {}
        end
        table.insert(groups_map[entry.group], entry)
    end

    local lines = {}
    local group_line_indices = {}

    for _, group_name in ipairs(groups_order) do
        table.insert(lines, "  " .. group_name)
        table.insert(group_line_indices, #lines)

        for _, entry in ipairs(groups_map[group_name]) do
            local padding = string.rep(" ", max_lhs_width - #entry.lhs + 1)
            table.insert(lines, "    " .. entry.lhs .. padding .. entry.desc)
        end

        table.insert(lines, "")
    end

    local floating_bufnr, floating_winid = vim.lsp.util.open_floating_preview(lines, "", {
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
    })

    for _, line_index in ipairs(group_line_indices) do
        vim.api.nvim_buf_add_highlight(floating_bufnr, -1, "ReviewHelpGroup", line_index - 1, 0, -1)
    end

    for line_index, line in ipairs(lines) do
        local key_start = line:find("%S")
        if key_start and not group_line_indices[1] then
            break
        end

        local is_group_line = false
        for _, group_index in ipairs(group_line_indices) do
            if line_index == group_index then
                is_group_line = true
                break
            end
        end

        if not is_group_line and line:match("^    %S") then
            local key_end = line:find("  ", 5)
            if key_end then
                vim.api.nvim_buf_add_highlight(floating_bufnr, -1, "ReviewHelpKey", line_index - 1, 4, key_end - 1)
            end
        end
    end
end

---Format grouped keymaps as lines (for welcome screen)
---@param keymaps {lhs: string, desc: string, group: string}[]
---@param indent string
---@return string[] lines
---@return number[] group_line_indices (1-indexed into returned lines)
function M.format_lines(keymaps, indent)
    local entries = deduplicate(keymaps)

    local max_lhs_width = 0
    for _, entry in ipairs(entries) do
        max_lhs_width = math.max(max_lhs_width, #entry.lhs)
    end

    local groups_seen = {}
    local groups_order = {}
    local groups_map = {}

    for _, entry in ipairs(entries) do
        if not groups_seen[entry.group] then
            groups_seen[entry.group] = true
            table.insert(groups_order, entry.group)
            groups_map[entry.group] = {}
        end
        table.insert(groups_map[entry.group], entry)
    end

    local lines = {}
    local group_line_indices = {}

    for _, group_name in ipairs(groups_order) do
        table.insert(lines, indent .. group_name)
        table.insert(group_line_indices, #lines)

        for _, entry in ipairs(groups_map[group_name]) do
            local padding = string.rep(" ", max_lhs_width - #entry.lhs + 1)
            table.insert(lines, indent .. "  " .. entry.lhs .. padding .. entry.desc)
        end

        table.insert(lines, "")
    end

    return lines, group_line_indices
end

return M
