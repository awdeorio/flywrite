# flywrite

An Emacs minor mode for LLM-powered grammar, style, and academic writing feedback. Suggestions appear as flymake diagnostics with inline explanations. Features a [customizable prompt](#system-prompt) and [flexible API provider](#api-providers) support.

**Privacy warning:** Flywrite sends your document text to an LLM API.

![flywrite-mode screenshot](screenshot.png)

## Quick start

Get an Anthropic API key at https://console.anthropic.com/settings/keys and save it to `~/.flywrite-api-key`.

Add credits at https://platform.claude.com/settings/billing — as of Spring 2026, $5 should last months of typical use.

Add to your init file (Requires [MELPA](https://melpa.org/#/getting-started)):
```elisp
(use-package flywrite
  :ensure t
  :commands (flywrite-mode)
  :config
  (setq flywrite-api-url "https://api.anthropic.com/v1/messages")
  (setq flywrite-api-key-file "~/.flywrite-api-key"))

(use-package flymake-popon
  :ensure t
  :hook (flymake-mode . flymake-popon-mode))
```

Open a text file and save this content with intentional errors:

> The optimization had a significant affect on runtime performance. The benchmarks show the approach is more efficient then brute force search. We feel the results are promising.

Run `M-x flywrite-mode`.  As you move or type, flywrite will automatically run checks after a short idle delay.  API responses may take a few seconds.  Move the point over one of the wavy underlines.

![flywrite-mode screenshot](screenshot.png)


## Configuration

### System prompt
`flywrite-system-prompt` controls the instructions sent with every API call. Select a built-in style or provide a custom string.

- `flywrite-prose-prompt`: grammar, clarity, and style feedback
- `flywrite-academic-prompt`: adds rules for formal academic writing: contractions, hedging, weasel words, etc. (default)

**Per-user prompt:** Set the prompt style in your Emacs config. This applies to all files unless overridden by a per-file or per-directory setting.

```elisp
(setq flywrite-system-prompt 'academic)  ; or 'prose
```

**Custom prompt:** Copy the academic prompt below and modify the rules at the end. Keep the JSON format section unchanged, flywrite needs it to parse responses.  Longer prompts cost more per call.  Anthropic's prompt caching helps, but other providers may not cache. Keep custom prompts concise.

```elisp
(setq flywrite-system-prompt
  "You are a writing assistant. Analyze the text for grammar,
clarity, and style.  Return JSON only. No text outside the JSON.

If the text is fine:
{\"suggestions\": []}

If there are issues:
{\"suggestions\": [{\"quote\": \"exact substring\",
  \"reason\": \"brief explanation\"}]}

Rules:
- \"quote\" must be an exact substring of the input
- Keep reasons under 12 words
- One entry per distinct issue
- Do not flag correct text
- Do not flag spacing between sentences (one or two spaces are
  both acceptable).
- Err on the side of not flagging.  Only flag clear, unambiguous errors.
- Ignore markup like LaTeX, HTML, or Org-mode.
- Flag informal language, contractions, and colloquialisms
- Flag vague hedging
  (e.g., 'a lot', 'thing(s)', 'stuff', 'really')
- Flag unsupported opinions
  (e.g., 'I think X is better') -- state evidence instead
- Flag unsupported superlatives
  (e.g., 'the best', 'the most important')
- Flag wordiness and nominalizations
  (e.g., 'make an adjustment' -> 'adjust')
- Flag subjective qualifiers
  (e.g., 'obviously', 'clearly', 'of course')
- Flag ambiguous 'this/it/they' pronouns without antecedents
  (e.g., 'This is important' -- this what?)
- Flag weasel words (e.g., 'significantly' without statistical
  context, 'often', 'usually' without citation)
- Flag informal transitions (e.g., 'So,', 'Also,', 'Plus')
  -- prefer 'Therefore', 'Additionally', 'Moreover'")
```

**Custom named style:** Register your own named style by adding an entry to `flywrite-prompt-alist`, then select it like a built-in style. Keep the JSON format section unchanged, flywrite needs it to parse responses.

```elisp
(add-to-list 'flywrite-prompt-alist
             '(scifi . "You are a sci-fi writing assistant.
Analyze the text for grammar, clarity, and style.
Return JSON only. No text outside the JSON.

If the text is fine:
{\"suggestions\": []}

If there are issues:
{\"suggestions\": [{\"quote\": \"exact substring\",
  \"reason\": \"brief explanation\"}]}

Rules:
- \"quote\" must be an exact substring of the input
- Keep reasons under 12 words
- One entry per distinct issue
- Do not flag correct text
- Flag inconsistent use of sci-fi terminology
- Flag technobabble that obscures meaning"))
(setq flywrite-system-prompt 'scifi)
```

**Per-file prompt:** Add a file-local variable at the top of a file to override the prompt style for that file only. Emacs will apply it automatically when the file is opened.

| File type | First-line variable |
|-----------|---------------------|
| Plain text | `-*- flywrite-system-prompt: prose -*-` |
| LaTeX | `% -*- flywrite-system-prompt: prose -*-` |
| Org mode | `# -*- flywrite-system-prompt: prose -*-` |
| Markdown | `<!-- -*- flywrite-system-prompt: prose -*- -->` |

**Per-directory prompt:** Create a `.dir-locals.el` file to set the prompt for all files in a directory:

```elisp
((nil . ((flywrite-system-prompt . prose))))
```

### Settings

```elisp
(setq flywrite-idle-delay 1.5)          ; seconds before checking
(setq flywrite-max-concurrent 3)        ; max parallel API calls
(setq flywrite-eager t)                 ; eagerly check around point
(setq flywrite-debug t)                 ; log to *flywrite-log* (on by default)
```

### API providers
Configure an API.  Flywrite natively supports the Anthropic Messages API and the OpenAI Chat Completions API, which includes Google Gemini and Ollama.  The model is optional, by default it is auto-detected from the API URL.

**Security warning:** Restrict access to API key files.
```console
$ chmod 600 ~/.flywrite-api-key
```

**Anthropic**
1. Get an API key at https://console.anthropic.com/settings/keys
2. Add credits at https://platform.claude.com/settings/billing
3. Optionally, select a [model](https://docs.anthropic.com/en/docs/about-claude/models)
4. Configure
   ```elisp
   (setq flywrite-api-url "https://api.anthropic.com/v1/messages")
   (setq flywrite-api-key-file "~/.flywrite-api-key")
   (setq flywrite-api-model "claude-sonnet-4-20250514")  ; default
   ```

**OpenAI**
1. Get an API key at https://platform.openai.com/api-keys
2. Add credits at https://platform.openai.com/settings/organization/billing/overview
3. Optionally, select a [model](https://platform.openai.com/docs/models)
4. Configure
   ```elisp
   (setq flywrite-api-url "https://api.openai.com/v1/chat/completions")
   (setq flywrite-api-key-file "~/.flywrite-api-key")
   (setq flywrite-api-model "gpt-4o")  ; default
   ```

**Google Gemini**
1. Get an API key at https://aistudio.google.com/apikey
2. Add credits at https://aistudio.google.com/plan_billing
3. Optionally, select a [model](https://ai.google.dev/gemini-api/docs/models)
4. Configure
   ```elisp
   (setq flywrite-api-url "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
   (setq flywrite-api-key-file "~/.flywrite-api-key")
   (setq flywrite-api-model "gemini-2.5-flash")  ; default
   ```

**Ollama**
1. Install Ollama from https://ollama.com
2. Select a [model](https://ollama.com/library) and download it
   ```console
   $ ollama pull llama3.2:3b
   $ ollama list
   ```
3. Run server
   ```console
   $ ollama serve
   ```
4. Configure
   ```elisp
   (setq flywrite-api-url "http://localhost:11434/v1/chat/completions")
   ;; No key needed
   (setq flywrite-api-model "llama3.2:3b")
   ```

Note: Smaller models may not consistently return valid JSON in the expected format, leading to "LLM returned invalid JSON" messages. Larger models (7B+) tend to be more reliable. Check `*flywrite-log*` to see raw responses.

**Any API provider**
```elisp
(setq flywrite-api-url "https://api.anthropic.com/v1/messages")
(setq flywrite-api-key-file "~/.flywrite-api-key")
(setq flywrite-api-headers '(("Custom-Header" . "value")))
(setq flywrite-api-model "claude-sonnet-4-20250514")
```

`flywrite-api-headers` adds custom HTTP headers to every request, merged with the default Content-Type and authorization headers.

### API key
Choose one method:
1. Read from a file like `~/.flywrite-api-key` (recommended).  Use `chmod 600` to restrict access.
   ```console
   $ chmod 600 ~/.flywrite-api-key
   ```

   ```elisp
   (setq flywrite-api-key-file "~/.flywrite-api-key")
   ```
2. Set API key directly.
   ```elisp
   (setq flywrite-api-key "sk-ant-...")
   ```
3. Set the `FLYWRITE_API_KEY` environment variable.  No elisp configuration needed.
4. Omit the API key if it's not needed, e.g., for Ollama.

Anthropic endpoints are auto-detected by hostname and use the `x-api-key` header; all other providers use a `Bearer` token in the `Authorization` header. Local providers like Ollama work without an API key.

### Diagnostic appearance
Flywrite uses its own faces for underlines and popup/echo text, independent of flymake's built-in note/warning/error faces.

Customize underline color or style (default shown):
```elisp
(set-face-attribute 'flywrite-diagnostic nil
                    :underline '(:style wave :color "deep sky blue"))
```

Customize popup and echo area text color (default shown):
```elisp
(set-face-attribute 'flywrite-diagnostic-echo nil
                    :foreground "steel blue")
```

Or use the interactive picker:
```
M-x customize-face RET flywrite-diagnostic RET
M-x customize-face RET flywrite-diagnostic-echo RET
```

Both faces are in the `flywrite` customization group (`M-x customize-group RET flywrite`). Run `M-x list-colors-display` in Emacs to see all available color names.

### Popup explanations
For the best experience, install [flymake-popon](https://github.com/akicho8/flymake-popon) to see suggestion explanations as inline popups near the flagged text (included in the [Quick start](#quick-start) config). Without it, suggestions are shown in the echo area when point is on a diagnostic.

## Usage

Enable the mode in any buffer:

```
M-x flywrite-mode
```

As you move or type, flywrite will automatically run checks after a short idle delay and underline issues with suggestions.

### Commands

| Command                    | Description                      |
|----------------------------|----------------------------------|
| `flywrite-check-buffer`    | Check all paragraphs in buffer   |
| `flywrite-check-region`    | Check all paragraphs in region   |
| `flywrite-check-at-point`  | Check paragraph at point         |
| `flywrite-set-prompt`      | Pick a prompt style interactively |
| `flywrite-clear`           | Clear diagnostics and caches     |
| `flymake-goto-next-error`  | Next diagnostic (flymake built-in) |
| `flymake-goto-prev-error`  | Previous diagnostic (flymake built-in) |

A `paragraph` is the unit of text sent to the LLM for checking.

## Troubleshooting

**Check the logs**
Check *flywrite-log* for API calls, responses, and events.

**Config validation error on startup**
Flywrite validates API configuration on enable. If you see an error like "Set flywrite-api-url" or "API key is not set", see [API providers](#api-providers) for setup instructions.

**Nothing happens / no underlines appear**
1. Make sure `flywrite-mode` is active: check the mode line for `flywrite`.
2. Check the `*flywrite-log*` buffer for errors.
3. Verify your API key is set correctly — `M-: (flywrite--get-api-key)` should return your key.
4. Verify your API URL is set — `M-: flywrite-api-url` should return a URL.
5. Try `M-x flywrite-check-buffer` to force a check on existing text.

**Underlines appear but no popup explanation**
Install [flymake-popon](https://github.com/akicho8/flymake-popon) (see [Popup explanations](#popup-explanations)). Without it, move point onto an underlined word and check the echo area at the bottom of the frame.

**API errors in the log**
Check that `flywrite-api-url` matches your provider and that your API key has credits remaining.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing, 
and code style.
