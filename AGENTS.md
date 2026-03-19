# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

flywrite-mode is an Emacs minor mode that provides inline writing suggestions powered by an LLM API. Suggestions appear as flymake diagnostics (wavy underlines) with explanations via flymake-popon or the echo area. The UX goal is unobtrusive, always-on feedback (like Flyspell but for style/clarity, built on flymake).

The entire package lives in a single file: `flywrite-mode.el`. Tests are in `test-flywrite.el`. Sample files in `samples/` are used for manual end-to-end testing in Emacs.

## Development

This is a pure Emacs Lisp package with no build system and no external dependencies.

**Load for development** (in Emacs):
```elisp
(load-file "/path/to/flywrite-mode.el")
```

**Regression test** (linting + byte-compile + ERT unit tests):
```bash
./test
```

The `./test` script runs these checks in order:
1. **Byte-compile** with warnings-as-errors
2. **checkdoc** — docstring style
3. **elint** — Emacs Lisp lint
4. **elisp-lint** — installed from MELPA on first run
5. **Nesting depth** — custom `lint-nesting.el`, max control-flow depth of 6
6. **ERT unit tests** — `test-flywrite.el`

**Byte-compile check** (standalone):
```bash
emacs -Q --batch --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile flywrite-mode.el && rm -f flywrite-mode.elc
```

**Run a single ERT test by name:**
```bash
emacs -Q --batch -l flywrite-mode.el -l test-flywrite.el --eval '(ert-run-tests-batch-and-exit "flywrite-test-NAME")'
```

**Requires:** Emacs 27.1+, an LLM API key (via `flywrite-api-key-file` (recommended), `flywrite-api-key`, or `FLYWRITE_API_KEY` env var). API key is optional for local providers like Ollama.

**README consistency:** Default values shown in the README (including the system prompt) must match the source code in `flywrite-mode.el`. When changing defaults, update both.

**Samples README consistency:** When adding, removing, or renaming files in `samples/`, update the table in `samples/README.md` to match.

## Architecture

```
Buffer edits
    │
    ▼
after-change-functions
    │  marks unit dirty
    ▼
Dirty unit registry  ◄──── content deduplication (hash check)
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
- **Unit granularity**: a "unit" is the text sent per API call — one sentence or one paragraph, controlled by `flywrite-granularity` (sentence by default)
- **Content deduplication**: MD5 hashing prevents redundant API calls; checked hashes stored in `flywrite--checked-units` hash table
- **Stale response guard**: responses discarded if unit changed while call was in-flight, then re-dirtied for re-check
- **Flymake backend**: `flywrite-flymake` registered in `flymake-diagnostic-functions`; handles eglot coexistence by re-adding itself via `eglot-managed-mode-hook`
- **Prompt caching**: system prompt uses `cache_control` with `"type": "ephemeral"` for cost reduction
- **Mode-aware suppression**: skips code blocks, comments, and other non-prose regions via font-lock face inspection
- **Multi-provider support**: Anthropic endpoints are auto-detected (use `x-api-key` header); all others use `Bearer` token in `Authorization` header

## Emacs Lisp Conventions

- All async HTTP via `url-retrieve` (no external dependencies)
- All state is buffer-local (dirty registry, checked-units hash table, in-flight counter, pending queue, report-fn)
- Package prefix: `flywrite-` (public), `flywrite--` (internal)
- No default keybindings; commands available via `M-x`
- Diagnostics are tagged with `[flywrite]` suffix in messages
- 80-character line width
- Logical nesting depth: prefer 4-5 levels, hard limit of 6 (enforced by `lint-nesting.el`; counted forms include `if`, `when`, `let`, `save-excursion`, `condition-case`, etc.)

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contributing guide.
