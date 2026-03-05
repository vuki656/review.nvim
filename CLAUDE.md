# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

review.nvim is a Neovim plugin for reviewing AI-generated code changes. It provides a two-pane UI for browsing git diffs, adding comments, and exporting review feedback to tmux (designed for Claude Code workflows).

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

After every code change, run `luacheck lua/` and `make test`. Fix ALL luacheck warnings (not just errors) before considering the task done — zero warnings is the target. When adding new logic to pure modules (non-UI, non-git-shelling), add corresponding tests in `tests/`.

## Testing

Uses **mini.test** (from mini.nvim). Dependencies are auto-cloned into `.deps/` (gitignored) by the Makefile.

Test files live in `tests/` and follow the naming convention `test_<module>.lua`. Each test file requires only the modules it needs — the plugin is not loaded globally.

Shared fixtures and factories are in `tests/helpers.lua`.

Tested modules: `comment_types`, `core/diff`, `config`, `state`, `quick_comments/state`, `core/json_persistence`, `export/markdown`, `quick_comments/markdown`.

Not tested (integration-heavy): `core/git`, `core/async`, `core/watcher`, `ui/*`, `commands`.

## Architecture

```
lua/review/
├── init.lua                    # Public API: setup(), toggle(), open(), close(), export()
├── config.lua                  # Default config merged with user options
├── state.lua                   # Centralized state: comments, files, review status
├── comment_types.lua           # Static comment type definitions (note, fix, question)
├── commands.lua                # :Review command routing
├── core/
│   ├── git.lua                 # Git operations (diffs, status, staging)
│   ├── diff.lua                # Unified diff parsing into structured hunks
│   ├── async.lua               # Coroutine-based async utilities
│   ├── log.lua                 # File-based logger (DEBUG/INFO/WARN/ERROR)
│   ├── json_persistence.lua    # JSON file read/write
│   ├── persistence.lua         # Session persistence (wraps json_persistence + state)
│   └── watcher.lua             # File system watcher for auto-refresh
├── ui/
│   ├── init.lua                # UI orchestration (open/close/toggle)
│   ├── layout.lua              # Two-pane tab layout (file tree + diff view)
│   ├── file_tree.lua           # Left pane: file list with status icons
│   ├── diff_view.lua           # Right pane: diff with inline comments
│   ├── highlights.lua          # Highlight groups for UI theming
│   ├── help.lua                # Help overlay
│   ├── commit_list.lua         # Commit picker UI
│   ├── branch_list.lua         # Branch picker UI
│   └── util.lua                # UI utilities
├── quick_comments/
│   ├── init.lua                # Quick comments public API
│   ├── state.lua               # Quick comments state management
│   ├── panel.lua               # Side panel UI for quick comments
│   ├── markdown.lua            # Quick comments markdown export
│   ├── persistence.lua         # Quick comments persistence
│   └── signs.lua               # Gutter signs for quick comments
└── export/
    └── markdown.lua            # Export comments to clipboard/file/tmux
```

### Data Flow

1. User calls `:Review` → `commands.lua` routes to `ui/init.lua`
2. `layout.lua` creates a new tab with two splits
3. `git.lua` fetches changed files and diffs
4. `file_tree.lua` renders file list, `diff_view.lua` renders selected file's diff
5. Comments stored in `state.lua`, exported via `export/markdown.lua`

### Key Patterns

- **State centralization**: All mutable state lives in `state.lua`
- **Namespace isolation**: Uses Neovim namespaces for extmarks/highlights
- **Async git**: Uses `vim.system()` for non-blocking git commands
- **Git root caching**: Cached to avoid repeated syscalls

## User Commands

- `:Review` – Toggle review UI
- `:Review close` – Close review UI
- `:Review export` – Export comments to clipboard
- `:Review send [target]` – Send comments to tmux pane
- `:Review commit <sha>` – Change git comparison base
- `:Review pick [count]` – Interactive commit picker
- `:Review log` – Open the log file in a new tab

## Logging

Log file: `vim.fn.stdpath("log") .. "/review.log"` (typically `~/.local/state/nvim/review.log`).

Config: `log_level = "INFO"` (options: DEBUG, INFO, WARN, ERROR). Set via `require("review").setup({ log_level = "DEBUG" })`.

Use `:Review log` to open the log file. Key flows logged: git operations (stage, commit, push), layout lifecycle, commit/amend UI flow.

## Code Style

StyLua configuration: 120-char lines, 4-space indentation, Unix line endings. Run `stylua lua/` before committing.
