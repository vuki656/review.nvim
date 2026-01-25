# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

review.nvim is a Neovim plugin for reviewing AI-generated code changes. It provides a two-pane UI for browsing git diffs, adding comments, and exporting review feedback to tmux (designed for Claude Code workflows).

## Commands

```bash
# Format code
stylua lua/

# Check syntax
luac -p lua/review/*.lua lua/review/**/*.lua

# Lint (if luacheck is installed)
luacheck lua/

# Test in Neovim (run from plugin directory)
nvim --cmd "set rtp+=." -c "lua require('review').setup()"
```

## Architecture

```
lua/review/
├── init.lua          # Public API: setup(), toggle(), open(), close(), export()
├── config.lua        # Default config merged with user options
├── state.lua         # Centralized state: comments, files, review status
├── commands.lua      # :Review command routing
├── core/
│   ├── git.lua       # Git operations (diffs, status, staging)
│   └── diff.lua      # Unified diff parsing into structured hunks
├── ui/
│   ├── init.lua      # UI orchestration (open/close/toggle)
│   ├── layout.lua    # Two-pane tab layout (file tree + diff view)
│   ├── file_tree.lua # Left pane: file list with status icons
│   ├── diff_view.lua # Right pane: diff with inline comments
│   └── highlights.lua # 30+ highlight groups for UI theming
└── export/
    └── markdown.lua  # Export comments to clipboard/file/tmux
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

## Code Style

StyLua configuration: 120-char lines, 4-space indentation, Unix line endings. Run `stylua lua/` before committing.
