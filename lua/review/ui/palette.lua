local colors = {
    green = "#89ca78",
    red = "#ef596f",
    blue = "#61afef",
    yellow = "#e5c07b",
    purple = "#c678dd",
    orange = "#d19a66",
    cyan = "#56b6c2",

    white = "#abb2bf",
    grey = "#5c6370",
    grey_dark = "#4b5263",
    grey_darker = "#3e4452",
    blue_dark = "#4a90d9",
    black = "#000000",

    green_dark = "#002800",
    green_mid = "#004000",
    red_dark = "#3f0001",
    red_mid = "#600010",

    grey_bg = "#2a2d35",
    blue_bg = "#1e2940",
    purple_bg = "#2c2033",
    dark_bg = "#1e1e1e",
    grey_subtle = "#333842",
}

local palette = {
    positive = colors.green,
    negative = colors.red,
    caution = colors.orange,
    accent = colors.blue,
    highlight = colors.yellow,
    special = colors.purple,

    text = colors.white,
    muted = colors.grey,
    faded = colors.grey_dark,

    border = colors.grey_darker,
    border_accent = colors.blue_dark,

    diff_add = colors.green_dark,
    diff_add_emphasis = colors.green_mid,
    diff_delete = colors.red_dark,
    diff_delete_emphasis = colors.red_mid,

    selected = colors.black,
    surface = colors.grey_bg,
    header = colors.blue_bg,
    tint = colors.purple_bg,
    padding = colors.dark_bg,
    cursor_line = colors.grey_subtle,

    author1 = colors.blue,
    author2 = colors.purple,
    author3 = colors.yellow,
    author4 = colors.cyan,
    author5 = colors.orange,
    author6 = colors.red,
}

return palette
