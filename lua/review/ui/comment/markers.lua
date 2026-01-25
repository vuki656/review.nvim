local state = require("review.state")
local types = require("review.ui.comment.types")

local M = {}

---Namespace for comment extmarks
local ns_id = vim.api.nvim_create_namespace("review_comments")

---Render comment markers in the buffer
---@param bufnr number
---@param file string
function M.render(bufnr, file)
    -- Clear existing markers
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

    -- Get comments for this file
    local comments = state.get_comments_for_file(file)

    for _, comment in ipairs(comments) do
        local type_info = types.get(comment.type)
        if type_info then
            -- Create virtual text
            local virt_text = types.format(comment.type, comment.text, 50)

            -- Add extmark with virtual text
            pcall(function()
                vim.api.nvim_buf_set_extmark(bufnr, ns_id, comment.line - 1, 0, {
                    virt_text = { { "  " .. virt_text, type_info.highlight } },
                    virt_text_pos = "eol",
                    hl_mode = "combine",
                })

                -- Add sign/indicator in the sign column
                vim.api.nvim_buf_set_extmark(bufnr, ns_id, comment.line - 1, 0, {
                    sign_text = type_info.icon,
                    sign_hl_group = type_info.highlight,
                })
            end)
        end
    end
end

---Clear all markers in a buffer
---@param bufnr number
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
end

---Get the namespace id
---@return number
function M.get_namespace()
    return ns_id
end

return M
