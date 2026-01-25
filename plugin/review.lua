-- Prevent loading twice
if vim.g.loaded_review then
    return
end
vim.g.loaded_review = true

-- Check Neovim version
if vim.fn.has("nvim-0.10") ~= 1 then
    vim.notify("review.nvim requires Neovim 0.10 or later", vim.log.levels.ERROR)
    return
end

-- Check for nui.nvim dependency
local has_nui, _ = pcall(require, "nui.popup")
if not has_nui then
    vim.notify("review.nvim requires nui.nvim (MunifTanjim/nui.nvim)", vim.log.levels.ERROR)
    return
end

-- The plugin is lazy-loaded - setup() must be called by the user
