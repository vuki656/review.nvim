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

-- The plugin is lazy-loaded - setup() must be called by the user
