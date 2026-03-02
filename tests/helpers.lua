local M = {}

M.SIMPLE_DIFF = table.concat({
    "diff --git a/file.lua b/file.lua",
    "index abc1234..def5678 100644",
    "--- a/file.lua",
    "+++ b/file.lua",
    "@@ -1,3 +1,4 @@",
    " local M = {}",
    "-local old = true",
    "+local new = true",
    "+local extra = false",
    " return M",
}, "\n")

M.MULTI_HUNK_DIFF = table.concat({
    "--- a/app.ts",
    "+++ b/app.ts",
    "@@ -1,3 +1,3 @@",
    " import React from 'react'",
    "-const old = 1",
    "+const updated = 1",
    " export default old",
    "@@ -10,3 +10,4 @@",
    " function render() {",
    "+  console.log('debug')",
    "   return null",
    " }",
}, "\n")

M.ADD_ONLY_DIFF = table.concat({
    "--- /dev/null",
    "+++ b/new_file.lua",
    "@@ -0,0 +1,3 @@",
    "+local M = {}",
    "+M.value = 42",
    "+return M",
}, "\n")

M.DELETE_ONLY_DIFF = table.concat({
    "--- a/old_file.lua",
    "+++ /dev/null",
    "@@ -1,3 +0,0 @@",
    "-local M = {}",
    "-M.value = 42",
    "-return M",
}, "\n")

M.NO_COUNT_HEADER_DIFF = table.concat({
    "--- a/single.lua",
    "+++ b/single.lua",
    "@@ -5 +5 @@",
    "-old_line",
    "+new_line",
}, "\n")

M.MIXED_DIFF = table.concat({
    "--- a/mixed.ts",
    "+++ b/mixed.ts",
    "@@ -1,7 +1,8 @@",
    " const a = 1",
    "-const b = 2",
    "-const c = 3",
    "+const b = 20",
    "+const c = 30",
    "+const d = 40",
    " const e = 5",
    " const f = 6",
}, "\n")

function M.make_comment(overrides)
    local defaults = {
        id = "comment_1",
        file = "src/main.lua",
        line = 5,
        original_line = nil,
        type = "note",
        text = "Test comment",
        created_at = 1000000,
    }

    return vim.tbl_deep_extend("force", defaults, overrides or {})
end

function M.make_quick_comment(overrides)
    local defaults = {
        id = "qc_1000_1",
        file = "/project/src/main.lua",
        line = 10,
        type = "note",
        text = "Quick test comment",
        created_at = 1000000,
        context = nil,
    }

    return vim.tbl_deep_extend("force", defaults, overrides or {})
end

function M.make_render_line(overrides)
    local defaults = {
        type = "context",
        content = "some code",
        raw = " some code",
        old_line = 1,
        new_line = 1,
    }

    return vim.tbl_deep_extend("force", defaults, overrides or {})
end

function M.capture_notifications()
    local captured = {}
    local original_notify = vim.notify

    vim.notify = function(message, level, options)
        table.insert(captured, { message = message, level = level, options = options })
    end

    local function restore()
        vim.notify = original_notify
    end

    return captured, restore
end

return M
