# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

review.nvim is a Neovim plugin for reviewing AI-generated code changes. `:Review` opens a dedicated tab of floating windows: a sidebar of five stacked floats (Branch, Files, Branches, Commits, Comments) on the left and a diff pane on the right. It browses git diffs, attaches typed comments to lines, and exports review feedback to the clipboard or tmux (designed for Claude Code workflows).

## Commands

```bash
# Lint
luacheck lua/

# Run all tests
make test

# Run a single test file
make test-file FILE=tests/test_diff.lua

# Format code
stylua lua/
```

## Workflow

After every code change, run `luacheck lua/` and `make test`. Fix ALL luacheck warnings (not just errors) before considering the task done — zero warnings is the target. When adding new features or logic to pure modules (non-UI, non-git-shelling), always add corresponding tests in `tests/`. If a module is testable (pure logic, no vim.api dependencies), it should have tests.

CI (`.github/workflows/ci.yml`) runs three jobs: `make test` on Neovim stable and nightly, `luacheck lua/`, and `stylua --check lua/` (pinned to stylua 2.5.2). Formatting is enforced, so run `stylua lua/` before committing or CI fails.

Behavior changes are documented in three places that are expected to stay in sync: `README.md`, `doc/review.txt` (vimdoc), and this file.

The plugin targets Neovim 0.10+; `plugin/review.lua` hard-refuses to load below that.

## Testing

Uses **mini.test** (from mini.nvim). Dependencies are auto-cloned into `.deps/` (gitignored) by the Makefile.

Test files live in `tests/` and follow the naming convention `test_<module>.lua`. Each test file requires only the modules it needs — the plugin is not loaded globally.

Shared fixtures and factories are in `tests/helpers.lua`.

Tested modules: `comment_types`, `config`, `core/diff`, `core/format`, `core/json_persistence`, `core/paths`, `export/markdown`, `quick_comments/markdown`, `quick_comments/state`, `state`. `core/git` is tested only for its pure parsers (`tests/test_git_parse.lua` covers name-status and commit-line parsing); everything in it that shells out to git is not.

Not tested (integration-heavy): `core/async`, `core/log`, `core/persistence`, `core/watcher`, `commands`, `health`, `quick_comments/init`, `quick_comments/panel`, `quick_comments/persistence`, `quick_comments/signs`, `ui/*`.

## Architecture

```
lua/review/
├── init.lua                    # Public API: setup(), toggle(), open(), close(), export()
├── config.lua                  # Default config merged with user options
├── state.lua                   # Centralized state: comments, files, review status
├── comment_types.lua           # Static comment type definitions (note, fix, question)
├── commands.lua                # :Review command routing (registered from plugin/review.lua)
├── health.lua                  # :checkhealth review
├── core/
│   ├── git.lua                 # Git operations (diffs, status, staging) + pure parsers
│   ├── diff.lua                # Unified diff parsing into structured hunks
│   ├── format.lua              # Date shortening, author initials, UTF-8 truncation
│   ├── paths.lua               # Path helpers (relative paths, fence language, test files)
│   ├── async.lua               # Coroutine-based async utilities
│   ├── log.lua                 # File-based logger (DEBUG/INFO/WARN/ERROR), rotates at 1 MB
│   ├── json_persistence.lua    # JSON file read/write, resolves paths inside the git dir
│   ├── persistence.lua         # Session persistence (wraps json_persistence + state)
│   └── watcher.lua             # Per-directory fs watchers for auto-refresh
├── ui/
│   ├── init.lua                # UI orchestration (open/close/toggle), wires panel callbacks
│   ├── layout.lua              # Floating-window tab layout (sidebar floats + diff pane)
│   ├── file_tree.lua           # Files panel: file list with status icons
│   ├── diff_view.lua           # Diff pane: diff, inline comments, comment input
│   ├── comment_list.lua        # Comments panel
│   ├── commit_list.lua         # Commits panel
│   ├── branch_list.lua         # Branches panel
│   ├── panel_keymaps.lua       # Keymaps shared by the sidebar panels
│   ├── push.lua                # Shared push action
│   ├── highlights.lua          # Highlight groups, re-applied on ColorScheme
│   ├── palette.lua             # Semantic color names the highlight groups are built from
│   ├── help.lua                # Help overlay built from tracked keymaps
│   └── util.lua                # UI utilities (buffer mapper, scrolling, type cycling)
├── quick_comments/
│   ├── init.lua                # Quick comments public API
│   ├── state.lua               # Quick comments state management
│   ├── panel.lua               # Side panel UI for quick comments
│   ├── markdown.lua            # Quick comments markdown export
│   ├── persistence.lua         # Quick comments persistence
│   └── signs.lua               # Gutter signs for quick comments
└── export/
    └── markdown.lua            # Export comments to clipboard/file/tmux or export.on_export
```

### Data Flow

1. User calls `:Review` → `commands.lua` routes to `ui/init.lua`
2. `layout.lua` creates a new tab and opens the sidebar floats plus the diff float
3. `git.lua` fetches changed files and diffs
4. `file_tree.lua` renders the file list, `diff_view.lua` renders the selected file's diff, the other panels render branches, commits and comments
5. Comments stored in `state.lua`, exported via `export/markdown.lua`

Numeric section navigation is opt-in through `ui.number_navigation`. When
enabled, `1`–`4` focus Files, Branches, Commits and Comments, while `0` focuses
the diff pane. The mappings are buffer-local to the review UI and do not affect
normal buffers; in side-by-side mode `0` focuses the new (right) pane.

### Comparison Model

Everything the UI shows is derived from two fields in `state.lua`: `base` and `base_end`. They define the diff range, and every panel reads them rather than holding its own notion of what is being compared.

- `base = "HEAD"`, `base_end = nil` — working tree changes. This is the default and the reset target.
- `base = <rev>`, `base_end = <rev>` — a fixed range. Selecting a commit in the commits panel sets `base = <hash>~1`, `base_end = <hash>`; selecting a branch sets `base = <main branch>`, `base_end = <branch>`.
- `:Review commit <sha>` is the exception: it sets `base = <sha>` with `base_end = nil`, so it means "everything since that sha", not "that one commit".

`state.is_history_mode()` is just `base ~= "HEAD"`. `<Esc>` in any panel calls `ui.reset_to_head()`, which restores the default and refreshes every panel. Any revision arriving from user input or the session file must pass `git.is_safe_rev()` first, so a value like `--upload-pack=...` is not handed to git as an option.

### Comment Anchoring

`comment.line` is a display row in the current rendering, not a durable location — `diff_view.render_comments` overwrites it on every render via `display_row_for()`. The durable anchor is `original_line` plus `side` (`"old"` or `"new"`), captured from the source line when the comment is submitted; re-anchoring scans `render_lines` for the row whose source line matches on the matching side, and falls back to the old `comment.line` if the line no longer exists in the diff. Export prefers `original_line` when reporting a location. Anything that changes diff parsing or rendering must keep `original_line`/`side` intact, or comments silently drift onto the wrong lines.

### Export Delivery

`export/markdown.lua` separates generation from delivery: `generate()` builds the markdown, and `to_clipboard`, `to_file`, `to_tmux` are thin wrappers on it. `export.on_export` in config is a user delivery callback, `function(content, comments)`, and `M.send()` is the entry point every send path uses — it calls the callback when one is set and falls back to `to_tmux` when not. `to_clipboard` copies first and then also calls the callback. A callback returning `false` or raising counts as a failed hand-off, which makes the close path keep the saved session instead of deleting it (`has_handler()` gates that so tmux's optimistic `true` keeps its old behavior).

### Session Persistence

Sessions live at `review-session.json` inside the resolved git dir (`git rev-parse --absolute-git-dir`), not the working tree, so worktrees and submodules get their own file. The format is versioned (`version = 1`); an unknown version is left untouched.

`core/persistence.lua` is deliberately conservative, and each guard exists because of a bug:

- Never overwrite or delete a file that exists but failed to parse, or one whose version is unsupported.
- Never save into a path different from the one loaded (cross-repo write).
- On close, the file is deleted only when comments were successfully exported; when the clipboard write does not land, the session is kept instead.
- If the file's mtime changed since load, the on-disk comments are merged in by id before writing, so two Neovim instances do not clobber each other. When state has no comments and the file changed, it is left in place rather than removed.
- Writes go through a pid-suffixed temp file plus rename.

Autosave (`VimLeavePre`) is registered from `plugin/review.lua`, so sessions persist even when `setup()` is never called.

### Key Patterns

- **State centralization**: All mutable state lives in `state.lua`
- **Namespace isolation**: Uses Neovim namespaces for extmarks/highlights
- **Async git**: `core/git.lua` carries two variants of most operations. The plain ones call `vim.system():wait()`; the `*_async` ones (`get_diff_async`, `get_changed_files_async`, `get_all_file_statuses_async`, `get_file_at_rev_async`, plus the `*_streaming` commit helpers) must run inside `async.run()` and use `async.system()`/`async.all()`, which are coroutine wrappers that yield until the callback fires. The hot render paths — file tree refresh, diff rendering, treesitter highlight fetch — use the async variants and fan out concurrent git calls with `async.all()`; everything else stays synchronous
- **Git root caching**: Cached to avoid repeated syscalls
- **Keymap tracking**: Panels register keymaps through `ui/util.lua`'s buffer mapper so `?` can render the help overlay from the same list
- **Highlight defaults**: Groups in `highlights.lua` use the `ui/palette.lua` colors and are set with `default = true`, and re-applied on `ColorScheme` so they survive a theme change

## User Commands

- `:Review` – Toggle review UI
- `:Review close` – Close review UI
- `:Review export` – Export comments to clipboard
- `:Review send [target]` – Send comments to `export.on_export`, or a tmux pane when unset
- `:Review commit <sha>` – Change git comparison base
- `:Review pick [count]` – Interactive commit picker
- `:Review qc` – Add a quick comment on the current line
- `:Review qp` – Toggle the quick comments panel
- `:Review log` – Open the log file in a new tab

`:Review` is registered from `plugin/review.lua`, so it exists without `setup()`.

## Logging

Log file: `review.nvim/review.log` under `vim.uv.os_tmpdir()` (typically `/tmp/review.nvim/review.log`). Temp is deliberate so it is cleaned up. Rotates at 1 MB: the current file becomes `<path>.old` and a fresh one starts.

Config: `log_level = "WARN"` (options: DEBUG, INFO, WARN, ERROR) and `log_file` (a path, defaults to nil, overrides the temp path). Set via `require("review").setup({ log_level = "DEBUG" })`.

Use `:Review log` to open the log file. Key flows logged: git operations (stage, commit, push), layout lifecycle, commit/amend UI flow.

## Code Style

StyLua configuration: 120-char lines, 4-space indentation, Unix line endings. Run `stylua lua/` before committing.
