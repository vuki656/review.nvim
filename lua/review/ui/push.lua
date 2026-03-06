local git = require("review.core.git")
local state = require("review.state")
local ui_util = require("review.ui.util")

local M = {}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@param label string
---@return { close: fun() }
local function create_spinner(label)
    local popup_width = #label + 6
    local popup_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[popup_buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, {
        " " .. SPINNER_FRAMES[1] .. " " .. label,
    })

    local popup_win = vim.api.nvim_open_win(popup_buf, false, {
        relative = "editor",
        row = math.floor(vim.o.lines / 2),
        col = math.floor((vim.o.columns - popup_width) / 2),
        width = popup_width,
        height = 1,
        style = "minimal",
        border = "rounded",
    })

    local frame = 0
    local timer = vim.uv.new_timer()
    timer:start(0, 80, vim.schedule_wrap(function()
        if not vim.api.nvim_buf_is_valid(popup_buf) then
            timer:stop()
            timer:close()
            return
        end
        frame = (frame % #SPINNER_FRAMES) + 1
        vim.api.nvim_buf_set_lines(popup_buf, 0, 1, false, {
            " " .. SPINNER_FRAMES[frame] .. " " .. label,
        })
    end))

    return {
        close = function()
            timer:stop()
            timer:close()
            if vim.api.nvim_win_is_valid(popup_win) then
                vim.api.nvim_win_close(popup_win, true)
            end
            if vim.api.nvim_buf_is_valid(popup_buf) then
                vim.api.nvim_buf_delete(popup_buf, { force = true })
            end
        end,
    }
end

---Check if push error is a rejection (diverged history)
---@param err string
---@return boolean
local function is_push_rejected(err)
    return err:find("rejected") ~= nil
        or err:find("non%-fast%-forward") ~= nil
        or err:find("fetch first") ~= nil
end

---Push to remote with a small centered spinner popup
---@param force? boolean
function M.push(force)
    if state.state.is_pushing then
        vim.notify("Already pushing...", vim.log.levels.WARN)
        return
    end

    if state.is_history_mode() then
        vim.notify("Cannot push in history mode", vim.log.levels.WARN)
        return
    end

    state.state.is_pushing = true
    local label = force and "Force pushing..." or "Pushing..."
    local spinner = create_spinner(label)

    git.push(function(success, err)
        spinner.close()
        state.state.is_pushing = false

        if success then
            vim.notify("Pushed successfully", vim.log.levels.INFO)
            local commit_list = require("review.ui.commit_list")
            commit_list.refresh()
            local file_tree = require("review.ui.file_tree")
            file_tree.update_footer()
        elseif not force and err and is_push_rejected(err) then
            ui_util.confirm("Push rejected (diverged). Force push with --force-with-lease?", function()
                M.push(true)
            end)
        else
            vim.notify("Push failed: " .. (err or "unknown error"), vim.log.levels.ERROR)
        end
    end, force)
end

return M
