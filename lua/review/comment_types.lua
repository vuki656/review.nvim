local M = {}

M.TYPES = {
    note = {
        label = "Note",
        icon = "󰍩",
        highlight = "ReviewCommentNote",
        border_hl = "ReviewInputBorderNote",
        title_hl = "ReviewInputTitleNote",
    },
    fix = {
        label = "Fix",
        icon = "󰁨",
        highlight = "ReviewCommentFix",
        border_hl = "ReviewInputBorderFix",
        title_hl = "ReviewInputTitleFix",
    },
    question = {
        label = "Question",
        icon = "󰋗",
        highlight = "ReviewCommentQuestion",
        border_hl = "ReviewInputBorderQuestion",
        title_hl = "ReviewInputTitleQuestion",
    },
}

M.ORDER = { "fix", "note", "question" }

return M
