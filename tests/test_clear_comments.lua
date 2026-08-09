local new_set = MiniTest.new_set
local expect = MiniTest.expect

local state = require("review.state")
local ui = require("review.ui")
local ui_util = require("review.ui.util")
local persistence = require("review.core.persistence")
local helpers = require("tests.helpers")

local T = new_set({
    hooks = {
        pre_case = function()
            state.reset()
        end,
        post_case = function()
            state.reset()
            local path = persistence.get_path()
            if path then
                os.remove(path)
            end
        end,
    },
})

local clear_tests = new_set()
T["clear_comments"] = clear_tests

clear_tests["notifies when count is 0 and UI is open"] = function()
    local captured, restore = helpers.capture_notifications()
    state.state.is_open = true

    local ok, count = pcall(ui.clear_comments)
    restore()
    if not ok then
        error(count)
    end

    expect.equality(count, 0)
    expect.equality(#captured, 1)
    expect.equality(captured[1].message, "No comments to clear")
end

clear_tests["notifies when count is 0, UI closed, and no session file exists"] = function()
    local path = persistence.get_path()
    if path then
        os.remove(path)
    end

    local captured, restore = helpers.capture_notifications()
    state.state.is_open = false

    local ok, count = pcall(ui.clear_comments)
    restore()
    if not ok then
        error(count)
    end

    expect.equality(count, 0)
    expect.equality(#captured, 1)
    expect.equality(captured[1].message, "No comments to clear")
end

clear_tests["deletes session file and notifies when count is 0, UI closed, and session file exists"] = function()
    local path = persistence.get_path()
    if not path then
        return
    end

    -- Create a fake session file
    local file = io.open(path, "w")
    file:write('{"version":1,"files":{}}')
    file:close()

    expect.equality(persistence.exists(), true)

    local captured, restore = helpers.capture_notifications()
    state.state.is_open = false

    local ok, count = pcall(ui.clear_comments)
    restore()
    if not ok then
        error(count)
    end

    expect.equality(count, 0)
    expect.equality(persistence.exists(), false)
    expect.equality(#captured, 1)
    expect.equality(captured[1].message, "Cleared saved review session")
end

clear_tests["prompts for confirmation and clears comments when count > 0"] = function()
    state.add_comment("file.lua", 1, "note", "comment 1")
    state.add_comment("file.lua", 2, "note", "comment 2")

    local captured_prompt = nil
    local orig_confirm = ui_util.confirm
    ui_util.confirm = function(prompt, on_confirm)
        captured_prompt = prompt
        on_confirm()
    end

    local captured, restore = helpers.capture_notifications()
    state.state.is_open = false

    local ok, count = pcall(ui.clear_comments)
    restore()
    ui_util.confirm = orig_confirm
    if not ok then
        error(count)
    end

    expect.equality(count, 2)
    expect.equality(captured_prompt, "Clear 2 comments?")
    expect.equality(#captured, 1)
    expect.equality(captured[1].message, "Cleared 2 comments")
    expect.equality(captured[1].level, vim.log.levels.INFO)
    expect.equality(#state.get_all_comments(), 0)
end

clear_tests["does not clear comments if confirmation is declined"] = function()
    state.add_comment("file.lua", 1, "note", "comment 1")

    local orig_confirm = ui_util.confirm
    ui_util.confirm = function(prompt, on_confirm)
        -- Do not call on_confirm (simulating "No" or Esc)
    end

    local ok, count = pcall(ui.clear_comments)
    ui_util.confirm = orig_confirm
    if not ok then
        error(count)
    end

    expect.equality(count, 0)
    expect.equality(#state.get_all_comments(), 1)
end

clear_tests["deletes file despite conflict guard when force_empty is true"] = function()
    local path = persistence.get_path()
    if not path then
        return
    end

    -- Load clean state first so loaded_path/loaded_mtime are initialized
    persistence.load()

    -- Simulate another process writing to the file (updating mtime)
    os.execute("sleep 1")
    local file = io.open(path, "w")
    file:write('{"version":1,"files":{}}')
    file:close()

    state.add_comment("file.lua", 1, "note", "comment 1")
    state.clear_all_comments()

    -- Call save with force_empty = true
    local save_ok = persistence.save({ force_empty = true })
    expect.equality(save_ok, true)
    expect.equality(persistence.exists(), false)
end

clear_tests["retains file when conflicted and force_empty is false"] = function()
    local path = persistence.get_path()
    if not path then
        return
    end

    persistence.load()

    os.execute("sleep 1")
    local file = io.open(path, "w")
    file:write('{"version":1,"files":{}}')
    file:close()

    state.add_comment("file.lua", 1, "note", "comment 1")
    state.clear_all_comments()

    -- Call save without force_empty (regular save)
    local save_ok = persistence.save()
    expect.equality(save_ok, true)
    expect.equality(persistence.exists(), true)
end

clear_tests["shows warning when save returns false"] = function()
    state.add_comment("file.lua", 1, "note", "comment 1")

    local orig_confirm = ui_util.confirm
    ui_util.confirm = function(prompt, on_confirm)
        on_confirm()
    end

    -- Mock persistence.save to simulate save failure
    local original_save = persistence.save
    persistence.save = function()
        return false
    end

    local captured, restore = helpers.capture_notifications()
    local ok, count = pcall(ui.clear_comments)
    restore()
    persistence.save = original_save
    ui_util.confirm = orig_confirm
    if not ok then
        error(count)
    end

    expect.equality(count, 1)
    expect.equality(#captured, 1)
    expect.equality(captured[1].message, "Failed to clear saved review session")
    expect.equality(captured[1].level, vim.log.levels.WARN)
end

return T
