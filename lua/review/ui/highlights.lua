local M = {}

---Define all highlight groups for the plugin
function M.setup()
    local highlights = {
        -- Diff colors (OneDark-compatible)
        ReviewDiffAdd = { fg = "#89ca78", bg = "#3C4048" },
        ReviewDiffDelete = { fg = "#ef596f", bg = "#3C4048" },
        ReviewDiffChange = { fg = "#61afef", bg = "#3C4048" },
        ReviewDiffText = { fg = "#e5c07b", bg = "#3e4452", bold = true },
        ReviewDiffHeader = { fg = "#c678dd", bold = true },

        -- Comment type colors
        ReviewCommentNote = { fg = "#61afef" },
        ReviewCommentFix = { fg = "#ef596f", bold = true },
        ReviewCommentQuestion = { fg = "#e5c07b" },

        -- File tree
        ReviewFileReviewed = { fg = "#89ca78" },
        ReviewFileModified = { fg = "#d19a66" },
        ReviewFilePending = { fg = "#abb2bf" },
        ReviewTreeDirectory = { fg = "#c678dd", bold = true },

        -- UI elements
        ReviewBorder = { fg = "#3e4452" },
        ReviewTitle = { fg = "#61afef", bold = true },
        ReviewSelected = { bg = "#3e4452" },

        -- Line numbers in diff
        ReviewLineNrAdd = { fg = "#89ca78" },
        ReviewLineNrDelete = { fg = "#ef596f" },
        ReviewLineNrContext = { fg = "#5c6370" },
    }

    for name, opts in pairs(highlights) do
        vim.api.nvim_set_hl(0, name, opts)
    end
end

return M
