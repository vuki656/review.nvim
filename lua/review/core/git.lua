local limits = require("review.core.limits")
local log = require("review.core.log")

local M = {}

---@class GitDiffResult
---@field success boolean
---@field output string
---@field error string|nil
---@field too_large boolean|nil Diff was skipped because it is too big to render

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

    local result = vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "rev-parse", "--show-toplevel" },
        { text = true }
    ):wait()
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

local UNQUOTE_ESCAPES = {
    a = "\a",
    b = "\b",
    f = "\f",
    n = "\n",
    r = "\r",
    t = "\t",
    v = "\v",
    ["\\"] = "\\",
    ['"'] = '"',
}

---Decode a path git wrapped in C-style quoting.
---core.quotepath=false only suppresses quoting of non-ASCII bytes; git still
---quotes any path containing a quote, a backslash or a control character.
---@param path string
---@return string
function M.unquote_path(path)
    if not path or #path < 2 or path:sub(1, 1) ~= '"' or path:sub(-1) ~= '"' then
        return path
    end

    local body = path:sub(2, -2)
    local out = {}
    local index = 1

    while index <= #body do
        local char = body:sub(index, index)
        if char ~= "\\" then
            table.insert(out, char)
            index = index + 1
        else
            local octal = body:match("^([0-7][0-7][0-7])", index + 1)
            local escaped = body:sub(index + 1, index + 1)
            if octal then
                table.insert(out, string.char(tonumber(octal, 8)))
                index = index + 4
            elseif UNQUOTE_ESCAPES[escaped] then
                table.insert(out, UNQUOTE_ESCAPES[escaped])
                index = index + 2
            else
                table.insert(out, escaped)
                index = index + 2
            end
        end
    end

    return table.concat(out)
end

---Split output into non-empty lines, decoding any C-quoted paths
---@param output string
---@return fun(): string|nil iterator
local function parse_lines(output)
    local iterator = output:gmatch("[^\r\n]+")
    return function()
        local line = iterator()
        if line == nil then
            return nil
        end
        return M.unquote_path(line)
    end
end

---@class GitNameStatus
---@field status string One of added, modified, deleted, renamed, copied, conflicted
---@field path string Path the status applies to
---@field rename_from string|nil Original path for renames and copies

---Parse a single line of `git diff --name-status` output
---@param line string
---@return GitNameStatus|nil
function M.parse_name_status_line(line)
    if not line or line == "" then
        return nil
    end

    local rename_status, old_path, new_path = line:match("^([RC])%d*\t([^\t]+)\t([^\t]+)$")
    if rename_status and old_path and new_path then
        return {
            status = rename_status == "R" and "renamed" or "copied",
            path = M.unquote_path(new_path),
            rename_from = M.unquote_path(old_path),
        }
    end

    local status_char, file_path = line:match("^(%a)%d*\t(.+)$")
    if not status_char or not file_path then
        return nil
    end

    file_path = M.unquote_path(file_path)

    local status_map = {
        A = "added",
        D = "deleted",
        U = "conflicted",
    }

    return { status = status_map[status_char] or "modified", path = file_path }
end

---@class GitLineStats
---@field added number|nil Lines added, nil for binary files
---@field deleted number|nil Lines deleted, nil for binary files

---@class GitNumstat : GitLineStats
---@field path string Path the counts apply to (the new path for renames and copies)

---Resolve the path column of `git diff --numstat` output, which for renames
---and copies is either `old => new` or `dir/{old => new}/rest`
---@param raw string
---@return string
local function numstat_new_path(raw)
    local prefix, new_part, suffix = raw:match("^(.-){[^}]- => ([^}]*)}(.*)$")
    if prefix then
        -- An empty new part (`lua/{sub => }/init.lua`) leaves a doubled slash
        return (prefix .. new_part .. suffix):gsub("//+", "/")
    end

    local whole_new = raw:match("^.- => (.+)$")
    if whole_new then
        return whole_new
    end

    return raw
end

---Parse a single line of `git diff --numstat` output
---@param line string
---@return GitNumstat|nil
function M.parse_numstat_line(line)
    if not line or line == "" then
        return nil
    end

    local added, deleted, raw_path = line:match("^(%S+)\t(%S+)\t(.+)$")
    if not added or not deleted or not raw_path or raw_path == "" then
        return nil
    end

    return {
        added = tonumber(added),
        deleted = tonumber(deleted),
        path = M.unquote_path(numstat_new_path(raw_path)),
    }
end

---Record a parsed name-status line into status and rename maps
---@param line string
---@param statuses table<string, string>
---@param rename_map table<string, string>
---@param keep_existing boolean|nil Skip paths already recorded
local function apply_name_status_line(line, statuses, rename_map, keep_existing)
    local entry = M.parse_name_status_line(line)
    if not entry then
        return
    end

    if keep_existing and statuses[entry.path] then
        return
    end

    statuses[entry.path] = entry.status
    if entry.rename_from then
        rename_map[entry.path] = entry.rename_from
    end
end

---Parse a single line of the commit log format used by get_commits
---@param line string
---@return table|nil
function M.parse_commit_line(line)
    if not line or line == "" then
        return nil
    end

    local fields = vim.split(line, "\31", { plain = true })
    if #fields < 6 then
        return nil
    end

    local parents = fields[6]
    local parent_count = 0
    if parents and parents ~= "" then
        for _ in parents:gmatch("%S+") do
            parent_count = parent_count + 1
        end
    end

    return {
        hash = fields[1],
        short_hash = fields[2],
        subject = fields[3],
        author = fields[4],
        date = fields[5],
        parent_count = parent_count,
        is_merge = parent_count > 1,
    }
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
    if not M.is_safe_rev(base) or not M.is_safe_rev(base_end) then
        log.error("get_changed_files: refusing unsafe revision")
        return {}
    end

    return with_git_root({}, function(git_root)
        local files = {}
        local seen = {}

        if base_end then
            local range_result = vim.system({
                "git",
                "-c",
                "core.quotepath=false",
                "--literal-pathspecs",
                "diff",
                "-M",
                "--name-only",
                base .. "..." .. base_end,
            }, { text = true, cwd = git_root }):wait()

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
        local unstaged = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", "--name-only", base },
            { text = true, cwd = git_root }
        ):wait()

        if unstaged.code == 0 then
            for line in parse_lines(unstaged.stdout) do
                if line ~= "" and not seen[line] then
                    seen[line] = true
                    table.insert(files, line)
                end
            end
        end

        -- Get staged changes
        local staged = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", "--cached", "--name-only" },
            { text = true, cwd = git_root }
        ):wait()

        if staged.code == 0 then
            for line in parse_lines(staged.stdout) do
                if line ~= "" and not seen[line] then
                    seen[line] = true
                    table.insert(files, line)
                end
            end
        end

        -- Get untracked files
        local untracked = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "ls-files",
            "--others",
            "--exclude-standard",
        }, { text = true, cwd = git_root }):wait()

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

---Build the ls-files command that reports whether a path is untracked
---@param file string
---@return string[]
local function untracked_cmd(file)
    return {
        "git",
        "-c",
        "core.quotepath=false",
        "--literal-pathspecs",
        "ls-files",
        "--others",
        "--exclude-standard",
        "--",
        file,
    }
end

---Check if a file is untracked
---@param file string File path relative to git root
---@return boolean
function M.is_untracked(file)
    return with_git_root(false, function(git_root)
        local result = vim.system(untracked_cmd(file), { text = true, cwd = git_root }):wait()

        return result.code == 0 and vim.trim(result.stdout) ~= ""
    end)
end

---Whether a revision is safe to pass to git as a bare operand.
---Revisions must precede "--", so one starting with "-" is parsed as an option.
---@param rev string|nil
---@return boolean
function M.is_safe_rev(rev)
    if rev == nil then
        return true
    end
    return type(rev) == "string" and rev ~= "" and rev:sub(1, 1) ~= "-"
end

---Read the leading bytes of a file without pulling the whole thing into memory
---@param path string
---@return string|nil
local function read_probe(path)
    local fd = vim.uv.fs_open(path, "r", 438)
    if not fd then
        return nil
    end

    local ok, chunk = pcall(vim.uv.fs_read, fd, limits.BINARY_PROBE_BYTES, 0)
    vim.uv.fs_close(fd)

    if not ok then
        return nil
    end
    return chunk
end

---Cap a raw diff so callers never parse or render something huge
---@param output string
---@return GitDiffResult
local function capped_diff_result(output)
    if limits.is_too_large(#output, limits.MAX_DIFF_BYTES) then
        return { success = true, output = "", error = nil, too_large = true }
    end
    return { success = true, output = output, error = nil }
end

---Synthesize an add-only diff for an untracked file
---@param git_root string
---@param file string File path relative to git root
---@return GitDiffResult
local function untracked_diff(git_root, file)
    local full_path = git_root .. "/" .. file

    local stat = vim.uv.fs_stat(full_path)
    if not stat or stat.type ~= "file" then
        return { success = true, output = "", error = nil }
    end

    if limits.is_too_large(stat.size, limits.MAX_DIFF_BYTES) then
        return { success = true, output = "", error = nil, too_large = true }
    end

    if limits.is_binary_chunk(read_probe(full_path)) then
        return {
            success = true,
            output = "Binary files /dev/null and b/" .. file .. " differ",
            error = nil,
        }
    end

    local read_ok, content = pcall(vim.fn.readfile, full_path)
    if not read_ok or not content or #content == 0 then
        return { success = true, output = "", error = nil }
    end

    -- readfile turns NUL bytes into newlines, so an entry containing one means
    -- binary content past the probe; emitting it would corrupt the synthesized diff
    for _, line in ipairs(content) do
        if line:find("\n", 1, true) then
            return {
                success = true,
                output = "Binary files /dev/null and b/" .. file .. " differ",
                error = nil,
            }
        end
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

---Line stats for an untracked file, mirroring the add-only diff untracked_diff
---synthesizes for it. Binary, oversized and unreadable files count as binary.
---@param git_root string
---@param file string File path relative to git root
---@return GitLineStats
local function untracked_line_stats(git_root, file)
    local full_path = git_root .. "/" .. file

    local stat = vim.uv.fs_stat(full_path)
    if not stat or stat.type ~= "file" then
        return { added = 0, deleted = 0 }
    end

    if limits.is_too_large(stat.size, limits.MAX_DIFF_BYTES) or limits.is_binary_chunk(read_probe(full_path)) then
        return { added = nil, deleted = nil }
    end

    local read_ok, content = pcall(vim.fn.readfile, full_path)
    if not read_ok or not content then
        return { added = nil, deleted = nil }
    end

    return { added = #content, deleted = 0 }
end

local rename_source_cache = {}

---@param base string
---@param staged boolean
---@param git_root string
---@return string
local function rename_cache_key(base, staged, git_root)
    return (staged and "staged" or base) .. "\0" .. git_root
end

---@param staged boolean
---@param base string
---@return string[]
local function rename_source_cmd(staged, base)
    local cmd = { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", "--name-status" }
    if staged then
        table.insert(cmd, "--cached")
    else
        table.insert(cmd, base)
    end
    return cmd
end

---@param stdout string|nil
---@return table<string, string>
local function parse_rename_sources(stdout)
    local sources = {}
    for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
        local parsed = M.parse_name_status_line(line)
        if parsed and parsed.rename_from then
            sources[parsed.path] = parsed.rename_from
        end
    end
    return sources
end

---Find the source path of a renamed or copied file
---@param git_root string
---@param file string New path
---@param base string Base to compare against
---@param staged boolean Whether to look in the index rather than the worktree
---@return string|nil
local function find_rename_source(git_root, file, base, staged)
    local cache_key = rename_cache_key(base, staged, git_root)
    local cached = rename_source_cache[cache_key]

    if not cached then
        local result = vim.system(rename_source_cmd(staged, base), { text = true, cwd = git_root }):wait()
        if result.code ~= 0 then
            return nil
        end

        cached = parse_rename_sources(result.stdout)
        rename_source_cache[cache_key] = cached
    end

    return cached[file]
end

---Drop memoized rename lookups; call when the working tree or index changes
function M.clear_rename_cache()
    rename_source_cache = {}
end

---@class GetDiffOpts
---@field file_status "untracked"|"staged_only"|"unstaged"|nil Pre-resolved file status to skip subprocess calls
---@field rename_from string|nil Pre-resolved source path when the file is a rename

---Get diff for a specific file
---@param file string File path relative to git root
---@param base string|nil Base commit to compare against
---@param base_end string|nil End of commit range (when set, uses base..base_end)
---@param opts GetDiffOpts|nil Optional parameters
---@return GitDiffResult
function M.get_diff(file, base, base_end, opts)
    base = base or "HEAD"
    if not M.is_safe_rev(base) or not M.is_safe_rev(base_end) then
        log.error("get_diff: refusing unsafe revision", base, base_end)
        return { success = false, output = "", error = "Invalid revision" }
    end

    local git_root = M.get_root()
    if not git_root then
        return { success = false, output = "", error = "Not in a git repository" }
    end

    if base_end then
        local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
        local cmd = {
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "diff",
            "-M",
            context_flag,
            base .. "..." .. base_end,
            "--",
            file,
        }
        local result = vim.system(cmd, { text = true, cwd = git_root }):wait()

        if result.code ~= 0 then
            return { success = false, output = "", error = result.stderr }
        end

        return capped_diff_result(result.stdout)
    end

    local file_status = opts and opts.file_status or nil

    -- Check if file is untracked (new file)
    local is_untracked = file_status == "untracked" or (not file_status and M.is_untracked(file))
    if is_untracked then
        return untracked_diff(git_root, file)
    end

    -- Determine if file has only staged changes (no unstaged)
    local is_staged_only = base == "HEAD" and file_status == "staged_only"
    if base == "HEAD" and not file_status then
        local unstaged_result = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "--name-only", "--", file },
            { text = true, cwd = git_root }
        ):wait()

        if unstaged_result.code == 0 and vim.trim(unstaged_result.stdout) == "" then
            local staged_result = vim.system({
                "git",
                "-c",
                "core.quotepath=false",
                "--literal-pathspecs",
                "diff",
                "--cached",
                "--name-only",
                "--",
                file,
            }, { text = true, cwd = git_root }):wait()
            if staged_result.code == 0 and vim.trim(staged_result.stdout) ~= "" then
                is_staged_only = true
            end
        end
    end

    local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
    local cmd
    if is_staged_only then
        cmd = {
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "diff",
            "-M",
            context_flag,
            "--cached",
            "--",
            file,
        }
    else
        cmd =
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", context_flag, base, "--", file }
    end

    local result = vim.system(cmd, { text = true, cwd = git_root }):wait()

    if result.code ~= 0 then
        return { success = false, output = "", error = result.stderr }
    end

    if result.stdout:match("\nnew file mode") then
        local rename_from = opts and opts.rename_from or find_rename_source(git_root, file, base, is_staged_only)
        if rename_from then
            table.insert(cmd, rename_from)
            local retry = vim.system(cmd, { text = true, cwd = git_root }):wait()
            if retry.code == 0 and retry.stdout ~= "" then
                return capped_diff_result(retry.stdout)
            end
        end
    end

    return capped_diff_result(result.stdout)
end

---Get combined diff for a commit range in a single git call
---@param base string Base commit (parent)
---@param base_end string End commit
---@return GitDiffResult
function M.get_commit_diff(base, base_end)
    if not M.is_safe_rev(base) or not M.is_safe_rev(base_end) then
        log.error("get_commit_diff: refusing unsafe revision")
        return { success = false, output = "", error = "Invalid revision" }
    end

    local no_repo = { success = false, output = "", error = "Not in a git repository" }
    return with_git_root(no_repo, function(git_root)
        local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
        local result = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "diff",
            "-M",
            context_flag,
            base .. "..." .. base_end,
        }, { text = true, cwd = git_root }):wait()

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
    if not M.is_safe_rev(base) then
        log.error("get_full_diff: refusing unsafe revision")
        return { success = false, output = "", error = "Invalid revision" }
    end

    base = base or "HEAD"
    local no_repo = { success = false, output = "", error = "Not in a git repository" }
    return with_git_root(no_repo, function(git_root)
        local result = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", base },
            { text = true, cwd = git_root }
        ):wait()

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
    local result = vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "add", "--", file },
        { text = true, cwd = git_root }
    ):wait()

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
    local result = vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "reset", "HEAD", "--", file },
        { text = true, cwd = git_root }
    ):wait()

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

        local reset = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "checkout", "HEAD", "--", file },
            { text = true, cwd = git_root }
        ):wait()

        if reset.code == 0 then
            return true
        end

        local removed = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "rm", "-f", "--quiet", "--", file },
            { text = true, cwd = git_root }
        ):wait()

        if removed.code ~= 0 then
            log.error("restore_file: failed to restore", file, vim.trim(removed.stderr or reset.stderr or ""))
        end

        return removed.code == 0
    end)
end

---Check if a file is staged
---@param file string File path relative to git root
---@return boolean
function M.is_staged(file)
    return with_git_root(false, function(git_root)
        local result = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "diff",
            "--cached",
            "--name-only",
            "--",
            file,
        }, { text = true, cwd = git_root }):wait()

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
        local result = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "--name-only", "--", file },
            { text = true, cwd = git_root }
        ):wait()

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
        local result = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "--cached", "--name-only" },
            { text = true, cwd = git_root }
        ):wait()

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
        local result = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "--name-only" },
            { text = true, cwd = git_root }
        ):wait()

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
        local result = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "diff",
            "-M",
            "--name-status",
            base,
            "--",
            file,
        }, { text = true, cwd = git_root }):wait()

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
            local staged_result = vim.system({
                "git",
                "-c",
                "core.quotepath=false",
                "--literal-pathspecs",
                "diff",
                "-M",
                "--cached",
                "--name-status",
                "--",
                file,
            }, { text = true, cwd = git_root }):wait()

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
    if not M.is_safe_rev(base) or not M.is_safe_rev(base_end) then
        log.error("get_all_file_statuses: refusing unsafe revision")
        return {}, {}
    end

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
        local result = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "diff",
            "-M",
            "--name-status",
            base .. "..." .. base_end,
        }, { text = true, cwd = git_root }):wait()

        if result.code == 0 then
            for line in parse_lines(result.stdout) do
                apply_name_status_line(line, statuses, rename_map)
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
        local untracked = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "ls-files",
            "--others",
            "--exclude-standard",
        }, { text = true, cwd = git_root }):wait()
        if untracked.code == 0 then
            for line in parse_lines(untracked.stdout) do
                if line ~= "" then
                    untracked_set[line] = true
                end
            end
        end
    end

    -- Get all file statuses relative to base in one call
    local result = vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", "--name-status", base },
        { text = true, cwd = git_root }
    ):wait()

    if result.code == 0 then
        for line in parse_lines(result.stdout) do
            apply_name_status_line(line, statuses, rename_map)
        end
    end

    -- Also check staged changes (only for HEAD comparison)
    if base == "HEAD" then
        local staged_result = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", "--cached", "--name-status" },
            { text = true, cwd = git_root }
        ):wait()

        if staged_result.code == 0 then
            for line in parse_lines(staged_result.stdout) do
                apply_name_status_line(line, statuses, rename_map, true)
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
        local result = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "log",
            "--pretty=format:%H%x1f%h%x1f%s%x1f%an%x1f%ar%x1f%P",
            "-n",
            tostring(count),
        }, { text = true, cwd = git_root }):wait()

        if result.code ~= 0 then
            return {}
        end

        local commits = {}
        for line in parse_lines(result.stdout) do
            local commit = M.parse_commit_line(line)
            if commit then
                table.insert(commits, commit)
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

    vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "branch", "--format=%(refname:short)" },
        { text = true, cwd = git_root },
        function(result)
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
        end
    )
end

---Get the main branch name (checks "main", then "master", then origin/HEAD)
---@return string|nil
function M.get_main_branch()
    return with_git_root(nil, function(git_root)
        local result = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "rev-parse",
            "--verify",
            "--quiet",
            "refs/heads/main",
        }, { text = true, cwd = git_root }):wait()

        if result.code == 0 then
            return "main"
        end

        local master_result = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "rev-parse",
            "--verify",
            "--quiet",
            "refs/heads/master",
        }, { text = true, cwd = git_root }):wait()

        if master_result.code == 0 then
            return "master"
        end

        local head_result = vim.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "symbolic-ref",
            "--short",
            "refs/remotes/origin/HEAD",
        }, { text = true, cwd = git_root }):wait()

        if head_result.code == 0 then
            local ref = vim.trim(head_result.stdout)
            local branch = ref:match("^origin/(.+)$")
            if branch and branch ~= "" then
                return branch
            end
        end

        return nil
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

    vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "rev-parse", "--abbrev-ref", "HEAD" },
        { text = true, cwd = git_root },
        function(result)
            vim.schedule(function()
                if result.code == 0 then
                    callback(vim.trim(result.stdout))
                else
                    callback(nil)
                end
            end)
        end
    )
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

    local cmd = { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "commit", "-m", message }
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
    local result = vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "add", "-A" },
        { text = true, cwd = git_root }
    ):wait()

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
    local result = vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "reset", "HEAD" },
        { text = true, cwd = git_root }
    ):wait()

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
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "commit", "--amend", "--no-edit" },
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
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "reset", "--soft", "HEAD~1" },
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
    if not M.is_safe_rev(rev) then
        log.error("get_file_at_rev: refusing unsafe revision")
        return nil
    end

    rev = rev or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return nil, "Not in a git repository"
    end

    local result = vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "show", rev .. ":" .. file },
        { text = true, cwd = git_root }
    ):wait()

    if result.code ~= 0 then
        return nil, result.stderr
    end

    return result.stdout, nil
end

---Get file content from the working tree.
---Only used to feed syntax highlighting, so it refuses sources too big to parse.
---@param file string File path relative to git root
---@return string|nil content, string|nil error
function M.get_working_tree_file(file)
    local git_root = M.get_root()
    if not git_root then
        return nil, "Not in a git repository"
    end

    local full_path = git_root .. "/" .. file

    local stat = vim.uv.fs_stat(full_path)
    if not stat or stat.type ~= "file" then
        return nil, "Could not read file: " .. full_path
    end
    if limits.is_too_large(stat.size, limits.MAX_SOURCE_BYTES) then
        return nil, "File too large to highlight: " .. full_path
    end

    local read_ok, lines = pcall(vim.fn.readfile, full_path)
    if not read_ok or not lines then
        return nil, "Could not read file: " .. full_path
    end

    return table.concat(lines, "\n"), nil
end

---Get hashes of unpushed commits (commits ahead of upstream)
---@return table<string, boolean> Set of commit hashes that are unpushed
function M.get_unpushed_hashes()
    return with_git_root({}, function(git_root)
        local result = vim.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "rev-list", "@{u}..HEAD" },
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

    vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "rev-list", "--count", "@{u}..HEAD" },
        { text = true, cwd = git_root },
        function(result)
            vim.schedule(function()
                if result.code == 0 then
                    local count = tonumber(vim.trim(result.stdout))
                    callback(count or 0)
                else
                    callback(nil)
                end
            end)
        end
    )
end

---Get ahead/behind counts for all local branches relative to their upstream
---@param callback fun(counts: table<string, {ahead: number, behind: number}>)
function M.get_branch_sync_counts(callback)
    local git_root = M.get_root()
    if not git_root then
        callback({})
        return
    end

    vim.system({
        "git",
        "-c",
        "core.quotepath=false",
        "--literal-pathspecs",
        "for-each-ref",
        "--format=%(refname:short) %(upstream:track)",
        "refs/heads/",
    }, { text = true, cwd = git_root }, function(result)
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
    end)
end

---Check if the working tree has uncommitted changes (staged or unstaged)
---@param callback fun(is_dirty: boolean)
function M.has_dirty_worktree(callback)
    local git_root = M.get_root()
    if not git_root then
        callback(false)
        return
    end

    vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "status", "--porcelain" },
        { text = true, cwd = git_root },
        function(result)
            vim.schedule(function()
                if result.code ~= 0 then
                    callback(false)
                    return
                end

                local is_dirty = vim.trim(result.stdout) ~= ""
                callback(is_dirty)
            end)
        end
    )
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
    vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "checkout", branch_name },
        { text = true, cwd = git_root },
        function(result)
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
        end
    )
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
    vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "checkout", "-b", branch_name, base_branch },
        { text = true, cwd = git_root },
        function(result)
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
        end
    )
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
    vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "branch", "-d", branch_name },
        { text = true, cwd = git_root },
        function(result)
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
        end
    )
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
    vim.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "pull", "--ff-only" },
        { text = true, cwd = git_root },
        function(result)
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
        end
    )
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

    local cmd = { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "push" }
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
local function line_buffered_handler(on_line, captured)
    local buffer = ""
    local function emit(line)
        if captured then
            table.insert(captured, line)
        end
        vim.schedule(function()
            on_line(line)
        end)
    end
    return function(_err, data)
        if not data then
            if buffer ~= "" then
                emit(buffer)
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
            emit(line)
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

    local cmd = { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "commit", "-m", message }
    if description and description ~= "" then
        table.insert(cmd, "-m")
        table.insert(cmd, description)
    end

    log.info("commit_streaming:", table.concat(cmd, " "))

    local captured = {}

    vim.system(cmd, {
        cwd = git_root,
        stdout = line_buffered_handler(on_output, captured),
        stderr = line_buffered_handler(on_output, captured),
    }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                log.info("commit_streaming: success")
                callback(true, nil)
            else
                local error_output = vim.trim(table.concat(captured, "\n"))
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

    local captured = {}

    vim.system({ "git", "-c", "core.quotepath=false", "--literal-pathspecs", "commit", "--amend", "--no-edit" }, {
        cwd = git_root,
        stdout = line_buffered_handler(on_output, captured),
        stderr = line_buffered_handler(on_output, captured),
    }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                callback(true, nil)
            else
                local error_output = vim.trim(table.concat(captured, "\n"))
                log.error("amend_no_edit_streaming: failed:", error_output)
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

---Async: check if a file is untracked
---@param file string File path relative to git root
---@return boolean
function M.is_untracked_async(file)
    return with_git_root(false, function(git_root)
        local result = async.system(untracked_cmd(file), { text = true, cwd = git_root })

        return result.code == 0 and vim.trim(result.stdout) ~= ""
    end)
end

---Async: find the source path of a renamed or copied file
---@param git_root string
---@param file string New path
---@param base string Base to compare against
---@param staged boolean Whether to look in the index rather than the worktree
---@return string|nil
local function find_rename_source_async(git_root, file, base, staged)
    local cache_key = rename_cache_key(base, staged, git_root)
    local cached = rename_source_cache[cache_key]

    if not cached then
        local result = async.system(rename_source_cmd(staged, base), { text = true, cwd = git_root })
        if result.code ~= 0 then
            return nil
        end

        cached = parse_rename_sources(result.stdout)
        rename_source_cache[cache_key] = cached
    end

    return cached[file]
end

---Async: get set of staged files
---@return table<string, boolean>
function M.get_staged_files_async()
    return with_git_root({}, function(git_root)
        local result = async.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "--cached", "--name-only" },
            { text = true, cwd = git_root }
        )
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
        local result = async.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "--name-only" },
            { text = true, cwd = git_root }
        )
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
    if not M.is_safe_rev(base) or not M.is_safe_rev(base_end) then
        log.error("get_changed_files_async: refusing unsafe revision")
        return {}
    end

    return with_git_root({}, function(git_root)
        if base_end then
            local range_result = async.system({
                "git",
                "-c",
                "core.quotepath=false",
                "--literal-pathspecs",
                "diff",
                "-M",
                "--name-only",
                base .. "..." .. base_end,
            }, { text = true, cwd = git_root })

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
                return async.system(
                    { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", "--name-only", base },
                    { text = true, cwd = git_root }
                )
            end,
            function()
                return async.system({
                    "git",
                    "-c",
                    "core.quotepath=false",
                    "--literal-pathspecs",
                    "diff",
                    "-M",
                    "--cached",
                    "--name-only",
                }, { text = true, cwd = git_root })
            end,
            function()
                return async.system({
                    "git",
                    "-c",
                    "core.quotepath=false",
                    "--literal-pathspecs",
                    "ls-files",
                    "--others",
                    "--exclude-standard",
                }, { text = true, cwd = git_root })
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
    if not M.is_safe_rev(base) or not M.is_safe_rev(base_end) then
        log.error("get_all_file_statuses_async: refusing unsafe revision")
        return {}, {}
    end

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
        local range_result = async.system({
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "diff",
            "-M",
            "--name-status",
            base .. "..." .. base_end,
        }, { text = true, cwd = git_root })

        local statuses = {}
        local rename_map = {}

        if range_result.code == 0 then
            for line in parse_lines(range_result.stdout) do
                apply_name_status_line(line, statuses, rename_map)
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
            return async.system({
                "git",
                "-c",
                "core.quotepath=false",
                "--literal-pathspecs",
                "ls-files",
                "--others",
                "--exclude-standard",
            }, { text = true, cwd = git_root })
        end,
        function()
            return async.system(
                { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", "--name-status", base },
                { text = true, cwd = git_root }
            )
        end,
        function()
            return async.system({
                "git",
                "-c",
                "core.quotepath=false",
                "--literal-pathspecs",
                "diff",
                "-M",
                "--cached",
                "--name-status",
            }, { text = true, cwd = git_root })
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
            apply_name_status_line(line, statuses, rename_map, true)
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

---Async: added/deleted line counts for the given files, from one
---`git diff --numstat` call over the same range the file list was built from.
---Untracked files are counted from disk. Files git reports nothing for are
---left out of the result.
---@param files string[] List of file paths relative to git root
---@param base string|nil Base commit to compare against (default: HEAD)
---@param base_end string|nil End of commit range
---@return table<string, GitLineStats>
function M.get_line_stats_async(files, base, base_end)
    if not M.is_safe_rev(base) or not M.is_safe_rev(base_end) then
        log.error("get_line_stats_async: refusing unsafe revision")
        return {}
    end

    base = base or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return {}
    end

    local range = base_end and (base .. "..." .. base_end) or base
    local result = async.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", "--numstat", range },
        { text = true, cwd = git_root }
    )

    local stats = {}
    if result.code == 0 then
        for line in parse_lines(result.stdout) do
            local entry = M.parse_numstat_line(line)
            if entry then
                stats[entry.path] = { added = entry.added, deleted = entry.deleted }
            end
        end
    end

    -- Without a range end the file list also carries untracked files, which
    -- `git diff` cannot report on
    if not base_end then
        for _, file in ipairs(files) do
            if not stats[file] then
                stats[file] = untracked_line_stats(git_root, file)
            end
        end
    end

    return stats
end

---Async: get diff for a specific file
---@param file string File path relative to git root
---@param base string|nil Base commit to compare against
---@param base_end string|nil End of commit range
---@param opts GetDiffOpts|nil Optional parameters
---@return GitDiffResult
function M.get_diff_async(file, base, base_end, opts)
    base = base or "HEAD"
    if not M.is_safe_rev(base) or not M.is_safe_rev(base_end) then
        log.error("get_diff_async: refusing unsafe revision", base, base_end)
        return { success = false, output = "", error = "Invalid revision" }
    end

    local git_root = M.get_root()
    if not git_root then
        return { success = false, output = "", error = "Not in a git repository" }
    end

    if base_end then
        local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
        local cmd = {
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "diff",
            "-M",
            context_flag,
            base .. "..." .. base_end,
            "--",
            file,
        }
        local result = async.system(cmd, { text = true, cwd = git_root })

        if result.code ~= 0 then
            return { success = false, output = "", error = result.stderr }
        end

        return capped_diff_result(result.stdout)
    end

    local file_status = opts and opts.file_status or nil

    local is_untracked = file_status == "untracked" or (not file_status and M.is_untracked_async(file))
    if is_untracked then
        return untracked_diff(git_root, file)
    end

    local is_staged_only = base == "HEAD" and file_status == "staged_only"
    if base == "HEAD" and not file_status then
        local unstaged_result = async.system(
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "--name-only", "--", file },
            { text = true, cwd = git_root }
        )

        if unstaged_result.code == 0 and vim.trim(unstaged_result.stdout) == "" then
            local staged_result = async.system({
                "git",
                "-c",
                "core.quotepath=false",
                "--literal-pathspecs",
                "diff",
                "--cached",
                "--name-only",
                "--",
                file,
            }, { text = true, cwd = git_root })
            if staged_result.code == 0 and vim.trim(staged_result.stdout) ~= "" then
                is_staged_only = true
            end
        end
    end

    local context_flag = "-U" .. (require("review.state").state.diff_context or 3)
    local cmd
    if is_staged_only then
        cmd = {
            "git",
            "-c",
            "core.quotepath=false",
            "--literal-pathspecs",
            "diff",
            "-M",
            context_flag,
            "--cached",
            "--",
            file,
        }
    else
        cmd =
            { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "diff", "-M", context_flag, base, "--", file }
    end

    local result = async.system(cmd, { text = true, cwd = git_root })

    if result.code ~= 0 then
        return { success = false, output = "", error = result.stderr }
    end

    if result.stdout:match("\nnew file mode") then
        local rename_from = opts and opts.rename_from or find_rename_source_async(git_root, file, base, is_staged_only)
        if rename_from then
            table.insert(cmd, rename_from)
            local retry = async.system(cmd, { text = true, cwd = git_root })
            if retry.code == 0 and retry.stdout ~= "" then
                return capped_diff_result(retry.stdout)
            end
        end
    end

    return capped_diff_result(result.stdout)
end

---Async: get file content at a specific revision
---@param file string File path relative to git root
---@param rev string|nil Git revision (default: HEAD)
---@return string|nil content, string|nil error
function M.get_file_at_rev_async(file, rev)
    if not M.is_safe_rev(rev) then
        log.error("get_file_at_rev_async: refusing unsafe revision")
        return nil
    end

    rev = rev or "HEAD"
    local git_root = M.get_root()
    if not git_root then
        return nil, "Not in a git repository"
    end

    local result = async.system(
        { "git", "-c", "core.quotepath=false", "--literal-pathspecs", "show", rev .. ":" .. file },
        { text = true, cwd = git_root }
    )

    if result.code ~= 0 then
        return nil, result.stderr
    end

    return result.stdout, nil
end

return M
