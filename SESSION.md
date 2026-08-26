# Session Notes

## Known Issues / Oddities

- `quick_comments.persistence`: `persistence.save()` result is ignored after `qc_state.clear()` in `clear_quick_comments()` (used by `M.copy()` and `M.send()`). If `persistence.save()` refuses (for instance, if the repository changed since load), comments are cleared from in-memory state while the on-disk `.git/review-comments.json` file remains intact.
