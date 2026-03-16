# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

flywrite-mode is an Emacs minor mode that provides inline writing suggestions powered by the Anthropic LLM API. Suggestions appear as flymake diagnostics (wavy underlines) with explanations via flymake-popon or the echo area. The UX goal is unobtrusive, always-on feedback (like Flyspell but for style/clarity, and built on flymake rather than flyspell).

## Status

The project is in the design/planning phase. `plan.md` contains the full architecture specification. No Elisp code has been written yet.

## Architecture

The pipeline follows this flow: buffer edits → change detection → dirty sentence registry → idle timer (1.5s) → request queue (max 3 concurrent) → async LLM API call (`url-retrieve`) → response handler (with stale-check) → flymake diagnostics.

Key design decisions:
- **Sentence-level granularity** by default (paragraph also supported via `flywrite-granularity`)
- **Content deduplication** via MD5 hashing prevents redundant API calls
- **Stale response guard**: responses are discarded if the sentence changed while the call was in-flight
- **Flymake backend**: integrates as a standard `flymake-diagnostic-functions` entry using `:note` severity
- **Prompt caching**: system prompt uses `cache_control` for cost reduction
- **API**: Anthropic Messages API (`/v1/messages`), model defaults to `claude-sonnet-4-20250514`

## Emacs Lisp Conventions

- Use `url-retrieve` for async HTTP (no external dependencies)
- All state is buffer-local (dirty registry, checked-sentences hash table, in-flight counter, pending queue)
- The package prefix is `flywrite-`
- Key bindings use the `C-c C-g` prefix
