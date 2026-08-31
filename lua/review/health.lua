local M = {}

local VALID_LOG_LEVELS = { "DEBUG", "INFO", "WARN", "ERROR" }

local function check_neovim_version()
    local version = vim.version()
    local version_string = string.format("%d.%d.%d", version.major, version.minor, version.patch)

    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim " .. version_string .. " (>= 0.10 required)")
    else
        vim.health.error("Neovim " .. version_string .. " is too old", { "Upgrade to Neovim 0.10 or later" })
    end
end

local function check_git()
    if vim.fn.executable("git") ~= 1 then
        vim.health.error("`git` not found in PATH", { "Install git, it is required for all diff operations" })
        return
    end

    local version = vim.trim(vim.fn.system({ "git", "--version" }))
    if vim.v.shell_error ~= 0 then
        vim.health.error("`git --version` failed: " .. version)
        return
    end

    vim.health.ok("`git` found: " .. version)

    local inside = vim.trim(vim.fn.system({ "git", "rev-parse", "--is-inside-work-tree" }))
    if vim.v.shell_error ~= 0 or inside ~= "true" then
        vim.health.warn("Current directory is not inside a git repository", {
            "`:Review` only works from within a git repository",
        })
        return
    end

    local root = vim.trim(vim.fn.system({ "git", "rev-parse", "--show-toplevel" }))
    vim.health.ok("Inside a git repository: " .. root)
end

local function check_tmux()
    if vim.fn.executable("tmux") ~= 1 then
        if vim.env.HERDR_PANE_ID then
            vim.health.ok("`tmux` not found in PATH, herdr is used for sending")
        else
            vim.health.warn("`tmux` not found in PATH", {
                "Optional, only required for `:Review send` and `:Review qs`",
            })
        end
        return
    end

    vim.health.ok("`tmux` found: " .. vim.trim(vim.fn.system({ "tmux", "-V" })))

    if vim.env.TMUX then
        vim.health.ok("Running inside a tmux session")
    else
        vim.health.warn("Not running inside a tmux session ($TMUX is unset)", {
            "`:Review send` and `:Review qs` require Neovim to run inside tmux or herdr",
        })
    end
end

local function check_herdr()
    if not vim.env.HERDR_PANE_ID then
        if vim.fn.executable("herdr") == 1 then
            vim.health.ok("herdr found, not running inside a herdr session ($HERDR_PANE_ID is unset)")
        end
        return
    end

    if vim.fn.executable("herdr") ~= 1 then
        vim.health.warn("Running inside herdr but `herdr` not found in PATH", {
            "Required for `:Review send` and `:Review qs`",
        })
        return
    end

    vim.health.ok("Running inside a herdr session (pane " .. vim.env.HERDR_PANE_ID .. ")")
end

local function check_setup()
    local ok, config = pcall(require, "review.config")
    if not ok then
        vim.health.error("Failed to load `review.config`: " .. tostring(config))
        return
    end

    local options = config.get()
    if not config.did_setup then
        vim.health.warn("`require('review').setup()` has not been called", {
            "Defaults are in effect until setup() runs",
            "Add `require('review').setup({})` to your config to customize",
        })
    else
        vim.health.ok("`require('review').setup()` has been called")
    end

    local level = options.log_level
    if type(level) == "string" and vim.tbl_contains(VALID_LOG_LEVELS, level:upper()) then
        vim.health.ok("Log level: " .. level:upper())
    else
        vim.health.error("Invalid log level: " .. vim.inspect(level), {
            "Valid values: " .. table.concat(VALID_LOG_LEVELS, ", "),
        })
    end
end

local function check_log_file()
    local ok, log = pcall(require, "review.core.log")
    if not ok then
        vim.health.error("Failed to load `review.core.log`: " .. tostring(log))
        return
    end

    local path = log.get_log_path()
    if vim.fn.filereadable(path) == 1 then
        vim.health.ok("Log file: " .. path)
    else
        vim.health.info("Log file (not created yet): " .. path)
    end
end

function M.check()
    vim.health.start("review.nvim")
    check_neovim_version()
    check_git()
    check_tmux()
    check_herdr()
    check_setup()
    check_log_file()
end

return M
