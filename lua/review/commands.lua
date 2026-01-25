local M = {}

---Set up user commands
function M.setup()
    vim.api.nvim_create_user_command("Review", function(opts)
        local args = opts.fargs
        local subcommand = args[1]

        local ui = require("review.ui")
        local state = require("review.state")
        local export = require("review.export.markdown")

        if not subcommand or subcommand == "" then
            -- Toggle review UI
            ui.toggle()
        elseif subcommand == "close" then
            ui.close()
        elseif subcommand == "export" then
            export.to_clipboard()
        elseif subcommand == "send" then
            local target = args[2] -- Optional custom target
            export.to_tmux(target)
        elseif subcommand == "commit" then
            local sha = args[2]
            if sha then
                state.state.base = sha
                vim.notify("Comparing against: " .. sha, vim.log.levels.INFO)
                -- Refresh if UI is open
                if ui.is_open() then
                    ui.close()
                    ui.open()
                end
            else
                vim.notify("Usage: :Review commit <sha>", vim.log.levels.WARN)
            end
        else
            vim.notify("Unknown subcommand: " .. subcommand, vim.log.levels.ERROR)
        end
    end, {
        nargs = "*",
        complete = function(_, cmdline, _)
            local args = vim.split(cmdline, "%s+")
            if #args == 2 then
                return { "close", "export", "send", "commit" }
            end
            return {}
        end,
        desc = "Review AI-generated code changes",
    })
end

return M
