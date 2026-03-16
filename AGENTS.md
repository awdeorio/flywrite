# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

flywrite-mode is an Emacs minor mode that provides inline writing suggestions powered by an LLM API. Suggestions appear as flymake diagnostics (wavy underlines) with explanations via flymake-popon or the echo area. The UX goal is unobtrusive, always-on feedback (like Flyspell but for style/clarity, built on flymake).

The entire package lives in a single file: `flywrite-mode.el`. The design spec is in `spec.md`. Example files in `examples/` are used for manual end-to-end testing in Emacs.

## Development

This is a pure Emacs Lisp package with no build system and no external dependencies.

**Load for development** (in Emacs):
```elisp
(load-file "/path/to/flywrite-mode.el")
```

**Regression test** (byte-compile check + ERT unit tests):
```bash
./test
```

**Byte-compile check** (catches warnings and errors without running Emacs interactively):
```bash
emacs -Q --batch -f batch-byte-compile flywrite-mode.el && rm -f flywrite-mode.elc
```

**Requires:** Emacs 27.1+, an LLM API key (via `flywrite-api-key-file` (recommended), `flywrite-api-key`, or `FLYWRITE_API_KEY` env var). API key is optional for local providers like Ollama.

**README consistency:** Default values shown in the README (including the system prompt) must match the source code in `flywrite-mode.el`. When changing defaults, update both.

## Architecture

```
Buffer edits
    │
    ▼
after-change-functions
    │  marks sentence (or paragraph) dirty
    ▼
Dirty sentence registry  ◄──── sentence content deduplication (hash check)
    │
    │  idle timer fires (1.5s)
    ▼
Request queue
    │  concurrent call cap (max 3 in-flight)
    ▼
LLM API  (url-retrieve, async)
    │
    ▼
Response handler
    │  stale check (hash comparison)
    ▼
Flymake report  →  diagnostics (:note severity)
    │
    ▼
flymake-popon / echo area  →  inline popups near flagged text
```

Key design decisions:
- **Sentence-level granularity** by default (paragraph via `flywrite-granularity`)
- **Content deduplication**: MD5 hashing prevents redundant API calls; checked hashes stored in `flywrite--checked-sentences` hash table
- **Stale response guard**: responses discarded if sentence changed while call was in-flight, then re-dirtied for re-check
- **Flymake backend**: `flywrite-flymake` registered in `flymake-diagnostic-functions`; handles eglot coexistence by re-adding itself via `eglot-managed-mode-hook`
- **Prompt caching**: system prompt uses `cache_control` with `"type": "ephemeral"` for cost reduction
- **Mode-aware suppression**: skips code blocks, comments, and other non-prose regions via font-lock face inspection
- **Multi-provider support**: Anthropic endpoints are auto-detected (use `x-api-key` header); all others use `Bearer` token in `Authorization` header

## Emacs Lisp Conventions

- All async HTTP via `url-retrieve` (no external dependencies)
- All state is buffer-local (dirty registry, checked-sentences hash table, in-flight counter, pending queue, report-fn)
- Package prefix: `flywrite-` (public), `flywrite--` (internal)
- No default keybindings; commands available via `M-x`
- Diagnostics are tagged with `[flywrite]` suffix in messages
