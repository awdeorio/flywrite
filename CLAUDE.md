# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

flywrite-mode is an Emacs minor mode that provides inline writing suggestions powered by the Anthropic LLM API. Suggestions appear as flymake diagnostics (wavy underlines) with explanations via flymake-popon or the echo area. The UX goal is unobtrusive, always-on feedback (like Flyspell but for style/clarity, built on flymake).

The entire package lives in a single file: `flywrite-mode.el`. The design spec is in `spec.md`. Test files in `tests/` are used for manual testing in Emacs.

## Development

This is a pure Emacs Lisp package with no build system, no external dependencies, and no automated tests. Development is done by loading the file in Emacs and testing interactively.

**Load for development** (in Emacs):
```elisp
(load-file "/path/to/flywrite-mode.el")
```

**Byte-compile** (optional):
```bash
emacs -Q --batch -f batch-byte-compile flywrite-mode.el
```

**Requires:** Emacs 27.1+, an Anthropic API key (via `flywrite-api-key`, `flywrite-api-key-file`, or `ANTHROPIC_API_KEY` env var).

## Architecture

The pipeline: buffer edits → `after-change-functions` → dirty sentence registry (deduplicated by MD5 hash) → idle timer (1.5s) → request queue (max 3 concurrent) → async `url-retrieve` to Anthropic Messages API → response handler (stale-check via hash comparison) → flymake diagnostics (`:note` severity).

Key design decisions:
- **Sentence-level granularity** by default (paragraph via `flywrite-granularity`)
- **Content deduplication**: MD5 hashing prevents redundant API calls; checked hashes stored in `flywrite--checked-sentences` hash table
- **Stale response guard**: responses discarded if sentence changed while call was in-flight, then re-dirtied for re-check
- **Flymake backend**: `flywrite-flymake` registered in `flymake-diagnostic-functions`; handles eglot coexistence by re-adding itself via `eglot-managed-mode-hook`
- **Prompt caching**: system prompt uses `cache_control` with `"type": "ephemeral"` for cost reduction
- **Mode-aware suppression**: skips code blocks, comments, and other non-prose regions via font-lock face inspection

## Emacs Lisp Conventions

- All async HTTP via `url-retrieve` (no external dependencies)
- All state is buffer-local (dirty registry, checked-sentences hash table, in-flight counter, pending queue, report-fn)
- Package prefix: `flywrite-` (public), `flywrite--` (internal)
- Key bindings use the `C-c C-g` prefix
- Diagnostics are tagged with `[flywrite]` suffix in messages
