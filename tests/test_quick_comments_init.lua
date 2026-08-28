local new_set = MiniTest.new_set
local expect = MiniTest.expect

local config = require("review.config")
local helpers = require("tests.helpers")
local qc = require("review.quick_comments")
local qc_panel = require("review.quick_comments.panel")
local qc_persistence = require("review.quick_comments.persistence")
local qc_state = require("review.quick_comments.state")
local review = require("review")

local QC_SESSION_PATH = vim.fn.tempname() .. "-qc.json"
local original_get_path = qc_persistence.get_path

local T = new_set({
    hooks = {
        pre_case = function()
            qc_persistence.get_path = function()
                return QC_SESSION_PATH
            end
            os.remove(QC_SESSION_PATH)
            config.setup()
            qc_state.clear()
        end,
        post_case = function()
            os.remove(QC_SESSION_PATH)
            qc_persistence.get_path = original_get_path
            qc_state.clear()
            pcall(vim.keymap.del, "n", "<leader>qs")
            if qc_panel.is_open() then
                qc_panel.close()
            end
        end,
    },
})

T["send warns when there are no comments"] = function()
    local captured, restore = helpers.capture_notifications()
    local ok, result = pcall(qc.send)
    restore()

    if not ok then
        error(result)
    end

    expect.equality(result, false)
    expect.equality(#captured, 1)
    expect.equality(captured[1].message, "No quick comments to send")
    expect.equality(captured[1].level, vim.log.levels.WARN)
end

T["send silent suppresses warning when no comments"] = function()
    local captured, restore = helpers.capture_notifications()
    local ok, result = pcall(qc.send, nil, { silent = true })
    restore()

    if not ok then
        error(result)
    end

    expect.equality(result, false)
    expect.equality(#captured, 0)
end

T["send executes on_export handler with markdown and comment list"] = function()
    local called = false
    local captured_content = nil
    local captured_comments = nil

    config.setup({
        export = {
            on_export = function(content, comments)
                called = true
                captured_content = content
                captured_comments = comments
                return true
            end,
        },
    })

    qc_state.add("/project/src/main.lua", 10, "note", "Test comment")

    local ok, result = pcall(qc.send, nil, { silent = true })
    if not ok then
        error(result)
    end

    expect.equality(result, true)
    expect.equality(called, true)
    expect.equality(captured_content:find("# Quick Comments") ~= nil, true)
    expect.equality(captured_content:find("Test comment") ~= nil, true)
    expect.equality(#captured_comments, 1)
end

T["send reports failure when on_export returns false"] = function()
    config.setup({
        export = {
            on_export = function()
                return false
            end,
        },
    })

    qc_state.add("/project/src/main.lua", 5, "note", "Note test")

    local ok, result = pcall(qc.send, nil, { silent = true })
    if not ok then
        error(result)
    end

    expect.equality(result, false)
end

T["send reports failure when on_export errors"] = function()
    config.setup({
        export = {
            on_export = function()
                error("delivery error")
            end,
        },
    })

    qc_state.add("/project/src/main.lua", 5, "note", "Note test")

    local ok, result = pcall(qc.send, nil, { silent = true })
    if not ok then
        error(result)
    end

    expect.equality(result, false)
end

T["send with clear=true clears state, saves persistence, and closes panel on success"] = function()
    config.setup({
        export = {
            on_export = function()
                return true
            end,
        },
    })

    qc_state.add("/project/src/main.lua", 10, "note", "Comment to clear")
    qc_panel.open()
    expect.equality(qc_panel.is_open(), true)

    local ok, result = pcall(qc.send, nil, { clear = true, silent = true })
    if not ok then
        error(result)
    end

    expect.equality(result, true)
    expect.equality(qc_state.count(), 0)
    expect.equality(qc_panel.is_open(), false)
end

T["send with clear=true retains comments if delivery fails"] = function()
    config.setup({
        export = {
            on_export = function()
                return false
            end,
        },
    })

    qc_state.add("/project/src/main.lua", 10, "note", "Comment to preserve")

    local ok, result = pcall(qc.send, nil, { clear = true, silent = true })
    if not ok then
        error(result)
    end

    expect.equality(result, false)
    expect.equality(qc_state.count(), 1)
end

T["send with clear=true retains comments if tmux delivery fails"] = function()
    config.setup({
        export = {
            on_export = nil,
        },
    })

    qc_state.add("/project/src/main.lua", 10, "note", "Tmux comment to preserve")

    local export = require("review.export.markdown")
    local original_send_to_default = export.send_to_default
    export.send_to_default = function(_, _, _, _, on_done)
        if on_done then
            on_done(false)
        end
        return false
    end

    local ok, result = pcall(qc.send, "invalid:pane", { clear = true, silent = true })
    export.send_to_default = original_send_to_default

    if not ok then
        error(result)
    end

    expect.equality(result, false)
    expect.equality(qc_state.count(), 1)
end

T["send with clear=true clears comments when tmux delivery succeeds"] = function()
    config.setup({
        export = {
            on_export = nil,
        },
    })

    qc_state.add("/project/src/main.lua", 10, "note", "Tmux comment to clear")
    qc_panel.open()
    expect.equality(qc_panel.is_open(), true)

    local export = require("review.export.markdown")
    local original_send_to_default = export.send_to_default
    export.send_to_default = function(_, _, _, _, on_done)
        if on_done then
            on_done(true)
        end
        return true
    end

    local ok, result = pcall(qc.send, "valid:pane", { clear = true, silent = true })
    export.send_to_default = original_send_to_default

    if not ok then
        error(result)
    end

    expect.equality(result, true)
    expect.equality(qc_state.count(), 0)
    expect.equality(qc_panel.is_open(), false)
end

T["send passes content, count, target, and silent to export.send_to_default when on_export is nil"] = function()
    config.setup({
        export = {
            on_export = nil,
        },
    })

    qc_state.add("/project/src/main.lua", 10, "note", "Tmux fallback comment")

    local export = require("review.export.markdown")
    local original_send_to_default = export.send_to_default
    local captured = {}

    export.send_to_default = function(content, comment_count, target, silent, on_done)
        captured.content = content
        captured.comment_count = comment_count
        captured.target = target
        captured.silent = silent
        captured.on_done = on_done
        return true
    end

    local ok, result = pcall(qc.send, "CLAUDE.0", { silent = true })
    export.send_to_default = original_send_to_default

    if not ok then
        error(result)
    end

    expect.equality(result, true)
    expect.equality(captured.content:find("# Quick Comments") ~= nil, true)
    expect.equality(captured.content:find("Tmux fallback comment") ~= nil, true)
    expect.equality(captured.comment_count, 1)
    expect.equality(captured.target, "CLAUDE.0")
    expect.equality(captured.silent, true)
    expect.equality(type(captured.on_done), "function")
end

T[":Review qs <target> passes target argument to send_to_default"] = function()
    config.setup({
        export = {
            on_export = nil,
        },
    })

    qc_state.add("/project/src/main.lua", 1, "note", "Target test")

    local export = require("review.export.markdown")
    local original_send_to_default = export.send_to_default
    local captured_target = nil

    export.send_to_default = function(_, _, target)
        captured_target = target
        return true
    end

    local ok, err = pcall(vim.cmd, "Review qs agent_pane")
    export.send_to_default = original_send_to_default

    if not ok then
        error(err)
    end

    expect.equality(captured_target, "agent_pane")
end

T["review.quick_send delegates to quick_comments.send"] = function()
    local called = false
    config.setup({
        export = {
            on_export = function()
                called = true
                return true
            end,
        },
    })

    qc_state.add("/project/src/main.lua", 1, "note", "Top level test")

    local ok, result = pcall(review.quick_send, nil, { silent = true })
    if not ok then
        error(result)
    end

    expect.equality(result, true)
    expect.equality(called, true)
end

T[":Review qs command dispatches to quick_comments.send"] = function()
    local called = false
    local opts = {
        export = {
            on_export = function()
                called = true
                return true
            end,
        },
    }

    qc_state.add("/project/src/main.lua", 1, "note", "Command test")

    config.setup(opts)
    vim.cmd("Review qs")

    expect.equality(called, true)
end

T["panel 's' keymap calls quick_comments.send"] = function()
    local called = false
    config.setup({
        export = {
            on_export = function()
                called = true
                return true
            end,
        },
    })

    qc_state.add("/project/src/main.lua", 1, "note", "Panel send test")
    qc_panel.open()

    local bufnr = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if
            vim.api.nvim_buf_is_loaded(b)
            and vim.api.nvim_get_option_value("filetype", { buf = b }) == "review-quick-comments"
        then
            bufnr = b
            break
        end
    end

    expect.equality(bufnr ~= nil, true)
    local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
    local s_map = nil
    for _, map in ipairs(keymaps) do
        if map.lhs == "s" then
            s_map = map
            break
        end
    end

    expect.equality(s_map ~= nil, true)
    if s_map and s_map.callback then
        s_map.callback()
        expect.equality(called, true)
    end
end

T["quick_comments.keymaps.send registers global keymap"] = function()
    local called = false
    config.setup({
        export = {
            on_export = function()
                called = true
                return true
            end,
        },
        quick_comments = {
            keymaps = {
                send = "<leader>qs",
            },
        },
    })

    qc_state.add("/project/src/main.lua", 1, "note", "Keymap test")
    qc.setup()

    local found = vim.fn.maparg("<leader>qs", "n", false, true)
    expect.equality(found.desc, "Send quick comments")
    if found.callback then
        found.callback()
    end
    expect.equality(called, true)

    pcall(vim.keymap.del, "n", "<leader>qs")
end

return T
