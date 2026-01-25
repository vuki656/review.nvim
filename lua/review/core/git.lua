local M = {}

---@class GitDiffResult
---@field success boolean
---@field output string
---@field error string|nil

---Get the git root directory
---@return string|nil
function M.get_root()
    local result = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()
    if result.code == 0 then
        return vim.trim(result.stdout)
    end
    return nil
end

---Get list of changed files (unstaged, staged, and untracked)
---@param base string|nil Base commit to compare against (default: HEAD)
---@return string[]
function M.get_changed_files(base)
    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return {}
    end

    local files = {}
    local seen = {}

    -- Get unstaged changes
    local unstaged = vim.system(
        { "git", "diff", "--name-only", base },
        { text = true, cwd = git_root }
    ):wait()

    if unstaged.code == 0 then
        for line in unstaged.stdout:gmatch("[^\r\n]+") do
            if line ~= "" and not seen[line] then
                seen[line] = true
                table.insert(files, line)
            end
        end
    end

    -- Get staged changes
    local staged = vim.system(
        { "git", "diff", "--cached", "--name-only" },
        { text = true, cwd = git_root }
    ):wait()

    if staged.code == 0 then
        for line in staged.stdout:gmatch("[^\r\n]+") do
            if line ~= "" and not seen[line] then
                seen[line] = true
                table.insert(files, line)
            end
        end
    end

    -- Get untracked files
    local untracked = vim.system(
        { "git", "ls-files", "--others", "--exclude-standard" },
        { text = true, cwd = git_root }
    ):wait()

    if untracked.code == 0 then
        for line in untracked.stdout:gmatch("[^\r\n]+") do
            if line ~= "" and not seen[line] then
                seen[line] = true
                table.insert(files, line)
            end
        end
    end

    return files
end

---Check if a file is untracked
---@param file string File path relative to git root
---@return boolean
function M.is_untracked(file)
    local git_root = M.get_root()
    if not git_root then
        return false
    end

    local result = vim.system(
        { "git", "ls-files", "--others", "--exclude-standard", "--", file },
        { text = true, cwd = git_root }
    ):wait()

    return result.code == 0 and vim.trim(result.stdout) ~= ""
end

---Get diff for a specific file
---@param file string File path relative to git root
---@param base string|nil Base commit to compare against
---@return GitDiffResult
function M.get_diff(file, base)
    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return { success = false, output = "", error = "Not in a git repository" }
    end

    -- Check if file is untracked (new file)
    if M.is_untracked(file) then
        -- For untracked files, read the file and generate a diff showing all as additions
        local full_path = git_root .. "/" .. file
        local content = vim.fn.readfile(full_path)
        if not content or #content == 0 then
            return { success = true, output = "", error = nil }
        end

        -- Generate diff-like output for new file
        local diff_lines = {
            "--- /dev/null",
            "+++ b/" .. file,
            "@@ -0,0 +1," .. #content .. " @@",
        }
        for _, line in ipairs(content) do
            table.insert(diff_lines, "+" .. line)
        end

        return { success = true, output = table.concat(diff_lines, "\n"), error = nil }
    end

    -- Check if file is staged (use cached diff)
    local is_staged_only = false
    local unstaged_result = vim.system(
        { "git", "diff", "--name-only", base, "--", file },
        { text = true, cwd = git_root }
    ):wait()

    if unstaged_result.code == 0 and vim.trim(unstaged_result.stdout) == "" then
        -- No unstaged changes, check if staged
        local staged_result = vim.system(
            { "git", "diff", "--cached", "--name-only", "--", file },
            { text = true, cwd = git_root }
        ):wait()
        if staged_result.code == 0 and vim.trim(staged_result.stdout) ~= "" then
            is_staged_only = true
        end
    end

    -- Get the appropriate diff
    local cmd
    if is_staged_only then
        cmd = { "git", "diff", "--cached", "--", file }
    else
        cmd = { "git", "diff", base, "--", file }
    end

    local result = vim.system(cmd, { text = true, cwd = git_root }):wait()

    if result.code ~= 0 then
        return { success = false, output = "", error = result.stderr }
    end

    return { success = true, output = result.stdout, error = nil }
end

---Get full diff for all changed files
---@param base string|nil Base commit to compare against
---@return GitDiffResult
function M.get_full_diff(base)
    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return { success = false, output = "", error = "Not in a git repository" }
    end

    local result = vim.system(
        { "git", "diff", base },
        { text = true, cwd = git_root }
    ):wait()

    if result.code ~= 0 then
        return { success = false, output = "", error = result.stderr }
    end

    return { success = true, output = result.stdout, error = nil }
end

---Stage a file (mark as reviewed)
---@param file string File path relative to git root
---@return boolean success
function M.stage_file(file)
    local git_root = M.get_root()
    if not git_root then
        return false
    end

    local result = vim.system(
        { "git", "add", "--", file },
        { text = true, cwd = git_root }
    ):wait()

    return result.code == 0
end

---Unstage a file
---@param file string File path relative to git root
---@return boolean success
function M.unstage_file(file)
    local git_root = M.get_root()
    if not git_root then
        return false
    end

    local result = vim.system(
        { "git", "reset", "HEAD", "--", file },
        { text = true, cwd = git_root }
    ):wait()

    return result.code == 0
end

---Check if a file is staged
---@param file string File path relative to git root
---@return boolean
function M.is_staged(file)
    local git_root = M.get_root()
    if not git_root then
        return false
    end

    local result = vim.system(
        { "git", "diff", "--cached", "--name-only", "--", file },
        { text = true, cwd = git_root }
    ):wait()

    if result.code ~= 0 then
        return false
    end

    return vim.trim(result.stdout) ~= ""
end

---@alias GitFileStatus "added"|"modified"|"deleted"

---Get the git status of a file
---@param file string File path relative to git root
---@param base string|nil Base commit to compare against (default: HEAD)
---@return GitFileStatus
function M.get_file_status(file, base)
    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return "modified"
    end

    -- Check if untracked (new file) - only for HEAD comparison
    if base == "HEAD" and M.is_untracked(file) then
        return "added"
    end

    -- Check file status relative to base
    local result = vim.system(
        { "git", "diff", "--name-status", base, "--", file },
        { text = true, cwd = git_root }
    ):wait()

    if result.code == 0 and result.stdout ~= "" then
        local status_char = result.stdout:sub(1, 1)
        if status_char == "D" then
            return "deleted"
        elseif status_char == "A" then
            return "added"
        end
    end

    -- Also check staged changes (only for HEAD comparison)
    if base == "HEAD" then
        local staged_result = vim.system(
            { "git", "diff", "--cached", "--name-status", "--", file },
            { text = true, cwd = git_root }
        ):wait()

        if staged_result.code == 0 and staged_result.stdout ~= "" then
            local status_char = staged_result.stdout:sub(1, 1)
            if status_char == "D" then
                return "deleted"
            elseif status_char == "A" then
                return "added"
            end
        end
    end

    return "modified"
end

---Get recent commits
---@param count number Number of commits to fetch (default 20)
---@return table[] commits with {hash, short_hash, subject, author, date}
function M.get_recent_commits(count)
    count = count or 20
    local git_root = M.get_root()
    if not git_root then
        return {}
    end

    local result = vim.system(
        { "git", "log", "--oneline", "--pretty=format:%H|%h|%s|%an|%ar", "-n", tostring(count) },
        { text = true, cwd = git_root }
    ):wait()

    if result.code ~= 0 then
        return {}
    end

    local commits = {}
    for line in result.stdout:gmatch("[^\r\n]+") do
        local hash, short_hash, subject, author, date = line:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)")
        if hash then
            table.insert(commits, {
                hash = hash,
                short_hash = short_hash,
                subject = subject,
                author = author,
                date = date,
            })
        end
    end

    return commits
end

---Get file content at a specific revision
---@param file string File path relative to git root
---@param rev string|nil Git revision (default: HEAD)
---@return string|nil content, string|nil error
function M.get_file_at_rev(file, rev)
    rev = rev or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return nil, "Not in a git repository"
    end

    local result = vim.system(
        { "git", "show", rev .. ":" .. file },
        { text = true, cwd = git_root }
    ):wait()

    if result.code ~= 0 then
        return nil, result.stderr
    end

    return result.stdout, nil
end

return M
