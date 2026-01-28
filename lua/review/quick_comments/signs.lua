local qc_state = require("review.quick_comments.state")

local M = {}

local SIGN_GROUP = "ReviewQuickComments"
local SIGN_NAME = "ReviewQuickComment"

---Set up sign definitions
function M.setup()
    vim.fn.sign_define(SIGN_NAME, {
        text = "󰆉",
        texthl = "ReviewCommentNote",
    })
end

---Update signs for a buffer
---@param bufnr number
function M.update(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    -- Clear existing signs
    vim.fn.sign_unplace(SIGN_GROUP, { buffer = bufnr })

    -- Get the file path
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then
        return
    end

    -- Get comments for this file
    local comments = qc_state.get_for_file(file)

    -- Place signs
    for _, comment in ipairs(comments) do
        vim.fn.sign_place(0, SIGN_GROUP, SIGN_NAME, bufnr, {
            lnum = comment.line,
            priority = 10,
        })
    end
end

---Clear signs for a buffer
---@param bufnr number
function M.clear(bufnr)
    vim.fn.sign_unplace(SIGN_GROUP, { buffer = bufnr })
end

---Update signs for all buffers with the given file
---@param file string
function M.update_file(file)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local buf_file = vim.api.nvim_buf_get_name(bufnr)
            if buf_file == file then
                M.update(bufnr)
            end
        end
    end
end

---Set up autocmd to refresh signs on BufEnter
function M.setup_autocmd()
    vim.api.nvim_create_autocmd("BufEnter", {
        group = vim.api.nvim_create_augroup("ReviewQuickCommentsSigns", { clear = true }),
        callback = function(args)
            M.update(args.buf)
        end,
    })
end

return M
