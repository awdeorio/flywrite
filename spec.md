# flywrite-mode — Design Plan

An Emacs minor mode that provides inline writing suggestions powered by an LLM API.  Suggestions are surfaced as flymake diagnostics: wavy underlines with explanations via flymake-popon or the echo area.

---

## Goals

- Feel like Flyspell but built on flymake: unobtrusive, automatic, always-on
- Surface grammar, clarity, and style issues at the sentence level (paragraph granularity also available)
- Keep API costs predictable and low
- Remain correct under fast editing (no stale overlays, no duplicate calls)

---

## Architecture Overview

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

---

## Component Breakdown

### 1. Change Detection (`after-change-functions`)

Fires on every buffer modification. Responsibilities:

- Locate the unit containing the changed region: by default, the sentence (using `forward-sentence` / `backward-sentence`); when `flywrite-granularity` is `paragraph`, use `forward-paragraph` / `backward-paragraph` instead
- Compute the sentence's MD5 hash
- If the hash matches the last-checked hash for that span, **do nothing** (deduplication — see §4)
- Otherwise, mark the sentence as dirty: add `(beg end hash)` to the dirty registry
- Trigger a flymake re-check so stale diagnostics for the edited region are cleared

Edge cases to handle:

- Change that spans a sentence boundary: mark both affected sentences dirty
- Change inside a code block or comment: skip (mode-aware suppression, see §7)
- Rapid successive changes to the same sentence: the dirty registry entry is simply overwritten; no duplicate entries accumulate

---

### 2. Dirty Sentence Registry

A buffer-local list of `(beg end hash)` triples representing sentences that need checking.

Rules:

- Entries are deduplicated by span: if a sentence is re-dirtied before its check fires, the old entry is replaced, not appended
- The registry is consumed (cleared) atomically when the idle timer fires, so a long burst of edits results in exactly one API call per unique dirty sentence, not N calls

---

### 3. Idle Timer

A repeating idle timer, default delay **1.5 seconds**, started when the mode is enabled and cancelled on disable.

On each fire:

1. Snapshot and clear the dirty registry
2. For each entry, check the concurrent call cap (see §5)
3. If under cap, dispatch an API call immediately
4. If at cap, push the entry onto a **pending queue** to be dispatched as in-flight calls complete

The timer only does work when there are dirty sentences; it is cheap when the buffer is idle.

---

### 4. Sentence Content Deduplication

The core mechanism for avoiding redundant API calls.

Each sentence that has been successfully checked is stored in a buffer-local hash table:

```
checked-sentences: { (beg . end) → content-hash }
```

Before dispatching a call, compare the current content hash of the sentence with the stored hash:

- **Hash matches**: sentence has not changed since last check — skip the API call entirely
- **Hash differs** (or absent): sentence is new or modified — proceed with the call and update the stored hash on successful response

This means that if the user types and then immediately deletes a character, restoring the original text, **no API call is made**. The hash check is O(1) and happens synchronously before any network activity.

The hash table must be invalidated (entry removed) whenever a sentence is marked dirty, so that a later re-check after edits always gets a fresh result.

---

### 5. Concurrent Call Cap

A buffer-local counter tracking the number of in-flight API requests.

- Hard cap: **3 concurrent requests** (configurable via `flywrite-max-concurrent`)
- When a call is dispatched, increment the counter
- When a response is received (success or error), decrement the counter and attempt to drain the pending queue
- The pending queue is a FIFO list of `(buf beg end hash)` entries waiting for a slot

This prevents a large buffer check or a burst of edits from flooding the API with dozens of simultaneous requests, which would cause unpredictable latency and cost spikes.

---

### 6. API Call

Each request targets a single sentence. The call is made asynchronously via `url-retrieve`.

**Endpoint:** configurable via `flywrite-api-url`

**Request structure:**

- Model: `claude-sonnet-4-20250514` (configurable)
- Max tokens: 300 (sufficient for 1–2 suggestions)
- System prompt: cacheable static instructions (see §6a)
- User message: the sentence text only

#### 6a. Prompt Design

The system prompt is fixed across all calls and is a candidate for prompt caching (see §9).

```
You are a writing assistant. Analyze the sentence for grammar, clarity, and style.
Return JSON only. No text outside the JSON.

If the sentence is fine:
{"suggestions": []}

If there are issues:
{"suggestions": [{"quote": "exact substring", "reason": "brief explanation"}]}

Rules:
- "quote" must be an exact substring of the input
- Keep reasons under 12 words
- One entry per distinct issue
- Do not flag correct sentences
```

The user message contains only the sentence, with no additional framing.

#### 6b. Stale Response Guard

Each dispatched call is tagged with the content hash at the time of dispatch. In the response handler, recompute the hash of the buffer region. If the hashes differ (the user edited the sentence while the call was in-flight), **discard the response silently** and re-add the sentence to the dirty registry.

---

### 7. Response Handler

Called asynchronously when `url-retrieve` completes.

Steps:

1. Check HTTP status; on error, log to `*flywrite-log*` and decrement the in-flight counter
2. Parse the response body as JSON
3. Perform the stale hash check (§6b); discard if stale
4. For each suggestion:
   - Search for `quote` as a literal substring within the sentence's buffer region
   - If found, build a `flymake-make-diagnostic` with `:type :note`, region `(beg + match-start)` to `(beg + match-end)`, and the reason as the message
   - If not found (model hallucinated a non-existent substring), skip silently
5. Accumulate diagnostics into a buffer-local list and call the flymake report function (see §8) to deliver them
6. Update `checked-sentences` hash table with the current content hash
7. Decrement the in-flight counter and drain the pending queue

---

### 8. Flymake Integration

flywrite-mode registers itself as a flymake diagnostic backend via `flymake-diagnostic-functions`.

**Backend function:** `flywrite-flymake` receives a report function from flymake. The mode stores this function buffer-locally and calls it whenever new diagnostics are available (from §7) or when diagnostics for an edited region should be cleared.

**Diagnostic properties:**

- **Type:** `:note` — lowest severity, appropriate for writing suggestions
- **Region:** the matched `quote` substring within the buffer
- **Message:** the reason string from the API response

**How diagnostics are displayed:**

- **flymake-popon** (if installed): shows the reason as an inline popup near the flagged text — the primary intended UX
- **Echo area:** flymake's built-in display shows the reason when point is on a diagnostic
- **`flymake-goto-next-error` / `flymake-goto-prev-error`:** standard navigation between suggestions

**Lifecycle:**

- The mode enables `flymake-mode` in the buffer if not already active
- Diagnostics are reported incrementally as API responses arrive; each report replaces the previous set for the buffer
- When the mode is disabled, the backend is removed from `flymake-diagnostic-functions` and existing diagnostics are cleared

**Face customization:** To change the underline style, customize `flymake-note` (or the more specific `flymake-popon-note` if using flymake-popon). Recommended: `(:underline (:style wave :color "deep sky blue"))`.

---

### 9. Prompt Caching

The system prompt (~100 tokens) is identical on every call. Adding a `cache_control` block marks it for server-side caching, reducing input token cost by ~90% on cache hits.

Implementation: add `"cache_control": {"type": "ephemeral"}` to the system message in the request payload. No other changes required.

At 30% cache miss rate (new sessions, cache expiry), effective input cost drops from $3.00/MTok to approximately **$1.80/MTok** on the system prompt portion.

---

### 10. Interactive Commands

| Command | Binding | Description |
|---|---|---|
| `flywrite-mode` | — | Toggle the mode on/off |
| `flywrite-check-buffer` | `C-c C-g b` | Queue all sentences in the buffer; prompts for confirmation when the call count exceeds `flywrite-check-confirm-threshold` |
| `flywrite-check-paragraph` | `C-c C-g p` | Queue all sentences in current paragraph |
| `flywrite-clear` | `C-c C-g c` | Clear all flywrite diagnostics and reset checked-sentences cache |
| `flymake-goto-next-error` | `M-n` (default) | Navigate to next diagnostic (built-in) |
| `flymake-goto-prev-error` | `M-p` (default) | Navigate to previous diagnostic (built-in) |

---

### 11. Configuration Variables

| Variable | Default | Description |
|---|---|---|
| `flywrite-api-key` | `nil` | API key (falls back to `FLYWRITE_API_KEY` env var) |
| `flywrite-model` | `"claude-sonnet-4-20250514"` | Model to use |
| `flywrite-idle-delay` | `1.5` | Seconds of idle before checking dirty sentences |
| `flywrite-max-concurrent` | `3` | Max simultaneous in-flight API calls |
| `flywrite-enable-caching` | `t` | Whether to send `cache_control` on the system prompt |
| `flymake-note` face | `(:underline (:style wave :color "deep sky blue"))` | Customize this standard flymake face to control underline styling |
| `flywrite-granularity` | `'sentence` | Unit of text to check: `sentence` or `paragraph` |
| `flywrite-check-confirm-threshold` | `50` | Prompt for confirmation when `check-buffer` would make more than this many API calls |
| `flywrite-long-sentence-threshold` | `500` | Max characters per unit; longer units are passed through without truncation or splitting |
| `flywrite-skip-modes` | `'(prog-mode)` | Major modes where checking is suppressed |
| `flywrite-debug` | `nil` | When non-nil, log API calls, responses, and events to `*flywrite-log*` |

---

### 12. Mode-Aware Suppression

Checking should be skipped for regions that are not prose:

- **In `org-mode`:** skip src blocks, drawer contents, property lines, timestamps
- **In `latex-mode` / `LaTeX-mode`:** skip command arguments, math environments, verbatim blocks
- **In `markdown-mode`:** skip fenced code blocks, inline code spans
- **General:** skip comment regions in any programming-derived mode

Detection uses `text-property-at-pos` and font-lock face inspection — if the face at the sentence start is `font-lock-comment-face`, `font-lock-string-face`, or similar, the sentence is skipped.

---

### 13. Logging

A `*flywrite-log*` buffer records:

- Each API call: timestamp, sentence text (truncated), request hash
- Each response: latency, suggestion count, any parse errors
- Stale discards and cap-blocked events

Logging is off by default (`flywrite-debug nil`). When enabled it is invaluable for tuning the idle delay and cap values.

---

## Cost Model Summary

| Scenario | Checks/day | Approx. daily cost (Sonnet) |
|---|---|---|
| Light writing, 30 min | ~40 | ~$0.03 |
| Moderate editing, 1 hr | ~150 | ~$0.11 |
| Heavy daily use, 3–4 hrs | ~500 | ~$0.35 |

With prompt caching active, reduce these figures by roughly 40%. Monthly cost for heavy daily use: **~$6**.

Haiku 4.5 ($1/$5 per MTok) is an available alternative at ~3× lower cost, with reduced quality on stylistic suggestions.



