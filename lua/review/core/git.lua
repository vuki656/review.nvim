local log = require("review.core.log")

local M = {}

---@class GitDiffResult
---@field success boolean
---@field output string
---@field error string|nil

-- Cached git root (invalidated on cwd change)
local cached_root = nil
local cached_cwd = nil

---Get the git root directory (cached)
---@return string|nil
function M.get_root()
    local cwd = vim.fn.getcwd()
    if cached_root and cached_cwd == cwd then
        return cached_root
    end

    local result = vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }):wait()
    if result.code == 0 then
        cached_root = vim.trim(result.stdout)
        cached_cwd = cwd
        return cached_root
    end

    cached_root = nil
    cached_cwd = cwd
    return nil
end

---Clear the git root cache (useful for testing or after changing directories)
function M.clear_cache()
    cached_root = nil
    cached_cwd = nil
end

---Split output into non-empty lines
---@param output string
---@return fun(): string|nil iterator
local function parse_lines(output)
    return output:gmatch("[^\r\n]+")
end

---Run a function with the git root, returning default_value if not in a git repo
---@generic T
---@param default_value T Value to return when not in a git repo
---@param fn fun(git_root: string): T
---@return T
local function with_git_root(default_value, fn)
    local git_root = M.get_root()
    if not git_root then
        return default_value
    end
    return fn(git_root)
end

---Get list of changed files (unstaged, staged, and untracked)
---@param base string|nil Base commit to compare against (default: HEAD)
---@param base_end string|nil End of commit range (when set, uses base..base_end)
---@return string[]
function M.get_changed_files(base, base_end)
    base = base or "HEAD"
    return with_git_root({}, function(git_root)
        local files = {}
        local seen = {}

        if base_end then
            local range_result = vim.system(
                { "git", "diff", "-M", "--name-only", base .. "..." .. base_end },
                { text = true, cwd = git_root }
            ):wait()

            if range_result.code == 0 then
                for line in parse_lines(range_result.stdout) do
                    if line ~= "" and not seen[line] then
                        seen[line] = true
                        table.insert(files, line)
                    end
                end
            end

            return files
        end

        -- Get unstaged changes
        local unstaged =
            vim.system({ "git", "diff", "-M", "--name-only", base }, { text = true, cwd = git_root }):wait()

        if unstaged.code == 0 then
            for line in parse_lines(unstaged.stdout) do
                if line ~= "" and not seen[line] then
                    seen[line] = true
                    table.insert(files, line)
                end
            end
        end

        -- Get staged changes
        local staged = vim.system({ "git", "diff", "-M", "--cached", "--name-only" }, { text = true, cwd = git_root })
            :wait()

        if staged.code == 0 then
            for line in parse_lines(staged.stdout) do
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
        )
            :wait()

        if untracked.code == 0 then
            for line in parse_lines(untracked.stdout) do
                if line ~= "" and not seen[line] then
                    seen[line] = true
                    table.insert(files, line)
                end
            end
        end

        return files
    end)
end

---Check if a file is untracked
---@param file string File path relative to git root
---@return boolean
function M.is_untracked(file)
    return with_git_root(false, function(git_root)
        local result = vim.system(
            { "git", "ls-files", "--others", "--exclude-standard", "--", file },
            { text = true, cwd = git_root }
        ):wait()

        return result.code == 0 and vim.trim(result.stdout) ~= ""
    end)
end

---@class GetDiffOpts
---@field file_status "untracked"|"staged_only"|"unstaged"|nil Pre-resolved file status to skip subprocess calls

---Get diff for a specific file
---@param file string File path relative to git root
---@param base string|nil Base commit to compare against
---@param base_end string|nil End of commit range (when set, uses base..base_end)
---@param opts GetDiffOpts|nil Optional parameters
---@return GitDiffResult
function M.get_diff(file, base, base_end, opts)
    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return { success = false, output = "", error = "Not in a git repository" }
    end

    if base_end then
        local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
        local cmd = { "git", "diff", "-M", context_flag, base .. "..." .. base_end, "--", file }
        local result = vim.system(cmd, { text = true, cwd = git_root }):wait()

        if result.code ~= 0 then
            return { success = false, output = "", error = result.stderr }
        end

        return { success = true, output = result.stdout, error = nil }
    end

    local file_status = opts and opts.file_status or nil

    -- Check if file is untracked (new file)
    local is_untracked = file_status == "untracked" or (not file_status and M.is_untracked(file))
    if is_untracked then
        local full_path = git_root .. "/" .. file
        local content = vim.fn.readfile(full_path)
        if not content or #content == 0 then
            return { success = true, output = "", error = nil }
        end

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

    -- Determine if file has only staged changes (no unstaged)
    local is_staged_only = file_status == "staged_only"
    if not file_status then
        local unstaged_result = vim.system(
            { "git", "diff", "--name-only", "--", file },
            { text = true, cwd = git_root }
        )
            :wait()

        if unstaged_result.code == 0 and vim.trim(unstaged_result.stdout) == "" then
            local staged_result = vim.system(
                { "git", "diff", "--cached", "--name-only", "--", file },
                { text = true, cwd = git_root }
            ):wait()
            if staged_result.code == 0 and vim.trim(staged_result.stdout) ~= "" then
                is_staged_only = true
            end
        end
    end

    local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
    local cmd
    if is_staged_only then
        cmd = { "git", "diff", "-M", context_flag, "--cached", "--", file }
    else
        cmd = { "git", "diff", "-M", context_flag, base, "--", file }
    end

    local result = vim.system(cmd, { text = true, cwd = git_root }):wait()

    if result.code ~= 0 then
        return { success = false, output = "", error = result.stderr }
    end

    return { success = true, output = result.stdout, error = nil }
end

---Get combined diff for a commit range in a single git call
---@param base string Base commit (parent)
---@param base_end string End commit
---@return GitDiffResult
function M.get_commit_diff(base, base_end)
    local no_repo = { success = false, output = "", error = "Not in a git repository" }
    return with_git_root(no_repo, function(git_root)
        local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
        local result = vim.system(
            { "git", "diff", "-M", context_flag, base .. "..." .. base_end },
            { text = true, cwd = git_root }
        )
            :wait()

        if result.code ~= 0 then
            return { success = false, output = "", error = result.stderr }
        end

        return { success = true, output = result.stdout, error = nil }
    end)
end

---Get full diff for all changed files
---@param base string|nil Base commit to compare against
---@return GitDiffResult
function M.get_full_diff(base)
    base = base or "HEAD"
    local no_repo = { success = false, output = "", error = "Not in a git repository" }
    return with_git_root(no_repo, function(git_root)
        local result = vim.system({ "git", "diff", base }, { text = true, cwd = git_root }):wait()

        if result.code ~= 0 then
            return { success = false, output = "", error = result.stderr }
        end

        return { success = true, output = result.stdout, error = nil }
    end)
end

---Stage a file (mark as reviewed)
---@param file string File path relative to git root
---@return boolean success
function M.stage_file(file)
    local git_root = M.get_root()
    if not git_root then
        log.error("stage_file: no git root")
        return false
    end

    log.debug("stage_file:", file)
    local result = vim.system({ "git", "add", "--", file }, { text = true, cwd = git_root }):wait()

    if result.code ~= 0 then
        log.error("stage_file failed:", file, result.stderr)
    end
    return result.code == 0
end

---Unstage a file
---@param file string File path relative to git root
---@return boolean success
function M.unstage_file(file)
    local git_root = M.get_root()
    if not git_root then
        log.error("unstage_file: no git root")
        return false
    end

    log.debug("unstage_file:", file)
    local result = vim.system({ "git", "reset", "HEAD", "--", file }, { text = true, cwd = git_root }):wait()

    if result.code ~= 0 then
        log.error("unstage_file failed:", file, result.stderr)
    end
    return result.code == 0
end

---Revert all changes to a file (both staged and unstaged)
---@param file string File path relative to git root
---@return boolean success
function M.restore_file(file)
    return with_git_root(false, function(git_root)
        if M.is_untracked(file) then
            local full_path = git_root .. "/" .. file
            local ok = os.remove(full_path)
            return ok ~= nil
        end

        local reset = vim.system({ "git", "checkout", "HEAD", "--", file }, { text = true, cwd = git_root }):wait()

        return reset.code == 0
    end)
end

---Check if a file is staged
---@param file string File path relative to git root
---@return boolean
function M.is_staged(file)
    return with_git_root(false, function(git_root)
        local result =
            vim.system({ "git", "diff", "--cached", "--name-only", "--", file }, { text = true, cwd = git_root }):wait()

        if result.code ~= 0 then
            return false
        end

        return vim.trim(result.stdout) ~= ""
    end)
end

---Check if a file has unstaged changes (working tree differs from index)
---@param file string File path relative to git root
---@return boolean
function M.has_unstaged_changes(file)
    return with_git_root(false, function(git_root)
        -- git diff (no --cached) compares working tree to index
        local result = vim.system({ "git", "diff", "--name-only", "--", file }, { text = true, cwd = git_root }):wait()

        if result.code ~= 0 then
            return false
        end

        return vim.trim(result.stdout) ~= ""
    end)
end

---Get set of staged files (batch operation — avoids N+1 is_staged calls)
---@return table<string, boolean> Set of staged file paths
function M.get_staged_files()
    return with_git_root({}, function(git_root)
        local result = vim.system({ "git", "diff", "--cached", "--name-only" }, { text = true, cwd = git_root }):wait()

        if result.code ~= 0 then
            return {}
        end

        local staged = {}
        for line in parse_lines(result.stdout) do
            if line ~= "" then
                staged[line] = true
            end
        end

        return staged
    end)
end

---Get set of files with unstaged changes (batch operation)
---@return table<string, boolean> Set of files with unstaged changes
function M.get_unstaged_files()
    return with_git_root({}, function(git_root)
        -- git diff (no --cached) compares working tree to index
        local result = vim.system({ "git", "diff", "--name-only" }, { text = true, cwd = git_root }):wait()

        if result.code ~= 0 then
            return {}
        end

        local unstaged = {}
        for line in parse_lines(result.stdout) do
            if line ~= "" then
                unstaged[line] = true
            end
        end

        return unstaged
    end)
end

---@alias GitFileStatus "added"|"modified"|"deleted"|"renamed"

---Get the git status of a file
---@param file string File path relative to git root
---@param base string|nil Base commit to compare against (default: HEAD)
---@return GitFileStatus
function M.get_file_status(file, base)
    base = base or "HEAD"
    return with_git_root("modified", function(git_root)
        -- Check if untracked (new file) - only for HEAD comparison
        if base == "HEAD" and M.is_untracked(file) then
        return "added"
    end

    -- Check file status relative to base
    local result = vim.system(
        { "git", "diff", "-M", "--name-status", base, "--", file },
        { text = true, cwd = git_root }
    )
        :wait()

    if result.code == 0 and result.stdout ~= "" then
        local status_char = result.stdout:sub(1, 1)
        if status_char == "D" then
            return "deleted"
        elseif status_char == "A" then
            return "added"
        elseif status_char == "R" then
            return "renamed"
        end
    end

    -- Also check staged changes (only for HEAD comparison)
    if base == "HEAD" then
        local staged_result = vim.system(
            { "git", "diff", "-M", "--cached", "--name-status", "--", file },
            { text = true, cwd = git_root }
        ):wait()

        if staged_result.code == 0 and staged_result.stdout ~= "" then
            local status_char = staged_result.stdout:sub(1, 1)
            if status_char == "D" then
                return "deleted"
            elseif status_char == "A" then
                return "added"
            elseif status_char == "R" then
                return "renamed"
            end
        end
    end

        return "modified"
    end)
end

---Get git status for multiple files in one batch call
---This is much more efficient than calling get_file_status() for each file
---@param files string[] List of file paths relative to git root
---@param base string|nil Base commit to compare against (default: HEAD)
---@param base_end string|nil End of commit range (when set, uses base..base_end)
---@return table<string, GitFileStatus> Map of file path to status
---@return table<string, string> Map of new_path to old_path for renamed files
function M.get_all_file_statuses(files, base, base_end)
    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        local result = {}
        for _, file in ipairs(files) do
            result[file] = "modified"
        end
        return result, {}
    end

    local statuses = {}
    local rename_map = {}
    local untracked_set = {}

    if base_end then
        local result = vim.system(
            { "git", "diff", "-M", "--name-status", base .. "..." .. base_end },
            { text = true, cwd = git_root }
        ):wait()

        if result.code == 0 then
            for line in parse_lines(result.stdout) do
                local rename_status, old_path, new_path = line:match("^(R%d*)%s+(.+)%s+(.+)$")
                if rename_status and old_path and new_path then
                    statuses[new_path] = "renamed"
                    rename_map[new_path] = old_path
                else
                    local status_char, file_path = line:match("^(%S+)%s+(.+)$")
                    if status_char and file_path then
                        if status_char == "D" then
                            statuses[file_path] = "deleted"
                        elseif status_char == "A" then
                            statuses[file_path] = "added"
                        else
                            statuses[file_path] = "modified"
                        end
                    end
                end
            end
        end

        local result_map = {}
        local result_rename_map = {}
        for _, file in ipairs(files) do
            if statuses[file] then
                result_map[file] = statuses[file]
                if rename_map[file] then
                    result_rename_map[file] = rename_map[file]
                end
            else
                result_map[file] = "modified"
            end
        end

        return result_map, result_rename_map
    end

    -- Get all untracked files (only for HEAD comparison)
    if base == "HEAD" then
        local untracked = vim.system(
            { "git", "ls-files", "--others", "--exclude-standard" },
            { text = true, cwd = git_root }
        )
            :wait()
        if untracked.code == 0 then
            for line in parse_lines(untracked.stdout) do
                if line ~= "" then
                    untracked_set[line] = true
                end
            end
        end
    end

    -- Get all file statuses relative to base in one call
    local result = vim.system({ "git", "diff", "-M", "--name-status", base }, { text = true, cwd = git_root }):wait()

    if result.code == 0 then
        for line in parse_lines(result.stdout) do
            local rename_status, old_path, new_path = line:match("^(R%d*)%s+(.+)%s+(.+)$")
            if rename_status and old_path and new_path then
                statuses[new_path] = "renamed"
                rename_map[new_path] = old_path
            else
                local status_char, file_path = line:match("^(%S+)%s+(.+)$")
                if status_char and file_path then
                    if status_char == "D" then
                        statuses[file_path] = "deleted"
                    elseif status_char == "A" then
                        statuses[file_path] = "added"
                    else
                        statuses[file_path] = "modified"
                    end
                end
            end
        end
    end

    -- Also check staged changes (only for HEAD comparison)
    if base == "HEAD" then
        local staged_result = vim.system(
            { "git", "diff", "-M", "--cached", "--name-status" },
            { text = true, cwd = git_root }
        )
            :wait()

        if staged_result.code == 0 then
            for line in parse_lines(staged_result.stdout) do
                local rename_status, old_path, new_path = line:match("^(R%d*)%s+(.+)%s+(.+)$")
                if rename_status and old_path and new_path and not statuses[new_path] then
                    statuses[new_path] = "renamed"
                    rename_map[new_path] = old_path
                else
                    local status_char, file_path = line:match("^(%S+)%s+(.+)$")
                    if status_char and file_path and not statuses[file_path] then
                        if status_char == "D" then
                            statuses[file_path] = "deleted"
                        elseif status_char == "A" then
                            statuses[file_path] = "added"
                        else
                            statuses[file_path] = "modified"
                        end
                    end
                end
            end
        end
    end

    -- Build final result for requested files
    local result_map = {}
    local result_rename_map = {}
    for _, file in ipairs(files) do
        if base == "HEAD" and untracked_set[file] then
            result_map[file] = "added"
        elseif statuses[file] then
            result_map[file] = statuses[file]
            if rename_map[file] then
                result_rename_map[file] = rename_map[file]
            end
        else
            result_map[file] = "modified"
        end
    end

    return result_map, result_rename_map
end

---Get recent commits
---@param count number Number of commits to fetch (default 20)
---@return table[] commits with {hash, short_hash, subject, author, date, parent_count}
function M.get_recent_commits(count)
    count = count or 20
    return with_git_root({}, function(git_root)
        local result = vim.system(
            { "git", "log", "--oneline", "--pretty=format:%H|%h|%s|%an|%ar|%P", "-n", tostring(count) },
            { text = true, cwd = git_root }
        ):wait()

        if result.code ~= 0 then
            return {}
        end

        local commits = {}
        for line in parse_lines(result.stdout) do
            local hash, short_hash, subject, author, date, parents =
                line:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|?(.*)")
            if hash then
                local parent_count = 0
                if parents and parents ~= "" then
                    for _ in parents:gmatch("%S+") do
                        parent_count = parent_count + 1
                    end
                end
                table.insert(commits, {
                    hash = hash,
                    short_hash = short_hash,
                    subject = subject,
                    author = author,
                    date = date,
                    parent_count = parent_count,
                })
            end
        end

        return commits
    end)
end

---Get local branch names
---@param callback fun(branches: string[])
function M.get_local_branches(callback)
    local git_root = M.get_root()
    if not git_root then
        callback({})
        return
    end

    vim.system({ "git", "branch", "--format=%(refname:short)" }, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback({})
                return
            end

            local branches = {}
            for line in parse_lines(result.stdout) do
                if line ~= "" then
                    table.insert(branches, line)
                end
            end
            callback(branches)
        end)
    end)
end

---Get the main branch name (checks for "main" first, then "master")
---@return string
function M.get_main_branch()
    return with_git_root("main", function(git_root)
        local result = vim.system(
            { "git", "rev-parse", "--verify", "--quiet", "refs/heads/main" },
            { text = true, cwd = git_root }
        )
            :wait()

        if result.code == 0 then
            return "main"
        end

        local master_result = vim.system(
            { "git", "rev-parse", "--verify", "--quiet", "refs/heads/master" },
            { text = true, cwd = git_root }
        ):wait()

        if master_result.code == 0 then
            return "master"
        end

        return "main"
    end)
end

---Get the current branch name
---@param callback fun(branch: string|nil)
function M.get_current_branch(callback)
    local git_root = M.get_root()
    if not git_root then
        callback(nil)
        return
    end

    vim.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                callback(vim.trim(result.stdout))
            else
                callback(nil)
            end
        end)
    end)
end

---Commit staged changes asynchronously
---@param message string Commit message subject line
---@param callback fun(success: boolean, error: string|nil)
---@param description? string Optional commit body/description
function M.commit(message, callback, description)
    local git_root = M.get_root()
    if not git_root then
        callback(false, "Not a git repository")
        return
    end

    local cmd = { "git", "commit", "-m", message }
    if description and description ~= "" then
        table.insert(cmd, "-m")
        table.insert(cmd, description)
    end

    vim.system(cmd, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                callback(true, nil)
            else
                callback(false, vim.trim(result.stderr))
            end
        end)
    end)
end

---Stage all changes (tracked and untracked)
---@return boolean success
function M.stage_all()
    local git_root = M.get_root()
    if not git_root then
        log.error("stage_all: no git root")
        return false
    end

    log.info("stage_all")
    local result = vim.system({ "git", "add", "-A" }, { text = true, cwd = git_root }):wait()

    if result.code ~= 0 then
        log.error("stage_all failed:", result.stderr)
    end
    return result.code == 0
end

function M.unstage_all()
    local git_root = M.get_root()
    if not git_root then
        log.error("unstage_all: no git root")
        return false
    end

    log.info("unstage_all")
    local result = vim.system({ "git", "reset", "HEAD" }, { text = true, cwd = git_root }):wait()

    if result.code ~= 0 then
        log.error("unstage_all failed:", result.stderr)
    end
    return result.code == 0
end

---Amend staged changes to the last commit (keep the same message)
---@param callback fun(success: boolean, error: string|nil)
function M.amend_no_edit(callback)
    local git_root = M.get_root()
    if not git_root then
        callback(false, "Not a git repository")
        return
    end

    vim.system(
        { "git", "commit", "--amend", "--no-edit" },
        { text = true, cwd = git_root },
        function(result)
            vim.schedule(function()
                if result.code == 0 then
                    callback(true, nil)
                else
                    callback(false, vim.trim(result.stderr))
                end
            end)
        end
    )
end

---Soft reset HEAD (uncommit last commit, keeping changes staged)
---@param callback fun(success: boolean, error: string|nil)
function M.soft_reset_head(callback)
    local git_root = M.get_root()
    if not git_root then
        callback(false, "Not a git repository")
        return
    end

    vim.system(
        { "git", "reset", "--soft", "HEAD~1" },
        { text = true, cwd = git_root },
        function(result)
            vim.schedule(function()
                if result.code == 0 then
                    callback(true, nil)
                else
                    callback(false, vim.trim(result.stderr))
                end
            end)
        end
    )
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

    local result = vim.system({ "git", "show", rev .. ":" .. file }, { text = true, cwd = git_root }):wait()

    if result.code ~= 0 then
        return nil, result.stderr
    end

    return result.stdout, nil
end

---Get file content from the working tree
---@param file string File path relative to git root
---@return string|nil content, string|nil error
function M.get_working_tree_file(file)
    local git_root = M.get_root()
    if not git_root then
        return nil, "Not in a git repository"
    end

    local full_path = git_root .. "/" .. file
    local lines = vim.fn.readfile(full_path)
    if not lines then
        return nil, "Could not read file: " .. full_path
    end

    return table.concat(lines, "\n"), nil
end

---Get hashes of unpushed commits (commits ahead of upstream)
---@return table<string, boolean> Set of commit hashes that are unpushed
function M.get_unpushed_hashes()
    return with_git_root({}, function(git_root)
        local result = vim.system(
            { "git", "rev-list", "@{u}..HEAD" },
            { text = true, cwd = git_root }
        ):wait()

        if result.code ~= 0 then
            return {}
        end

        local hashes = {}
        for line in parse_lines(result.stdout) do
            if line ~= "" then
                hashes[line] = true
            end
        end

        return hashes
    end)
end

---Get count of unpushed commits (commits ahead of upstream)
---@param callback fun(count: number|nil) nil if no upstream configured
function M.get_unpushed_count(callback)
    local git_root = M.get_root()
    if not git_root then
        callback(nil)
        return
    end

    vim.system({ "git", "rev-list", "--count", "@{u}..HEAD" }, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                local count = tonumber(vim.trim(result.stdout))
                callback(count or 0)
            else
                callback(nil)
            end
        end)
    end)
end

---Get ahead/behind counts for all local branches relative to their upstream
---@param callback fun(counts: table<string, {ahead: number, behind: number}>)
function M.get_branch_sync_counts(callback)
    local git_root = M.get_root()
    if not git_root then
        callback({})
        return
    end

    vim.system(
        { "git", "for-each-ref", "--format=%(refname:short) %(upstream:track)", "refs/heads/" },
        { text = true, cwd = git_root },
        function(result)
            vim.schedule(function()
                local counts = {}
                if result.code ~= 0 then
                    callback(counts)
                    return
                end

                for line in parse_lines(result.stdout) do
                    local branch_name, track = line:match("^(%S+)%s*(.*)$")
                    if branch_name then
                        local ahead = tonumber(track:match("ahead (%d+)")) or 0
                        local behind = tonumber(track:match("behind (%d+)")) or 0
                        if ahead > 0 or behind > 0 then
                            counts[branch_name] = { ahead = ahead, behind = behind }
                        end
                    end
                end

                callback(counts)
            end)
        end
    )
end

---Check if the working tree has uncommitted changes (staged or unstaged)
---@param callback fun(is_dirty: boolean)
function M.has_dirty_worktree(callback)
    local git_root = M.get_root()
    if not git_root then
        callback(false)
        return
    end

    vim.system({ "git", "status", "--porcelain" }, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false)
                return
            end

            local is_dirty = vim.trim(result.stdout) ~= ""
            callback(is_dirty)
        end)
    end)
end

---Checkout a branch asynchronously
---@param branch_name string
---@param callback fun(success: boolean, error: string|nil)
function M.checkout(branch_name, callback)
    local git_root = M.get_root()
    if not git_root then
        log.error("checkout: no git root")
        callback(false, "Not a git repository")
        return
    end

    log.info("checkout: switching to", branch_name)
    vim.system({ "git", "checkout", branch_name }, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                log.info("checkout: success", branch_name)
                callback(true, nil)
            else
                local err = vim.trim(result.stderr)
                log.error("checkout: failed:", err)
                callback(false, err)
            end
        end)
    end)
end

---Create and checkout a new branch off a base branch asynchronously
---@param branch_name string
---@param base_branch string
---@param callback fun(success: boolean, error: string|nil)
function M.create_branch(branch_name, base_branch, callback)
    local git_root = M.get_root()
    if not git_root then
        log.error("create_branch: no git root")
        callback(false, "Not a git repository")
        return
    end

    log.info("create_branch: creating", branch_name, "from", base_branch)
    vim.system({ "git", "checkout", "-b", branch_name, base_branch }, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                log.info("create_branch: success", branch_name)
                callback(true, nil)
            else
                local err = vim.trim(result.stderr)
                log.error("create_branch: failed:", err)
                callback(false, err)
            end
        end)
    end)
end

---Delete a local branch asynchronously
---@param branch_name string
---@param callback fun(success: boolean, error: string|nil)
function M.delete_branch(branch_name, callback)
    local git_root = M.get_root()
    if not git_root then
        log.error("delete_branch: no git root")
        callback(false, "Not a git repository")
        return
    end

    log.info("delete_branch: deleting", branch_name)
    vim.system({ "git", "branch", "-d", branch_name }, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                log.info("delete_branch: success", branch_name)
                callback(true, nil)
            else
                local err = vim.trim(result.stderr)
                log.error("delete_branch: failed:", err)
                callback(false, err)
            end
        end)
    end)
end

---Pull from remote asynchronously (fast-forward only, aborts on conflicts)
---@param callback fun(success: boolean, error: string|nil)
function M.pull(callback)
    local git_root = M.get_root()
    if not git_root then
        log.error("pull: no git root")
        callback(false, "Not a git repository")
        return
    end

    log.info("pull: starting")
    vim.system({ "git", "pull", "--ff-only" }, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                log.info("pull: success")
                callback(true, nil)
            else
                local err = vim.trim(result.stderr)
                log.error("pull: failed:", err)
                callback(false, err)
            end
        end)
    end)
end

---Push to remote asynchronously
---@param callback fun(success: boolean, error: string|nil)
---@param force? boolean Use --force-with-lease for safer force push
function M.push(callback, force)
    local git_root = M.get_root()
    if not git_root then
        log.error("push: no git root")
        callback(false, "Not a git repository")
        return
    end

    local cmd = { "git", "push" }
    if force then
        table.insert(cmd, "--force-with-lease")
    end

    log.info("push: starting", force and "(force-with-lease)" or "")
    vim.system(cmd, { text = true, cwd = git_root }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                log.info("push: success")
                callback(true, nil)
            else
                log.error("push: failed:", vim.trim(result.stderr))
                callback(false, vim.trim(result.stderr))
            end
        end)
    end)
end

---Buffer raw chunks into complete lines, calling on_line for each
---@param on_line fun(line: string)
---@return fun(err: string|nil, data: string|nil)
local function line_buffered_handler(on_line)
    local buffer = ""
    return function(_err, data)
        if not data then
            if buffer ~= "" then
                vim.schedule(function()
                    on_line(buffer)
                end)
                buffer = ""
            end
            return
        end
        buffer = buffer .. data
        while true do
            local newline_pos = buffer:find("\n")
            if not newline_pos then
                break
            end
            local line = buffer:sub(1, newline_pos - 1)
            buffer = buffer:sub(newline_pos + 1)
            vim.schedule(function()
                on_line(line)
            end)
        end
    end
end

---Commit staged changes with streaming output (for hook visibility)
---@param message string Commit message subject line
---@param on_output fun(line: string) Called per-line as hooks produce output
---@param callback fun(success: boolean, error: string|nil)
---@param description? string Optional commit body/description
function M.commit_streaming(message, on_output, callback, description)
    local git_root = M.get_root()
    if not git_root then
        log.error("commit_streaming: no git root")
        callback(false, "Not a git repository")
        return
    end

    local cmd = { "git", "commit", "-m", message }
    if description and description ~= "" then
        table.insert(cmd, "-m")
        table.insert(cmd, description)
    end

    log.info("commit_streaming:", table.concat(cmd, " "))

    local handler = line_buffered_handler(on_output)

    vim.system(cmd, {
        cwd = git_root,
        stdout = handler,
        stderr = handler,
    }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                log.info("commit_streaming: success")
                callback(true, nil)
            else
                local error_output = vim.trim((result.stderr or "") .. (result.stdout or ""))
                log.error("commit_streaming: failed:", error_output)
                callback(false, error_output ~= "" and error_output or "Commit failed")
            end
        end)
    end)
end

---Amend staged changes with streaming output (for hook visibility)
---@param on_output fun(line: string) Called per-line as hooks produce output
---@param callback fun(success: boolean, error: string|nil)
function M.amend_no_edit_streaming(on_output, callback)
    local git_root = M.get_root()
    if not git_root then
        callback(false, "Not a git repository")
        return
    end

    local handler = line_buffered_handler(on_output)

    vim.system({ "git", "commit", "--amend", "--no-edit" }, {
        cwd = git_root,
        stdout = handler,
        stderr = handler,
    }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                callback(true, nil)
            else
                local error_output = vim.trim((result.stderr or "") .. (result.stdout or ""))
                callback(false, error_output ~= "" and error_output or "Amend failed")
            end
        end)
    end)
end

-- ============================================================================
-- Async variants (must be called inside async.run())
-- ============================================================================

local async = require("review.core.async")

---Parse output lines into a set
---@param stdout string
---@return table<string, boolean>
local function parse_name_set(stdout)
    local result = {}
    for line in parse_lines(stdout) do
        if line ~= "" then
            result[line] = true
        end
    end
    return result
end

---Async: get set of staged files
---@return table<string, boolean>
function M.get_staged_files_async()
    return with_git_root({}, function(git_root)
        local result = async.system({ "git", "diff", "--cached", "--name-only" }, { text = true, cwd = git_root })
        if result.code ~= 0 then
            return {}
        end

        return parse_name_set(result.stdout)
    end)
end

---Async: get set of files with unstaged changes
---@return table<string, boolean>
function M.get_unstaged_files_async()
    return with_git_root({}, function(git_root)
        local result = async.system({ "git", "diff", "--name-only" }, { text = true, cwd = git_root })
        if result.code ~= 0 then
            return {}
        end

        return parse_name_set(result.stdout)
    end)
end

---Async: get changed files (unstaged, staged, and untracked) — runs 3 git calls concurrently
---@param base string|nil Base commit to compare against (default: HEAD)
---@param base_end string|nil End of commit range
---@return string[]
function M.get_changed_files_async(base, base_end)
    base = base or "HEAD"
    return with_git_root({}, function(git_root)

    if base_end then
        local range_result = async.system(
            { "git", "diff", "-M", "--name-only", base .. "..." .. base_end },
            { text = true, cwd = git_root }
        )

        local files = {}
        local seen = {}
        if range_result.code == 0 then
            for line in parse_lines(range_result.stdout) do
                if line ~= "" and not seen[line] then
                    seen[line] = true
                    table.insert(files, line)
                end
            end
        end
        return files
    end

    local results = async.all({
        function()
            return async.system({ "git", "diff", "-M", "--name-only", base }, { text = true, cwd = git_root })
        end,
        function()
            return async.system({ "git", "diff", "-M", "--cached", "--name-only" }, { text = true, cwd = git_root })
        end,
        function()
            return async.system(
                { "git", "ls-files", "--others", "--exclude-standard" },
                { text = true, cwd = git_root }
            )
        end,
    })

    local files = {}
    local seen = {}
    for _, result in ipairs(results) do
        if result.code == 0 then
            for line in parse_lines(result.stdout) do
                if line ~= "" and not seen[line] then
                    seen[line] = true
                    table.insert(files, line)
                end
            end
        end
    end

        return files
    end)
end

---Async: get all file statuses — runs concurrent git calls
---@param files string[] List of file paths relative to git root
---@param base string|nil Base commit to compare against (default: HEAD)
---@param base_end string|nil End of commit range
---@return table<string, GitFileStatus> statuses
---@return table<string, string> rename_map
function M.get_all_file_statuses_async(files, base, base_end)
    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        local result = {}
        for _, file in ipairs(files) do
            result[file] = "modified"
        end
        return result, {}
    end

    if base_end then
        local range_result = async.system(
            { "git", "diff", "-M", "--name-status", base .. "..." .. base_end },
            { text = true, cwd = git_root }
        )

        local statuses = {}
        local rename_map = {}

        if range_result.code == 0 then
            for line in parse_lines(range_result.stdout) do
                local rename_status, old_path, new_path = line:match("^(R%d*)%s+(.+)%s+(.+)$")
                if rename_status and old_path and new_path then
                    statuses[new_path] = "renamed"
                    rename_map[new_path] = old_path
                else
                    local status_char, file_path = line:match("^(%S+)%s+(.+)$")
                    if status_char and file_path then
                        if status_char == "D" then
                            statuses[file_path] = "deleted"
                        elseif status_char == "A" then
                            statuses[file_path] = "added"
                        else
                            statuses[file_path] = "modified"
                        end
                    end
                end
            end
        end

        local result_map = {}
        local result_rename_map = {}
        for _, file in ipairs(files) do
            result_map[file] = statuses[file] or "modified"
            if rename_map[file] then
                result_rename_map[file] = rename_map[file]
            end
        end

        return result_map, result_rename_map
    end

    -- HEAD mode: run all 3 git calls concurrently
    local concurrent_results = async.all({
        function()
            return async.system(
                { "git", "ls-files", "--others", "--exclude-standard" },
                { text = true, cwd = git_root }
            )
        end,
        function()
            return async.system({ "git", "diff", "-M", "--name-status", base }, { text = true, cwd = git_root })
        end,
        function()
            return async.system({ "git", "diff", "-M", "--cached", "--name-status" }, { text = true, cwd = git_root })
        end,
    })

    local untracked_result = concurrent_results[1]
    local diff_result = concurrent_results[2]
    local staged_result = concurrent_results[3]

    local untracked_set = {}
    if base == "HEAD" and untracked_result.code == 0 then
        untracked_set = parse_name_set(untracked_result.stdout)
    end

    local statuses = {}
    local rename_map = {}

    local function parse_name_status(stdout)
        for line in parse_lines(stdout) do
            local rs, old_path, new_path = line:match("^(R%d*)%s+(.+)%s+(.+)$")
            if rs and old_path and new_path then
                if not statuses[new_path] then
                    statuses[new_path] = "renamed"
                    rename_map[new_path] = old_path
                end
            else
                local status_char, file_path = line:match("^(%S+)%s+(.+)$")
                if status_char and file_path and not statuses[file_path] then
                    if status_char == "D" then
                        statuses[file_path] = "deleted"
                    elseif status_char == "A" then
                        statuses[file_path] = "added"
                    else
                        statuses[file_path] = "modified"
                    end
                end
            end
        end
    end

    if diff_result.code == 0 then
        parse_name_status(diff_result.stdout)
    end
    if base == "HEAD" and staged_result.code == 0 then
        parse_name_status(staged_result.stdout)
    end

    local result_map = {}
    local result_rename_map = {}
    for _, file in ipairs(files) do
        if base == "HEAD" and untracked_set[file] then
            result_map[file] = "added"
        elseif statuses[file] then
            result_map[file] = statuses[file]
            if rename_map[file] then
                result_rename_map[file] = rename_map[file]
            end
        else
            result_map[file] = "modified"
        end
    end

    return result_map, result_rename_map
end

---Async: get diff for a specific file
---@param file string File path relative to git root
---@param base string|nil Base commit to compare against
---@param base_end string|nil End of commit range
---@param opts GetDiffOpts|nil Optional parameters
---@return GitDiffResult
function M.get_diff_async(file, base, base_end, opts)
    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return { success = false, output = "", error = "Not in a git repository" }
    end

    if base_end then
        local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
        local cmd = { "git", "diff", "-M", context_flag, base .. "..." .. base_end, "--", file }
        local result = async.system(cmd, { text = true, cwd = git_root })

        if result.code ~= 0 then
            return { success = false, output = "", error = result.stderr }
        end

        return { success = true, output = result.stdout, error = nil }
    end

    local file_status = opts and opts.file_status or nil

    local is_untracked = file_status == "untracked" or (not file_status and M.is_untracked(file))
    if is_untracked then
        local full_path = git_root .. "/" .. file
        local content = vim.fn.readfile(full_path)
        if not content or #content == 0 then
            return { success = true, output = "", error = nil }
        end

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

    local is_staged_only = file_status == "staged_only"
    if not file_status then
        local unstaged_result = async.system(
            { "git", "diff", "--name-only", "--", file },
            { text = true, cwd = git_root }
        )

        if unstaged_result.code == 0 and vim.trim(unstaged_result.stdout) == "" then
            local staged_result = async.system(
                { "git", "diff", "--cached", "--name-only", "--", file },
                { text = true, cwd = git_root }
            )
            if staged_result.code == 0 and vim.trim(staged_result.stdout) ~= "" then
                is_staged_only = true
            end
        end
    end

    local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
    local cmd
    if is_staged_only then
        cmd = { "git", "diff", "-M", context_flag, "--cached", "--", file }
    else
        cmd = { "git", "diff", "-M", context_flag, base, "--", file }
    end

    local result = async.system(cmd, { text = true, cwd = git_root })

    if result.code ~= 0 then
        return { success = false, output = "", error = result.stderr }
    end

    return { success = true, output = result.stdout, error = nil }
end

---Async: get file content at a specific revision
---@param file string File path relative to git root
---@param rev string|nil Git revision (default: HEAD)
---@return string|nil content, string|nil error
function M.get_file_at_rev_async(file, rev)
    rev = rev or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return nil, "Not in a git repository"
    end

    local result = async.system({ "git", "show", rev .. ":" .. file }, { text = true, cwd = git_root })

    if result.code ~= 0 then
        return nil, result.stderr
    end

    return result.stdout, nil
end

return M
