local new_set = MiniTest.new_set
local expect = MiniTest.expect

local config = require("review.config")
local helpers = require("tests.helpers")
local qc = require("review.quick_comments")
local qc_panel = require("review.quick_comments.panel")
local qc_state = require("review.quick_comments.state")
local review = require("review")

local T = new_set({
    hooks = {
        pre_case = function()
            config.setup()
            qc_state.clear()
        end,
        post_case = function()
            qc_state.clear()
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

T["send calls on_export with quick comments content and comments table"] = function()
    local captured_payload = {}
    config.setup({
        export = {
            on_export = function(content, comments)
                captured_payload.content = content
                captured_payload.comments = comments
                return true
            end,
        },
    })

    qc_state.add("/project/src/main.lua", 10, "fix", "Fix this bug", "local x = 1", 12)

    local captured_notify, restore_notify = helpers.capture_notifications()
    local ok, result = pcall(qc.send)
    restore_notify()

    if not ok then
        error(result)
    end

    expect.equality(result, true)
    expect.equality(captured_payload.content:find("# Quick Comments") ~= nil, true)
    expect.equality(captured_payload.content:find("Fix this bug") ~= nil, true)
    expect.equality(#captured_payload.comments, 1)
    expect.equality(captured_payload.comments[1].text, "Fix this bug")

    expect.equality(#captured_notify, 1)
    expect.equality(captured_notify[1].message, "Sent 1 quick comment(s)")
    expect.equality(captured_notify[1].level, vim.log.levels.INFO)
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

T["send with clear=true clears comments state and closes panel on success"] = function()
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

    review.setup(opts)
    vim.cmd("Review qs")

    expect.equality(called, true)
end

T[":Review qsend command alias also dispatches to quick_comments.send"] = function()
    local called = false
    local opts = {
        export = {
            on_export = function()
                called = true
                return true
            end,
        },
    }

    qc_state.add("/project/src/main.lua", 1, "note", "Alias test")

    review.setup(opts)
    vim.cmd("Review qsend")

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

    -- Find the 's' keymap in the panel buffer
    local bufnr = qc_panel.get_bufnr and qc_panel.get_bufnr() or vim.api.nvim_get_current_buf()
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

    local keymaps = vim.api.nvim_get_keymap("n")
    local found = nil
    for _, map in ipairs(keymaps) do
        if map.lhs == " <Space>qs" or map.lhs == "<leader>qs" or map.lhs:find("qs") then
            found = map
            break
        end
    end

    expect.equality(found ~= nil, true)
    if found and found.callback then
        found.callback()
        expect.equality(called, true)
    end
end

return T
