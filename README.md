# flywrite-mode

An Emacs minor mode that provides inline writing suggestions powered by an LLM. Suggestions appear as flymake diagnostics (wavy underlines) with explanations via flymake-popon or the echo area.

**Privacy warning:** Flywrite sends your document text to an LLM API.

![flywrite-mode screenshot](screenshot.png)

## Quick start

Get an Anthropic API key at https://console.anthropic.com/settings/keys and save it to `~/.flywrite-api-key`.

Add credits at https://platform.claude.com/settings/billing — as of Spring 2026, $5 should last months of typical use.

Clone.
```bash
git clone https://github.com/awdeorio/flywrite.git
```

Configure.
```elisp
(use-package flywrite-mode
  :load-path "~/src/flywrite"
  :commands (flywrite-mode)
  :config
  (setq flywrite-api-url "https://api.anthropic.com/v1/messages")
  (setq flywrite-api-key-file "~/.flywrite-api-key"))

(use-package flymake-popon
  :ensure t
  :hook (flymake-mode . flymake-popon-mode))
```

Open a text file and save this content (it contains intentional errors for flywrite to catch):

> The quick brown fox jumpted over the lazy dog. Him and his friend went to the store to buy some grocerys. The weather was very extremely hot outside yesterday.

Run `M-x flywrite-mode`.  Try checking the entire buffer with `M-x flywrite-check-buffer`.  Move the point over one of the wavy underlines.

![flywrite-mode screenshot](screenshot.png)

Now try adding new text.  New sentences are checked after a short delay.

## Configuration

### API providers
Set `flywrite-api-url` to your provider's endpoint. Flywrite natively supports the Anthropic Messages API and the OpenAI Chat Completions API.

**Anthropic**
1. `(setq flywrite-api-url "https://api.anthropic.com/v1/messages")`
2. `(setq flywrite-model "claude-sonnet-4-20250514")` — [model list](https://docs.anthropic.com/en/docs/about-claude/models)
3. Get an API key at https://console.anthropic.com/settings/keys
4. Add credits at https://platform.claude.com/settings/billing

**OpenAI**
1. `(setq flywrite-api-url "https://api.openai.com/v1/chat/completions")`
2. `(setq flywrite-model "gpt-4o")` — [model list](https://platform.openai.com/docs/models)
3. Get an API key at https://platform.openai.com/api-keys
4. Add credits at https://platform.openai.com/settings/organization/billing/overview

**Google Gemini** (OpenAI-compatible endpoint)
1. `(setq flywrite-api-url "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")`
2. `(setq flywrite-model "gemini-2.5-flash")` — [model list](https://ai.google.dev/gemini-api/docs/models)
3. Get an API key at https://aistudio.google.com/apikey
4. Add credits at https://aistudio.google.com/plan_billing

**Ollama** (local, no API key needed)
1. Install Ollama from https://ollama.com and pull a model (e.g., `ollama pull llama3.2`)
2. `(setq flywrite-api-url "http://localhost:11434/v1/chat/completions")`
3. `(setq flywrite-model "llama3.2:3b")` — [model list](https://ollama.com/library), check local names with `ollama list`

Note: Smaller local models may struggle to consistently return valid JSON in the expected format, leading to "LLM returned invalid JSON" messages. Larger models (7B+) tend to be more reliable. Enable `flywrite-debug` and check `*flywrite-log*` to see raw responses.

Anthropic endpoints are auto-detected (by hostname) and use the `x-api-key` header; all other providers use a `Bearer` token in the `Authorization` header. Local providers like Ollama work without an API key.

### API key
Choose one method:
1. Read from a file (recommended): `(setq flywrite-api-key-file "~/.flywrite-api-key")` — use `chmod 600` to restrict access
2. Set directly: `(setq flywrite-api-key "sk-ant-...")`
3. Use `FLYWRITE_API_KEY` environment variable (no config needed)

Omit the API key if it's not needed, e.g., for Ollama.

### Optional settings
Settings with defaults.

```elisp
(setq flywrite-model "claude-sonnet-4-20250514")   ; model
(setq flywrite-idle-delay 1.5)                     ; seconds before checking
(setq flywrite-max-concurrent 3)                   ; max parallel API calls
(setq flywrite-granularity 'sentence)              ; 'sentence or 'paragraph
(setq flywrite-eager t)                            ; eagerly check around point
(setq flywrite-debug t)                            ; log to *flywrite-log*
(setq flywrite-api-headers '(("Custom-Header" . "value")))  ; extra HTTP headers
```

### System prompt

Customize `flywrite-system-prompt` to change tone, strictness, or focus areas. The prompt must instruct the model to return JSON with a `suggestions` array where each element has `quote` and `reason` keys. The default is:

```elisp
(setq flywrite-system-prompt
  "You are a writing assistant. Analyze the sentence for grammar, clarity, and style.
Return JSON only. No text outside the JSON.

If the sentence is fine:
{\"suggestions\": []}

If there are issues:
{\"suggestions\": [{\"quote\": \"exact substring\", \"reason\": \"brief explanation\"}]}

Rules:
- \"quote\" must be an exact substring of the input
- Keep reasons under 12 words
- One entry per distinct issue
- Do not flag correct sentences
- Ignore markup and formatting commands (LaTeX, HTML, Org-mode, etc.) -- only evaluate the prose content")
```

### Popup explanations
For the best experience, install [flymake-popon](https://github.com/akicho8/flymake-popon) to see suggestion explanations as inline popups near the flagged text (included in the [Quick start](#quick-start) config). Without it, suggestions are shown in the echo area when point is on a diagnostic.


## Usage

Enable the mode in any buffer:

```
M-x flywrite-mode
```

As you move or type, flywrite will automatically check sentences after a short idle delay and underline issues with suggestions.

### Commands

| Command                    | Description                      |
|----------------------------|----------------------------------|
| `flywrite-check-buffer`    | Check all sentences in buffer    |
| `flywrite-check-region`    | Check all sentences in region    |
| `flywrite-check-at-point`  | Check sentence at point          |
| `flywrite-clear`           | Clear diagnostics and caches     |
| `flymake-goto-next-error`  | Next diagnostic (flymake built-in) |
| `flymake-goto-prev-error`  | Previous diagnostic (flymake built-in) |

Run any command with `M-x`. No default keybindings are provided — bind them yourself if desired.

## Troubleshooting

**Nothing happens / no underlines appear**
1. Make sure `flywrite-mode` is active: check the mode line for `flywrite`.
2. Enable debug logging with `(setq flywrite-debug t)` and check the `*flywrite-log*` buffer for errors.
3. Verify your API key is set correctly — `M-: (flywrite--get-api-key)` should return your key.
4. Verify your API URL is set — `M-: flywrite-api-url` should return a URL.
5. Try `M-x flywrite-check-buffer` to force a check on existing text.

**Underlines appear but no popup explanation**
Install [flymake-popon](https://github.com/akicho8/flymake-popon) (see [Popup explanations](#popup-explanations)). Without it, move point onto an underlined word and check the echo area at the bottom of the frame.

**API errors in the log**
Check that `flywrite-api-url` matches your provider and that your API key has credits remaining.

## Testing

Run the regression tests:
```bash
./test
```

### Manual end-to-end tests

The `examples/` directory contains files for manual testing in Emacs. Open a file, run `M-x flywrite-mode`, and verify diagnostics appear as expected.

| File | Description |
|------|-------------|
| `test00.txt` | Plain text with spelling, grammar, and style errors |
| `test01.md` | Markdown with multiple paragraphs of errors plus clean prose |
| `test02.tex` | LaTeX document with the same error paragraphs (should ignore markup) |
| `test03.tex` | Long LaTeX exam document with heavy markup, lists, and math (stress test for markup suppression) |
| `test04.tex` | Short LaTeX with an itemize list containing a spelling error |
| `test05.md` | Markdown with headings, blockquotes, a code block, and errors (should skip code blocks) |
| `test06.tex` | Minimal LaTeX exam with a solution block (should handle custom environments) |

## Debugging

Enable debug logging:

```elisp
(setq flywrite-debug t)
```

Then check the `*flywrite-log*` buffer for API calls, responses, latency, and events.
