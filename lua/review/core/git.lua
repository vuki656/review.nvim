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

---Get list of changed files (unstaged)
---@param base string|nil Base commit to compare against (default: HEAD)
---@return string[]
function M.get_changed_files(base)
    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return {}
    end

    local result = vim.system(
        { "git", "diff", "--name-only", base },
        { text = true, cwd = git_root }
    ):wait()

    if result.code ~= 0 then
        return {}
    end

    local files = {}
    for line in result.stdout:gmatch("[^\r\n]+") do
        if line ~= "" then
            table.insert(files, line)
        end
    end
    return files
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

    local result = vim.system(
        { "git", "diff", base, "--", file },
        { text = true, cwd = git_root }
    ):wait()

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
