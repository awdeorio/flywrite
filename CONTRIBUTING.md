# Contributing

Please open an issue to discuss your idea before submitting a pull
request.

## Development install

Clone.
```bash
git clone https://github.com/awdeorio/flywrite.git ~/src/flywrite
```

Configure.
```elisp
(use-package flywrite-mode
  :load-path "/path/to/flywrite-mode.el"
  :commands (flywrite-mode)
  :config
  (setq flywrite-api-url "https://api.anthropic.com/v1/messages")
  (setq flywrite-api-key-file "~/.flywrite-api-key"))

(use-package flymake-popon
  :ensure t
  :hook (flymake-mode . flymake-popon-mode))
```

Requirements: Emacs 27.1+, an LLM API key (see
[README](README.md) for provider setup). API key is optional for local
providers like Ollama.

**Testing with Emacs 27 on macOS.** CI runs tests against Emacs 27.1.
To reproduce locally on macOS, install Emacs 27 via Homebrew:
```bash
brew install emacs-plus@27
/opt/homebrew/opt/emacs-plus@27/bin/emacs -Q --batch \
  -l flywrite-mode.el -l test-flywrite.el \
  -f ert-run-tests-batch-and-exit
```

The entire package lives in `flywrite-mode.el`. Unit tests are in
`test-flywrite.el`. Prompt regression tests are in
`test-flywrite-prompt.el`. Sample files in `samples/` are for manual
end-to-end testing.

## Testing

Run the full regression suite:
```bash
./test
```

The `./test` script runs these checks:
1. **Byte-compile** with warnings-as-errors
2. **checkdoc** -- docstring style
3. **elint** -- Emacs Lisp lint
4. **elisp-lint** -- installed from MELPA on first run
5. **Nesting depth** -- custom `lint-nesting.el`, max depth of 6
6. **ERT unit tests** -- `test-flywrite.el`
7. **Prompt regression tests** -- `test-flywrite-prompt.el`

### Prompt regression tests

`test-flywrite-prompt.el` sends text samples to a real LLM API and
verifies that every prompt style in `flywrite--prompt-alist` catches
(or does not flag) specific writing flaws.

**API key setup.** Prompt regression tests require the
`FLYWRITE_API_KEY_ANTHROPIC` environment variable.  One option is to set it in
a `.env` file which is git-ignored.

```bash
# .env
export FLYWRITE_API_KEY_ANTHROPIC=FIXME
```

```bash
source .env
./test
```

**Cache.** Results are cached in `test-flywrite-prompt-cache.json` to
avoid redundant API calls. The cache key includes the input text,
model, temperature, and prompt hash, so entries are automatically
invalidated when a system prompt changes.  Stale entries are pruned on
each run.  Do not edit the cache file manually -- it is managed by the
test runner.

Byte-compile standalone:
```bash
emacs -Q --batch \
  --eval "(setq byte-compile-error-on-warn t)" \
  -f batch-byte-compile flywrite-mode.el \
  && rm -f flywrite-mode.elc
```

Run a single ERT test by name:
```bash
emacs -Q --batch -l flywrite-mode.el -l test-flywrite.el \
  --eval '(ert-run-tests-batch-and-exit "flywrite-test-NAME")'
```

Manual end-to-end testing: open a file in `samples/`, run
`M-x flywrite-mode`, and verify diagnostics appear as expected.
See [`samples/README.md`](samples/README.md) for file descriptions.

## Code style

- 80-character line width
- Logical nesting depth: prefer 4--5 levels, hard limit of 6
  (enforced by `lint-nesting.el`)
- Package prefix: `flywrite-` (public), `flywrite--` (internal)
- All state is buffer-local
- Async HTTP via `url-retrieve` (no external dependencies)
- Diagnostics tagged with `[flywrite]` suffix
- Two newlines between functions


## Documentation

- Default values shown in the README (including the system prompt)
  must match the source code in `flywrite-mode.el`. When changing
  defaults, update both.
- When adding, removing, or renaming files in `samples/`, update the
  table in `samples/README.md` to match.

## Architecture

```
Buffer edits
    |
    v
after-change-functions
    |  marks unit dirty
    v
Dirty unit registry  <---- content deduplication (hash check)
    |
    |  idle timer fires (1.5s)
    v
Request queue
    |  concurrent call cap (max 3 in-flight)
    v
LLM API  (url-retrieve, async)
    |
    v
Response handler
    |  stale check (hash comparison)
    v
Flymake report  ->  diagnostics (:note severity)
    |
    v
flymake-popon / echo area  ->  inline popups near flagged text
```

Key design decisions:
- **Unit granularity**: a "unit" is the text sent per API call -- one
  sentence or one paragraph, controlled by `flywrite-granularity`
  (sentence by default)
- **Content deduplication**: MD5 hashing prevents redundant API calls;
  checked hashes stored in `flywrite--checked-units` hash table
- **Stale response guard**: responses discarded if unit changed while
  call was in-flight, then re-dirtied for re-check
- **Flymake backend**: `flywrite-flymake` registered in
  `flymake-diagnostic-functions`; handles eglot coexistence by
  re-adding itself via `eglot-managed-mode-hook`
- **Prompt caching**: system prompt uses `cache_control` with
  `"type": "ephemeral"` for cost reduction
- **Mode-aware suppression**: skips code blocks, comments, and other
  non-prose regions via font-lock face inspection
- **Multi-provider support**: Anthropic endpoints are auto-detected
  (use `x-api-key` header); all others use `Bearer` token in
  `Authorization` header

## AI policy

AI-assisted contributions are welcome. Contributors should review and understand all AI-generated code before submitting. Fully automated submissions (bots, unreviewed AI output) are not accepted.

## Release procedure

1. Update the `Version` header in `flywrite-mode.el`
   (`;; Version: X.Y.Z`)
2. Commit and push to `main`
3. Tag the release: `git tag vX.Y.Z && git push --tags`
4. Draft a new release on GitHub at
   https://github.com/awdeorio/flywrite/tags
