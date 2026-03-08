local palette = require("review.ui.palette")

local M = {}

function M.setup()
    local highlights = {
        ReviewDiffAdd = { bg = palette.diff_add },
        ReviewDiffDelete = { bg = palette.diff_delete },

        ReviewDiffAddInline = { bg = palette.diff_add_emphasis },
        ReviewDiffDeleteInline = { bg = palette.diff_delete_emphasis },

        ReviewDiffSignAdd = { fg = palette.positive, bold = true },
        ReviewDiffSignDelete = { fg = palette.negative, bold = true },
        ReviewDiffSignContext = { fg = palette.border },

        ReviewDiffFilePath = { fg = palette.text, bold = true },
        ReviewDiffFileHeaderBg = { bg = palette.header },
        ReviewDiffFileDivider = { fg = palette.text, bg = palette.header, bold = true },
        ReviewDiffFileDividerBorderTop = { fg = palette.border_accent },
        ReviewDiffFileDividerBorderBottom = { fg = palette.border_accent },

        ReviewDiffPadding = { bg = palette.padding },

        ReviewDiffChange = { fg = palette.text, bg = palette.surface },
        ReviewDiffText = { fg = palette.highlight, bg = palette.border, bold = true },
        ReviewDiffHeader = { fg = palette.special, bg = palette.tint, bold = true },
        ReviewDiffHunkHeader = { fg = palette.accent, bg = palette.header, italic = true },

        ReviewCommentNote = { fg = palette.accent, bold = true },
        ReviewCommentFix = { fg = palette.negative, bold = true },
        ReviewCommentQuestion = { fg = palette.highlight, bold = true },
        ReviewCommentBorder = { fg = palette.muted },
        ReviewCommentBorderFocusNote = { fg = palette.accent },
        ReviewCommentBorderFocusFix = { fg = palette.negative },
        ReviewCommentBorderFocusQuestion = { fg = palette.highlight },
        ReviewCommentText = { fg = palette.text },

        ReviewFileReviewed = { fg = palette.positive },
        ReviewFileModified = { fg = palette.caution },
        ReviewFilePending = { fg = palette.text },
        ReviewFilePath = { fg = palette.text },
        ReviewFilePathFaded = { fg = palette.muted },
        ReviewFileFaded = { fg = palette.faded },
        ReviewTreeDirectory = { fg = palette.text },
        ReviewTreeIndent = { fg = palette.border },
        ReviewLogo = { fg = palette.accent, bold = true },

        ReviewInputBorder = { fg = palette.text },
        ReviewInputTitle = { fg = palette.text, bold = true },
        ReviewInputFooter = { fg = palette.muted },

        ReviewInputBorderFix = { fg = palette.negative },
        ReviewInputTitleFix = { fg = palette.negative, bold = true },
        ReviewInputBorderNote = { fg = palette.accent },
        ReviewInputTitleNote = { fg = palette.accent, bold = true },
        ReviewInputBorderQuestion = { fg = palette.highlight },
        ReviewInputTitleQuestion = { fg = palette.highlight, bold = true },

        ReviewGitAdded = { fg = palette.positive },
        ReviewGitModified = { fg = palette.caution },
        ReviewGitDeleted = { fg = palette.negative },
        ReviewGitRenamed = { fg = palette.special },

        ReviewBranchAhead = { fg = palette.caution },
        ReviewBranchBehind = { fg = palette.caution },
        ReviewBranchSpinner = { fg = palette.caution, bg = palette.selected },

        ReviewFloatBorder = { fg = palette.text },
        ReviewFloatBorderActive = { fg = palette.positive },
        ReviewFloatTitle = { fg = palette.text, bold = true },
        ReviewFloatTitleActive = { fg = palette.positive, bold = true },

        ReviewWinSeparator = { fg = palette.muted },
        ReviewBorder = { fg = palette.border },
        ReviewTitle = { fg = palette.accent, bold = true },
        ReviewWinBar = { fg = palette.text, bold = true, bg = "NONE" },
        ReviewWinBarCount = { fg = palette.faded, bg = "NONE" },
        ReviewSelected = { bg = palette.selected },
        ReviewHelpGroup = { fg = palette.text, bg = palette.surface, bold = true },
        ReviewHelpKey = { fg = palette.highlight },

        ReviewLineNrAdd = { fg = palette.positive },
        ReviewLineNrDelete = { fg = palette.negative },
        ReviewLineNrContext = { fg = palette.muted },

        ReviewFooterText = { fg = palette.muted },
        ReviewFooterCount = { fg = palette.accent },

        ReviewQCPanelHeader = { fg = palette.accent, bold = true },
        ReviewQCPanelBorder = { fg = palette.border },
        ReviewQCPanelFile = { fg = palette.text, bold = true },
        ReviewQCPanelContext = { fg = palette.muted, italic = true },
        ReviewQCPanelLineNr = { fg = palette.muted },

        ReviewCommentListFile = { fg = palette.text },
        ReviewCommentListEmpty = { fg = palette.muted, italic = true },

        ReviewTemplateKey = { fg = palette.highlight, bold = true },
        ReviewTemplateLabel = { fg = palette.text },
        ReviewTemplateBorder = { fg = palette.muted },
        ReviewTemplateTitle = { fg = palette.accent, bold = true },

        ReviewActiveRow = { bg = palette.surface },
        ReviewDiffCursorLine = { bg = palette.cursor_line },

        ReviewCommitHash = { fg = palette.highlight },
        ReviewCommitAuthor = { fg = palette.accent },
        ReviewCommitAuthor1 = { fg = palette.author1 },
        ReviewCommitAuthor2 = { fg = palette.author2 },
        ReviewCommitAuthor3 = { fg = palette.author3 },
        ReviewCommitAuthor4 = { fg = palette.author4 },
        ReviewCommitAuthor5 = { fg = palette.author5 },
        ReviewCommitAuthor6 = { fg = palette.author6 },
        ReviewCommitDate = { fg = palette.faded },
        ReviewCommitActive = { fg = palette.positive, bold = true },
        ReviewCommitSeparator = { fg = palette.border },
        ReviewCommitGraph = { fg = palette.special },
        ReviewCommitGraphActive = { fg = palette.positive, bold = true },
        ReviewCommitPushed = { fg = palette.positive },
        ReviewCommitUnpushed = { fg = palette.negative },
        ReviewCommitIconRegular = { fg = palette.text },
        ReviewCommitIconMerge = { fg = palette.special },
        ReviewCommitIconRoot = { fg = palette.highlight },

        ReviewBranchName = { fg = palette.text },
        ReviewBranchMain = { fg = palette.positive },
        ReviewBranchHead = { fg = palette.accent },
        ReviewBranchActive = { fg = palette.positive, bold = true },
        ReviewBranchCurrent = { fg = palette.special },
        ReviewBranchCurrentRow = { bg = palette.tint },
        ReviewBranchSeparator = { fg = palette.border },
        ReviewHeadLabel = { fg = palette.highlight, bold = true },
    }

    for name, opts in pairs(highlights) do
        vim.api.nvim_set_hl(0, name, opts)
    end
end

return M
