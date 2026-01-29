local M = {}

---Define all highlight groups for the plugin
function M.setup()
    local highlights = {
        -- Diff line backgrounds
        ReviewDiffAdd = { bg = "#002800" },
        ReviewDiffDelete = { bg = "#3f0001" },

        -- Inline diff (actual changed parts)
        ReviewDiffAddInline = { bg = "#004000" },
        ReviewDiffDeleteInline = { bg = "#600010" },

        -- Diff sign column (fat colored border)
        ReviewDiffSignAdd = { fg = "#89ca78", bold = true },
        ReviewDiffSignDelete = { fg = "#ef596f", bold = true },
        ReviewDiffSignContext = { fg = "#3e4452" },

        -- Legacy (keep for compatibility)
        ReviewDiffChange = { fg = "#a8c8e8", bg = "#2a2a3a" },
        ReviewDiffText = { fg = "#e5c07b", bg = "#3e4452", bold = true },
        ReviewDiffHeader = { fg = "#c678dd", bg = "#2c2033", bold = true },
        ReviewDiffHunkHeader = { fg = "#61afef", bg = "#1e2a3a", italic = true },

        -- Comment type colors
        ReviewCommentNote = { fg = "#61afef", bold = true },
        ReviewCommentFix = { fg = "#ef596f", bold = true },
        ReviewCommentQuestion = { fg = "#e5c07b", bold = true },
        ReviewCommentBorder = { fg = "#5c6370" },
        ReviewCommentText = { fg = "#abb2bf" },

        -- File tree
        ReviewFileReviewed = { fg = "#89ca78" },
        ReviewFileModified = { fg = "#d19a66" },
        ReviewFilePending = { fg = "#abb2bf" },
        ReviewFilePath = { fg = "#abb2bf" },
        ReviewFilePathFaded = { fg = "#5c6370" },
        ReviewFileFaded = { fg = "#4b5263" },
        ReviewTreeDirectory = { fg = "#e5e5e5" },
        ReviewTreeIndent = { fg = "#3e4452" },
        ReviewLogo = { fg = "#61afef", bold = true },

        -- Comment input
        ReviewInputBorder = { fg = "#e5e5e5" },
        ReviewInputTitle = { fg = "#e5e5e5", bold = true },
        ReviewInputFooter = { fg = "#5c6370" },

        -- Comment input per-type colors (border + title)
        ReviewInputBorderFix = { fg = "#ef596f" },
        ReviewInputTitleFix = { fg = "#ef596f", bold = true },
        ReviewInputBorderNote = { fg = "#61afef" },
        ReviewInputTitleNote = { fg = "#61afef", bold = true },
        ReviewInputBorderQuestion = { fg = "#e5c07b" },
        ReviewInputTitleQuestion = { fg = "#e5c07b", bold = true },

        -- Git status icons in file tree
        ReviewGitAdded = { fg = "#89ca78" },
        ReviewGitModified = { fg = "#d19a66" },
        ReviewGitDeleted = { fg = "#ef596f" },
        ReviewGitRenamed = { fg = "#c678dd" },

        -- UI elements
        ReviewBorder = { fg = "#3e4452" },
        ReviewTitle = { fg = "#61afef", bold = true },
        ReviewSelected = { bg = "#3e4452" },

        -- Line numbers in diff
        ReviewLineNrAdd = { fg = "#89ca78" },
        ReviewLineNrDelete = { fg = "#ef596f" },
        ReviewLineNrContext = { fg = "#5c6370" },

        -- Footer
        ReviewFooterText = { fg = "#5c6370" },
        ReviewFooterCount = { fg = "#61afef" },

        -- Quick Comments Panel
        ReviewQCPanelHeader = { fg = "#61afef", bold = true },
        ReviewQCPanelBorder = { fg = "#3e4452" },
        ReviewQCPanelFile = { fg = "#abb2bf", bold = true },
        ReviewQCPanelContext = { fg = "#5c6370", italic = true },
        ReviewQCPanelLineNr = { fg = "#5c6370" },
    }

    for name, opts in pairs(highlights) do
        vim.api.nvim_set_hl(0, name, opts)
    end
end

return M
