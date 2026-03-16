# flywrite-mode

An Emacs minor mode that provides inline writing suggestions powered by the Anthropic LLM API. Suggestions appear as flymake diagnostics (wavy underlines) with explanations via flymake-popon or the echo area.

## Requirements

- Emacs 27.1+
- Anthropic API key

No external Emacs packages are required — flywrite uses only built-in libraries (`url`, `json`, `flymake`, `md5`).

## Installation

### Development install

```bash
git clone https://github.com/awdeorio/flywrite.git
```

Add to your Emacs config:

```elisp
(add-to-list 'load-path "/path/to/flywrite")
(require 'flywrite-mode)
```

### use-package (local path)

```elisp
(use-package flywrite-mode
  :load-path "/path/to/flywrite"

  ;; Optional: enable automatically for writing modes
  :hook ((text-mode latex-mode LaTeX-mode markdown-mode org-mode) . turn-on-flywrite-mode)

  ;; Set API key (choose one method):
  :config
  ;; 1. Set directly:
  ;; (setq flywrite-api-key "sk-ant-...")
  ;; 2. Read from a file:
  ;; (setq flywrite-api-key-file "~/.config/anthropic/api-key")
  ;; 3. Use ANTHROPIC_API_KEY environment variable (no config needed)
  )
```

For Claude:
1. Get an API key at https://console.anthropic.com/settings/keys
2. Store it in ~/.anthropic_api_key or set the environment variable:
   export ANTHROPIC_API_KEY=sk-ant-...
3. Add credits https://platform.claude.com/settings/billing


## Configuration

Optional settings:

```elisp
(setq flywrite-model "claude-sonnet-4-20250514")  ; default model
(setq flywrite-idle-delay 1.5)                     ; seconds before checking
(setq flywrite-max-concurrent 3)                   ; max parallel API calls
(setq flywrite-granularity 'sentence)              ; 'sentence or 'paragraph
(setq flywrite-debug t)                            ; enable logging to *flywrite-log*
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

### Recommended: flymake-popon

For the best experience, install [flymake-popon](https://github.com/akicho8/flymake-popon) to see suggestion explanations as inline popups near the flagged text. Without it, suggestions are shown in the echo area when point is on a diagnostic.

## Debugging

Enable debug logging:

```elisp
(setq flywrite-debug t)
```

Then check the `*flywrite-log*` buffer for API calls, responses, latency, and events.
