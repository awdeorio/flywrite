# flywrite-mode

An Emacs minor mode that provides inline writing suggestions powered by an LLM. Suggestions appear as flymake diagnostics (wavy underlines) with explanations via flymake-popon or the echo area.

## Privacy warning

Flywrite sends the text you are editing to an LLM API for analysis. Do not use flywrite-mode when editing files that contain sensitive or confidential information.

## Installation

Requirements:
- Emacs 27.1+
- LLM API key

No external Emacs packages are required — flywrite uses only built-in libraries (`url`, `json`, `flymake`, `md5`).

Clone
```bash
git clone https://github.com/awdeorio/flywrite.git
```

Configure with use-package
```elisp
(use-package flywrite-mode
  :load-path "/path/to/flywrite"

  ;; Important for those who use (setq use-package-always-defer t)
  :commands (flywrite-mode)

  ;; Optional: enable automatically for writing modes
  ;; :hook (text-mode . flywrite-mode)

  :config
  ;; API endpoint (required):
  (setq flywrite-api-url "https://api.anthropic.com/v1/messages")

  ;; API key (choose one method):
  ;; 1. Set directly:
  ;; (setq flywrite-api-key "sk-ant-...")
  ;; 2. Read from a file:
  ;; (setq flywrite-api-key-file "~/.anthropic_api_key")
  ;; 3. Use FLYWRITE_API_KEY environment variable (no config needed)
  )
```

### API providers

Set `flywrite-api-url` to point to a Messages API-compatible endpoint, then configure an API key (`flywrite-api-key` or `flywrite-api-key-file` or `FLYWRITE_API_KEY` environment variable).  By default, the key is sent as a `Bearer` token in the `Authorization` header.  Use `flywrite-api-headers` for provider-specific headers.

**Anthropic**
1. `(setq flywrite-api-url "https://api.anthropic.com/v1/messages")`
2. `(setq flywrite-api-headers '(("x-api-key" . "YOUR-KEY") ("anthropic-version" . "2023-06-01")))`
3. Get an API key at https://console.anthropic.com/settings/keys
4. Add credits at https://platform.claude.com/settings/billing

**OpenAI**
1. `(setq flywrite-api-url "https://api.openai.com/v1/messages")`
2. Get an API key at https://platform.openai.com/api-keys
3. Add credits at https://platform.openai.com/settings/organization/billing/overview

**Google Gemini**
1. `(setq flywrite-api-url "https://generativelanguage.googleapis.com/v1/messages")`
2. Get an API key at https://aistudio.google.com/apikey
3. Add credits at https://aistudio.google.com/plan_billing

## Popup explanations
For the best experience, install [flymake-popon](https://github.com/akicho8/flymake-popon) to see suggestion explanations as inline popups near the flagged text. Without it, suggestions are shown in the echo area when point is on a diagnostic.

```elisp
(use-package flymake-popon
  :ensure t
  :hook (flymake-mode . flymake-popon-mode))
```

## Configuration

Optional settings:

```elisp
(setq flywrite-model "claude-sonnet-4-20250514")   ; default model
(setq flywrite-idle-delay 1.5)                     ; seconds before checking
(setq flywrite-max-concurrent 3)                   ; max parallel API calls
(setq flywrite-granularity 'sentence)              ; 'sentence or 'paragraph
(setq flywrite-debug t)                            ; log to *flywrite-log*
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
- Do not flag correct sentences")
```

## Usage

Enable the mode in any buffer:

```
M-x flywrite-mode
```

As you type, flywrite will automatically check sentences after a short idle delay and underline issues with suggestions.

### Key bindings

| Binding     | Command                    | Description                      |
|-------------|----------------------------|----------------------------------|
| `C-c C-g b` | `flywrite-check-buffer`    | Check all sentences in buffer    |
| `C-c C-g p` | `flywrite-check-paragraph` | Check sentences in paragraph     |
| `C-c C-g c` | `flywrite-clear`           | Clear diagnostics and caches     |
| `M-n`       | `flymake-goto-next-error`  | Next diagnostic (flymake built-in) |
| `M-p`       | `flymake-goto-prev-error`  | Previous diagnostic (flymake built-in) |

## Debugging

Enable debug logging:

```elisp
(setq flywrite-debug t)
```

Then check the `*flywrite-log*` buffer for API calls, responses, latency, and events.
