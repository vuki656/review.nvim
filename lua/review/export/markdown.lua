local state = require("review.state")

local M = {}

local type_labels = {
    note = "NOTE",
    fix = "FIX",
    question = "QUESTION",
}

---Get file extension for fenced code block language
---@param file string
---@return string
local function get_language(file)
    local ext = vim.fn.fnamemodify(file, ":e")
    local lang_map = {
        ts = "typescript",
        js = "javascript",
        py = "python",
        rb = "ruby",
        rs = "rust",
        yml = "yaml",
        md = "markdown",
    }
    return lang_map[ext] or ext
end

---Extract context lines from render_lines around a comment
---@param render_lines table[]|nil
---@param comment_line number
---@param context_count number
---@return string[]|nil
local function get_diff_context(render_lines, comment_line, context_count)
    if not render_lines or #render_lines == 0 then
        return nil
    end

    if comment_line < 1 or comment_line > #render_lines then
        return nil
    end

    local start_idx = math.max(1, comment_line - context_count)
    local end_idx = math.min(#render_lines, comment_line + context_count)

    local context = {}
    for index = start_idx, end_idx do
        local line = render_lines[index]
        if line and line.type ~= "filepath" then
            local prefix = ""
            if line.type == "add" then
                prefix = "+"
            elseif line.type == "delete" then
                prefix = "-"
            else
                prefix = " "
            end
            table.insert(context, prefix .. (line.content or ""))
        end
    end

    return #context > 0 and context or nil
end

---Read source file lines for context when no diff is available
---@param file string
---@param line number
---@param context_count number
---@return string[]|nil
local function get_source_context(file, line, context_count)
    local git = require("review.core.git")
    local git_root = git.get_root()
    if not git_root then
        return nil
    end

    local full_path = git_root .. "/" .. file
    local content = vim.fn.readfile(full_path)
    if not content or #content == 0 then
        return nil
    end

    local start_idx = math.max(1, line - context_count)
    local end_idx = math.min(#content, line + context_count)

    local context = {}
    for index = start_idx, end_idx do
        table.insert(context, " " .. (content[index] or ""))
    end

    return #context > 0 and context or nil
end

---Generate markdown export of all comments
---@return string
function M.generate()
    local config = require("review.config").get()
    local context_count = config.export.context_lines
    local lines = {}

    table.insert(lines, "# Code Review Comments")
    table.insert(lines, "")

    local grouped = state.get_comments_grouped_by_file()

    local files = {}
    for file in pairs(grouped) do
        table.insert(files, file)
    end
    table.sort(files)

    if #files == 0 then
        table.insert(lines, "_No comments._")
        return table.concat(lines, "\n")
    end

    local language_cache = {}

    for _, file in ipairs(files) do
        local comments = grouped[file]
        local file_state = state.state.files[file]
        local render_lines_data = file_state and file_state.render_lines

        table.insert(lines, "## " .. file)
        table.insert(lines, "")

        for _, comment in ipairs(comments) do
            local type_label = type_labels[comment.type] or "NOTE"
            local display_line = comment.original_line or comment.line

            table.insert(lines, string.format("### [%s] %s:%d", type_label, file, display_line))
            table.insert(lines, "")

            if not language_cache[file] then
                language_cache[file] = get_language(file)
            end
            local language = language_cache[file]

            local context = get_diff_context(render_lines_data, comment.line, context_count)
            if context then
                table.insert(lines, "```" .. language)
                for _, context_line in ipairs(context) do
                    table.insert(lines, context_line)
                end
                table.insert(lines, "```")
                table.insert(lines, "")
            else
                local source_context = get_source_context(file, display_line, context_count)
                if source_context then
                    table.insert(lines, "*(no changes)*")
                    table.insert(lines, "```" .. language)
                    for _, context_line in ipairs(source_context) do
                        table.insert(lines, context_line)
                    end
                    table.insert(lines, "```")
                    table.insert(lines, "")
                end
            end

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
