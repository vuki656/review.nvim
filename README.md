<div align="center">

<img src="https://github.com/user-attachments/assets/b8a5da59-a136-4c60-8f9b-81fd5b1be9e1" width=315>

## Review git diffs in Neovim, comment on lines, send the comments to your AI agent

</div>

<div align="center">

![Lua](https://img.shields.io/badge/Made%20with%20Lua-blueviolet.svg?style=for-the-badge&logo=lua&logoColor=white)

</div>

<div align="center">

![License](https://img.shields.io/badge/License-MIT-brightgreen?style=flat-square)
![Neovim](https://img.shields.io/badge/Neovim-0.10+-green.svg?style=flat-square&logo=Neovim&logoColor=white)

</div>

## ✨ Features

- Diff browser in a dedicated tab: file tree, branches, commits, comments
- Typed comments (note, fix, question) attached to specific diff lines
- Export all comments as markdown with diff context, to the clipboard or a tmux pane
- Quick comments on any line of any buffer, with gutter signs
- Git actions without leaving the tab: stage, commit, amend, push, pull, checkout, branch
- Session persistence, so comments survive a restart
- Auto refresh while an agent writes files

<img src="https://github.com/user-attachments/assets/3a645c54-9aa7-4ac0-88b0-64b8c74985c6">

## ⚡️ Requirements

- Neovim 0.10 or later (enforced in `plugin/review.lua`)
- `git` on `$PATH`
- **tmux**, optional, only for `:Review send` and the "Copy & Send to tmux" exit option. Everything else works without it.
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons), optional, file icons. Without it the icon column is blank.
- Tree-sitter parsers for the languages you review, optional, syntax highlighting inside the diff. Without a parser the diff still renders, just uncolored.

## 📦 Installation

`:Review` is registered by `plugin/review.lua`, so the command exists as soon as the plugin loads and the defaults in `config.lua` are already in effect. `setup()` is still worth calling: it registers the plugin's highlight groups, loads existing quick comments and sets up their gutter signs, enables autosave for the review session and for quick comments, and creates the optional global keymaps. Without it the quick comment signs are never defined, so `quick_comments.signs.enabled` has no effect.

### lazy.nvim

```lua
{
    "vuki656/review.nvim",
    opts = {},
}
```

With options:

```lua
{
    "vuki656/review.nvim",
    config = function()
        require("review").setup({
            keymaps = { toggle = "<leader>rv" },
        })
    end,
}
```

To lazy-load, give lazy.nvim its own trigger. The plugin is not loaded until that trigger fires, so `keymaps.toggle` does not exist yet either. Use lazy's `keys` instead:

```lua
{
    "vuki656/review.nvim",
    cmd = "Review",
    keys = { { "<leader>rv", "<cmd>Review<cr>", desc = "Toggle review" } },
    opts = {},
}
```

### packer.nvim

```lua
use({ "vuki656/review.nvim", config = function() require("review").setup({}) end })
```

### vim-plug

```vim
Plug 'vuki656/review.nvim'
" after plug#end():
lua require("review").setup({})
```

## 🖼️ Layout

`:Review` opens a dedicated tab of floating windows. A sidebar on the left, the diff on the right.

```
┌─ Branch ────────┐┌───────────────────────────────┐
├─ Files ─────────┤│                               │
│                 ││                               │
├─ Branches ──────┤│            diff               │
│                 ││                               │
├─ Commits ───────┤│                               │
│                 ││                               │
├─ Comments ──────┤│                               │
└─────────────────┘└───────────────────────────────┘
```

**Branch** is a read-only line showing the current branch. **Files**, **Branches**, **Commits** and **Comments** are focusable. `<Tab>` cycles Files → Branches → Commits → Comments → Files; `h`/`l` walk the same chain; `<C-l>` jumps from any sidebar panel to the diff, `<C-h>` from the diff back to Files. Set `ui.number_navigation = true` to use `1`–`4` for Files, Branches, Commits and Comments, and `0` for the diff.

## 🤖 Commands

| Command | Description |
| --- | --- |
| `:Review` | Toggle the review UI |
| `:Review close` | Close the review UI |
| `:Review export` | Copy all comments to the clipboard as markdown |
| `:Review send [target]` | Send comments to `export.on_export`, or to a tmux pane (defaults to `tmux.target`) |
| `:Review commit <sha>` | Set the diff base to `<sha>` |
| `:Review pick [count]` | Pick a base commit from the last `count` commits (default 20) |
| `:Review qc` | Add a quick comment on the current line of the current buffer, or on a range with `:'<,'>Review qc` |
| `:Review qp` | Toggle the quick comments panel |
| `:Review log` | Open the plugin log file in a new tab |

`:checkhealth review` verifies the Neovim version, git and the repository, tmux and `$TMUX`, whether `setup()` has run, the log level, and the log file path. The "`setup()` has not been called" result is a warning, not an error. The defaults are in effect either way.

Lua API:

```lua
local review = require("review")

review.setup(opts)
review.toggle()
review.open()
review.close()
review.export()          -- to clipboard
review.send(target)      -- to export.on_export, else tmux; target optional
review.is_open()         -- boolean
review.get_state()       -- current state table
review.reset()           -- reset state
```

Quick comments have their own module:

```lua
local qc = require("review.quick_comments")

qc.add()            -- comment on the current line
qc.add(42, 50)      -- comment on lines 42 to 50
qc.add_visual()     -- comment on the current visual selection
qc.toggle_panel()
qc.export()         -- copy to clipboard
qc.copy()           -- copy to clipboard, then clear all quick comments
```

## ⌨️ Keymaps

All keymaps are buffer-local to the review UI. Press `?` in the Files, Branches, Commits or Comments panel, or in the diff pane, for the in-plugin help overlay listing that panel's keymaps.

Numeric section navigation is disabled by default. When `ui.number_navigation` is enabled, `1` focuses Files, `2` Branches, `3` Commits, `4` Comments and `0` the diff pane. These mappings are only active inside the review UI; in side-by-side mode, `0` focuses the new (right) diff pane.

### Files panel

| Key | Action |
| --- | --- |
| `j` / `k` | Next / previous entry (skips headers, loads its diff) |
| `<CR>` | On a file: load the diff and focus the diff pane. On a directory: collapse/expand |
| `<Space>` | Stage / unstage. On a directory or the `/` root, applies to everything under it |
| `e` | Open the real file at its first change, closing the review |
| `L` | Show the full path in a popup |
| `R` | Refresh the file list |
| `` ` `` | Toggle tree / flat list view |
| `S` | Toggle unified / side-by-side diff |
| `{` / `}` | Shrink / expand diff context lines |
| `c` | Commit staged changes (subject + description popup) |
| `A` | Amend staged changes into the last commit. With nothing staged, offers to stage everything first |
| `d` | Revert the file's changes (confirms first) |
| `P` | Push to remote |
| `B` | Focus the Commits panel |
| `<C-n>` | Hide / show the whole sidebar |
| `J` / `K` | Scroll the **diff pane** down / up |
| `<Tab>` / `l` | Focus the Branches panel |
| `<C-l>` | Focus the diff pane |
| `<Esc>` | Reset the diff base back to `HEAD` (no-op unless a branch or commit is selected) |
| `q` | Close the review |
| `?` | Help overlay |

### Diff pane

| Key | Action |
| --- | --- |
| `c` | Add a comment on the current line, or on the selection in visual mode |
| `dc` | Delete the comment on the current line |
| `]c` / `[c` | Next / previous hunk |
| `]f` / `[f` | Next / previous file |
| `e` | Open the real file at the current line, closing the review (raises the exit menu if you have comments) |
| `S` | Toggle unified / side-by-side diff |
| `{` / `}` | Shrink / expand diff context lines |
| `<C-n>` | Hide / show the sidebar |
| `<C-h>` | Focus the Files panel (in side-by-side, from the right pane focuses the left pane) |
| `<C-l>` | In side-by-side, from the left pane focuses the right pane |
| `<Esc>` | Focus the Files panel, and reset the base to `HEAD` if a branch or commit was selected |
| `q` | Close the review |
| `?` | Help overlay |

In side-by-side mode, `c` and `dc` are only bound on the right (new) pane. A binary file renders as a `Binary file` placeholder instead of an empty pane.

### Comment input popup

| Key | Mode | Action |
| --- | --- | --- |
| `<CR>` | insert, normal | Submit |
| `<Esc>` | insert, normal | Cancel |
| `<C-c>` | insert | Cancel |
| `<S-CR>` | insert | Newline |
| `<Tab>` / `<S-Tab>` | insert | Cycle comment type: Fix → Note → Question (diff pane comments only) |
| `<C-t>` | insert | Template picker (diff pane comments only) |

Submitting an empty input also discards the comment. The quick comment input has no types or templates, so only `<CR>`, `<Esc>`, `<C-c>` and `<S-CR>` are bound there. In the template picker, press a template's key to apply it, or `<Esc>` / `q` / `<C-t>` to back out.

### Branches panel

| Key | Action |
| --- | --- |
| `j` / `k` | Next / previous branch |
| `<CR>` | Diff the main branch against the selected branch |
| `<Space>` | Check out the branch (refuses on a dirty worktree) |
| `p` | Pull from remote |
| `n` | Create a new branch from the selected one |
| `d` | Delete the branch (confirms first) |
| `P` | Push to remote |
| `<C-d>` / `<C-u>` | Scroll the **diff pane** down / up |
| `<Tab>` / `l` | Focus the Commits panel |
| `h` | Focus the Files panel |
| `<C-l>` | Focus the diff pane |
| `<Esc>` | Reset the diff base back to `HEAD` |
| `q` | Close the review |
| `?` | Help overlay |

### Commits panel

| Key | Action |
| --- | --- |
| `j` / `k` | Next / previous commit, previewing its full diff |
| `<CR>` | Set the diff base to that commit and browse its files |
| `u` | Uncommit, soft reset the most recent commit (confirms first) |
| `P` | Push to remote |
| `<C-d>` / `<C-u>` | Scroll the **diff pane** down / up |
| `<Tab>` / `l` | Focus the Comments panel |
| `h` | Focus the Branches panel |
| `<C-l>` | Focus the diff pane |
| `<Esc>` | Reset the diff base back to `HEAD` |
| `q` | Close the review |
| `?` | Help overlay |

### Comments panel

| Key | Action |
| --- | --- |
| `j` / `k` | Next / previous entry |
| `<CR>` | Jump to the comment in the diff. On a directory in tree view: collapse/expand |
| `d` | Delete the comment (confirms first) |
| `t` | Toggle flat / tree grouping |
| `P` | Push to remote |
| `<C-d>` / `<C-u>` | Scroll the **diff pane** down / up |
| `<Tab>` | Focus the Files panel |
| `h` | Focus the Commits panel |
| `<C-l>` | Focus the diff pane |
| `<Esc>` | Reset the diff base back to `HEAD` |
| `q` | Close the review |
| `?` | Help overlay |

### Quick comments panel

Quick comments are separate from review comments: they attach to any line of any buffer, outside the review UI, and show up as gutter signs. `:Review qc` adds one, `:Review qp` toggles the panel. Selecting lines first and running `:'<,'>Review qc` attaches the comment to the whole range, which exports as `**Lines 42-50**` with all the selected lines as context. If `quick_comments.keymaps.add` is set, that key works in visual mode too.

| Key | Action |
| --- | --- |
| `j` / `k` | Standard cursor movement |
| `<CR>` | Jump to the comment's file and line in the previous window |
| `L` | Preview the full comment text in a popup |
| `e` | Edit the comment |
| `d` | Delete the comment |
| `c` | Copy all quick comments to the clipboard as markdown |
| `q` / `<Esc>` | Close the panel |

## ⚙️ Configuration

Full defaults, copy-pasteable:

```lua
require("review").setup({
    keymaps = {
        toggle = nil,
    },
    diff = {
        base = "HEAD",
    },
    ui = {
        file_tree_width = 33,
        diff_view_mode = "unified",
        number_navigation = false,
        panels = { "file_tree", "comment_list" },
    },
    tmux = {
        target = "!",
        auto_enter = false,
    },
    quick_comments = {
        keymaps = {
            add = nil,
            toggle_panel = nil,
        },
        panel = {
            width = 65,
            position = "right",
        },
        signs = {
            enabled = true,
        },
    },
    export = {
        context_lines = 3,
        on_export = nil,
    },
    auto_refresh = {
        enabled = true,
        debounce_ms = 500,
    },
    persistence = {
        enabled = true,
    },
    log_level = "WARN",
    log_file = nil,
    templates = {
        { key = "e", label = "Extract", text = "Extract this into a separate function/component" },
        { key = "r", label = "Rename", text = "Rename to: " },
        { key = "m", label = "Move", text = "Move this to a separate file" },
        { key = "t", label = "Types", text = "Add proper types" },
        { key = "h", label = "Error handling", text = "Add error handling" },
        { key = "p", label = "Performance", text = "Performance concern: " },
        { key = "s", label = "Simplify", text = "Simplify this" },
        { key = "d", label = "Delete", text = "Remove this" },
    },
})
```

The `nil` entries are unset by default. No global keymaps are created unless you give them a value, and `log_file` falls back to the temp path described below.

- `keymaps.toggle`: global normal-mode key that toggles the review UI.
- `diff.base`: git revision the diff compares against. `"HEAD"` means "everything in the worktree".
- `ui.file_tree_width`: sidebar width as a **percentage** of total columns, not a column count.
- `ui.diff_view_mode`: `"unified"` or `"split"` (side-by-side) on open. `S` toggles at runtime.
- `ui.number_navigation`: enable `1`–`4` to focus the sidebar sections and `0` to focus the diff. Disabled by default so normal-mode counts and `0` retain their usual behavior unless you opt in.
- `ui.panels`: sidebar panels to display. Can be a list of panel names (e.g. `{ "file_tree", "comment_list" }` or `{ "files", "comments" }`) or a table of boolean toggles (e.g. `{ branch = false, branches = false, commits = false }`). Defaults to `{ "file_tree", "comment_list" }` (showing Files changed and Comments).
- `tmux.target`: tmux target that `:Review send` pastes into. The default `"!"` is tmux's last active pane, which is normally the pane you came from, usually the one running your agent. Any target `tmux paste-buffer -t` accepts works instead, e.g. a named window `"CLAUDE"`, `"CLAUDE.0"` or a fully qualified `"session:window.pane"`.
- `tmux.auto_enter`: send `Enter` after pasting. Off by default so you can read the prompt before submitting it.
- `quick_comments.keymaps.add` / `.toggle_panel`: global keys for `:Review qc` and `:Review qp`.
- `quick_comments.signs.enabled`: gutter signs for quick comments.
- `export.context_lines`: lines of diff context included above and below each comment in the exported markdown.
- `export.on_export`: your own delivery callback, `function(content, comments)`. `content` is the exported markdown, `comments` the comment tables it was built from. Return `false` (or raise) to say the hand-off failed. When it is set, `:Review send` and "Copy & Send" call it instead of pasting into tmux. The clipboard paths, `:Review export` and "Exit & Copy", still copy and then call it as well. A failed hand-off on close keeps the saved session instead of deleting it, so nothing is lost.
- `auto_refresh`: a filesystem watcher re-renders the UI when files change on disk, debounced by `debounce_ms`. It walks the git root and watches each directory individually (libuv has no recursive watching on Linux), skipping `.git`, `node_modules`, `target`, `dist`, `build`, `.venv` and `vendor`, and stops at 2000 directories. Past that a warning goes to the log and the rest of the tree is not watched. The directory list is built when the UI opens, so directories created afterwards are picked up on the next open. Useful when an agent is writing while you read.
- `persistence.enabled`: remembers comments across sessions. State lives in `.git/review-session.json` and `.git/review-comments.json`, so nothing needs gitignoring.
- `log_level`: `"DEBUG"`, `"INFO"`, `"WARN"` or `"ERROR"`.
- `log_file`: path to write the log to. Unset by default, in which case the log goes to `review.nvim/review.log` under the system temp directory (`vim.uv.os_tmpdir()`, typically `/tmp/review.nvim/review.log`) so it gets cleaned up with the rest of temp. Set this to keep the log somewhere persistent. Either way the file rotates: once it passes 1 MB it is moved to `<path>.old` and a fresh one is started. `:Review log` opens the current file.
- `templates`: canned comment texts reachable with `<C-t>` in the diff comment input. A `text` ending in `": "` leaves the cursor at the end for you to finish; anything else submits immediately.

## 💬 Comments and export

The loop:

1. `:Review` opens the diff against `HEAD`, so you see whatever the agent just wrote.
2. Read the diff. Press `c` on a line to attach a comment, `<Tab>` to pick its type (Fix / Note / Question), `<CR>` to submit. Comments render as boxed virtual lines under the code and collect in the Comments panel.
3. `<Space>` on files in the Files panel to stage the parts you're keeping.
4. `q` to close. If you have comments, an exit popup appears:
   - **Exit, Copy & Send to tmux**: copies to the clipboard *and* pastes into the tmux target.
   - **Exit & Copy**: clipboard only.
   - **Exit**: keeps the session so `:Review` picks up where you left off.

   The two copy options clear the saved session. With no comments, `q` exits straight away.
5. Paste into the agent, or let tmux do it for you.

`:Review export` and `:Review send [target]` do the same export without closing the UI.

The generated markdown looks like:

````markdown
# Code Review Comments

## src/api/client.ts

### [FIX] src/api/client.ts:42

```typescript
 const res = await fetch(url)
+return res.json()
 }
```

Handle a non-2xx response here.
````

To hand the export to your own workflow instead of pasting it somewhere, set `export.on_export`:

```lua
require("review").setup({
    export = {
        on_export = function(content, comments)
            local path = vim.fn.stdpath("state") .. "/review-latest.md"
            if vim.fn.writefile(vim.split(content, "\n"), path) ~= 0 then
                return false
            end
            vim.system({ "my-agent", "--file", path, "--count", tostring(#comments) })
            return true
        end,
    },
})
```

For the tmux path, `tmux.target` names where the markdown is pasted. The default `"!"` is tmux's last active pane, so the export lands in whatever pane you were in before Neovim, usually the one running your agent. If your agent lives somewhere fixed, set a name instead (`target = "CLAUDE"`, or a fully qualified `"session:window.pane"`), or pass one per call with `:Review send other-pane`. "Copy & Send" fails quietly outside tmux, you still get the clipboard copy.

## 📄 License

MIT
