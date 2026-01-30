local state = require("review.state")

local M = {}

---Comment type labels
local type_labels = {
    note = "Note",
    fix = "Fix",
    question = "Question",
}

---Generate markdown export of all comments
---@return string
function M.generate()
    local lines = {}

    table.insert(lines, "# Code Review Comments")
    table.insert(lines, "")

    local grouped = state.get_comments_grouped_by_file()

    -- Sort files alphabetically
    local files = {}
    for file in pairs(grouped) do
        table.insert(files, file)
    end
    table.sort(files)

    if #files == 0 then
        table.insert(lines, "_No comments._")
        return table.concat(lines, "\n")
    end

    for _, file in ipairs(files) do
        local comments = grouped[file]

        table.insert(lines, "## " .. file)
        table.insert(lines, "")

        for _, comment in ipairs(comments) do
            local type_label = type_labels[comment.type] or "Unknown"
            local line_info = comment.original_line
                    and string.format("Line %d", comment.original_line)
                or string.format("Line %d", comment.line)

            table.insert(lines, string.format("### %s [%s]", line_info, type_label))
            table.insert(lines, "")
            table.insert(lines, comment.text)
            table.insert(lines, "")
        end
    end

    return table.concat(lines, "\n")
end

---Export comments to clipboard
---@return boolean success
function M.to_clipboard()
    local content = M.generate()

    -- Use system clipboard
    vim.fn.setreg("+", content)
    vim.fn.setreg("*", content)

    local comment_count = #state.get_all_comments()
    vim.notify(string.format("Exported %d comment(s) to clipboard", comment_count), vim.log.levels.INFO)

    return true
end

---Export comments to a file
---@param filepath string
---@return boolean success
function M.to_file(filepath)
    local content = M.generate()

    local file = io.open(filepath, "w")
    if not file then
        vim.notify("Failed to open file: " .. filepath, vim.log.levels.ERROR)
        return false
    end

    file:write(content)
    file:close()

    local comment_count = #state.get_all_comments()
    vim.notify(string.format("Exported %d comment(s) to %s", comment_count, filepath), vim.log.levels.INFO)

    return true
end

---Check if running inside tmux
---@return boolean
local function is_tmux()
    return vim.env.TMUX ~= nil
end

---Send comments to a tmux pane
---@param target? string Target window/pane (defaults to config)
---@param silent? boolean Suppress notifications (for auto-send)
---@return boolean success
function M.to_tmux(target, silent)
    if not is_tmux() then
        if not silent then
            vim.notify("Not running inside tmux", vim.log.levels.ERROR)
        end
        return false
    end

    local cfg = require("review.config").get()
    target = target or cfg.tmux.target

    local content = M.generate()
    local comment_count = #state.get_all_comments()

    if comment_count == 0 then
        if not silent then
            vim.notify("No comments to send", vim.log.levels.WARN)
        end
        return false
    end

    -- Write to temp file to avoid shell escaping issues
    local tmpfile = os.tmpname()
    local file = io.open(tmpfile, "w")
    if not file then
        if not silent then
            vim.notify("Failed to create temp file", vim.log.levels.ERROR)
        end
        return false
    end
    file:write(content)
    file:close()

    -- Load into tmux buffer and paste to target pane
    local load_cmd = string.format("tmux load-buffer %s", tmpfile)
    local paste_cmd = string.format("tmux paste-buffer -t %s", target)

    vim.system({ "sh", "-c", load_cmd }, {}, function(load_result)
        if load_result.code ~= 0 then
            vim.schedule(function()
                if not silent then
                    vim.notify("Failed to load tmux buffer: " .. (load_result.stderr or ""), vim.log.levels.ERROR)
                end
                os.remove(tmpfile)
            end)
            return
        end

        vim.system({ "sh", "-c", paste_cmd }, {}, function(paste_result)
            vim.schedule(function()
                os.remove(tmpfile)

                if paste_result.code ~= 0 then
                    if not silent then
                        vim.notify(
                            string.format("Failed to paste to tmux pane '%s': %s", target, paste_result.stderr or ""),
                            vim.log.levels.ERROR
                        )
                    end
                    return
                end

                -- Optionally send Enter key
                if cfg.tmux.auto_enter then
                    vim.system({ "tmux", "send-keys", "-t", target, "Enter" })
                end

                if not silent then
                    vim.notify(
                        string.format("Sent %d comment(s) to tmux pane '%s'", comment_count, target),
                        vim.log.levels.INFO
                    )
                end
            end)
        end)
    end)

    return true
end

return M
