;;; flywrite-mode.el --- Inline writing suggestions via LLM -*- lexical-binding: t; indent-tabs-mode: nil; fill-column: 80; -*-

;; Copyright (C) 2026 Andrew DeOrio

;; Author: Andrew DeOrio <awdeorio@umich.edu>
;; Maintainer: Andrew DeOrio <awdeorio@umich.edu>
;; Version: 0.1.1
;; Package-Requires: ((emacs "27.1"))
;; Keywords: text, wp
;; URL: https://github.com/awdeorio/flywrite

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; flywrite-mode is a minor mode that provides inline writing suggestions
;; powered by an LLM API.  Suggestions appear as flymake
;; diagnostics (wavy underlines) with explanations via flymake-popon or
;; the echo area.  The UX goal is unobtrusive, always-on feedback — like
;; Flyspell but for style and clarity, built on flymake.

;;; Code:

(require 'cl-lib)
(require 'flymake)
(require 'json)
(require 'url)
(require 'url-http)

;;;; ---- Faces ----


(defface flywrite-diagnostic
  '((t :underline (:style wave :color "deep sky blue")))
  "Face for flywrite diagnostic underlines.
Customize this to change the color or style of flywrite suggestions."
  :group 'flywrite)


(defface flywrite-diagnostic-echo
  '((t :foreground "medium blue"))
  "Face for flywrite diagnostic messages in popups and the echo area."
  :group 'flywrite)


;;;; ---- Flymake diagnostic type ----


(put 'flywrite-diagnostic-type 'flymake-category 'flymake-note)
(put 'flywrite-diagnostic-type 'flymake-overlay-control
     '((face . flywrite-diagnostic)))
(put 'flywrite-diagnostic-type 'echo-face 'flywrite-diagnostic-echo)
(put 'flywrite-diagnostic-type 'mode-line-face 'flywrite-diagnostic-echo)


;;;; ---- Customization group & variables ----


(defgroup flywrite nil
  "Inline writing suggestions via LLM."
  :group 'tools
  :prefix "flywrite-")


(defcustom flywrite-api-key nil
  "API key for the LLM provider.
Falls back to `flywrite-api-key-file', then the FLYWRITE_API_KEY
environment variable."
  :type '(choice (const :tag "Use file or env var" nil)
                 (string :tag "API key"))
  :group 'flywrite)


(defcustom flywrite-api-key-file nil
  "Path to a file containing the LLM API key.
The file should contain the key on its first line.  Leading and
trailing whitespace is stripped.  Checked when `flywrite-api-key'
is nil, before falling back to the FLYWRITE_API_KEY env var."
  :type '(choice (const :tag "None" nil)
                 (file :tag "Key file path"))
  :group 'flywrite)


(defcustom flywrite-api-model nil
  "Model to use for writing suggestions.
When nil, the model is auto-detected from `flywrite-api-url'."
  :type '(choice (const :tag "Auto-detect from URL" nil)
                 (string :tag "Model name"))
  :group 'flywrite)


(defcustom flywrite-idle-delay 1.5
  "Seconds of idle time before checking dirty paragraphs."
  :type 'number
  :group 'flywrite)


(defcustom flywrite-max-concurrent 3
  "Maximum number of simultaneous in-flight API calls."
  :type 'integer
  :group 'flywrite)


(defcustom flywrite-enable-caching t
  "Whether to send cache_control on the system prompt."
  :type 'boolean
  :group 'flywrite)


(defcustom flywrite-check-confirm-threshold 50
  "Max API calls before `flywrite-check-buffer' prompts for confirmation."
  :type 'integer
  :group 'flywrite)


(defcustom flywrite-long-paragraph-threshold 500
  "Max characters per paragraph.
Longer paragraphs are passed through without truncation or splitting."
  :type 'integer
  :group 'flywrite)


(defcustom flywrite-skip-modes '(prog-mode)
  "Major modes where checking is suppressed."
  :type '(repeat symbol)
  :group 'flywrite)


(defcustom flywrite-api-temperature 0
  "Temperature for LLM API calls.
Lower values produce more deterministic, consistent suggestions.
A value of 0 minimizes randomness, which is ideal for a writing
checker where reproducibility matters."
  :type 'number
  :group 'flywrite)


(defcustom flywrite-api-headers nil
  "Extra HTTP headers to include in API requests.
An alist of (HEADER-NAME . VALUE) pairs.  These are merged with
the default Content-Type and Authorization headers.

Example for Anthropic:
  \\='((\"x-api-key\" . \"sk-ant-...\")
    (\"anthropic-version\" . \"2023-06-01\"))"
  :type '(alist :key-type string :value-type string)
  :group 'flywrite)


(defcustom flywrite-eager t
  "When non-nil, also check the paragraph at point after each idle delay.
This allows reviewing existing text by moving the cursor through it,
without needing to edit."
  :type 'boolean
  :group 'flywrite)


(defcustom flywrite-debug t
  "When non-nil, log API calls, responses, and events to `*flywrite-log*'."
  :type 'boolean
  :group 'flywrite)


;; Forward-declare the minor-mode variable (defined by define-minor-mode
;; below) so the byte compiler doesn't warn about a free variable.
(defvar flywrite-mode)

;;;; ---- Buffer-local state ----


(defvar-local flywrite--dirty-registry nil
  "List of (beg end hash) triples for paragraphs needing a check.")


(defvar-local flywrite--checked-paragraphs (make-hash-table :test 'equal)
  "Hash table mapping content-hash -> t for already-checked paragraphs.")


(defvar-local flywrite--in-flight 0
  "Counter of in-flight API requests.")


(defvar-local flywrite--pending-queue nil
  "FIFO list of (buf beg end hash) entries waiting for an API slot.")


(defvar-local flywrite--connection-buffers nil
  "List of active `url-retrieve' response buffers for cleanup.")


(defvar-local flywrite--idle-timer nil
  "The idle timer object for this buffer.")


(defvar-local flywrite--report-fn nil
  "The flymake report function, stored when the backend is invoked.")


(defvar-local flywrite--diagnostics nil
  "List of active flymake diagnostics.")


(defvar-local flywrite--region-hashes (make-hash-table :test 'equal)
  "Map from \"beg-end\" region key to the last-known content hash.
Used by `after-change' to find and remove stale checked-paragraph entries.")


(defvar flywrite--response-handled nil
  "Non-nil when a `url-retrieve' callback has already been processed.
Set buffer-locally in HTTP response buffers to guard against
duplicate callbacks.")


;;;; ---- Constants ----


(defcustom flywrite-api-url nil
  "LLM API endpoint URL.
If nil, `flywrite-mode' will display an error asking you to
configure it.  See the README for details."
  :type '(choice (const :tag "Not set" nil)
                 (string :tag "URL"))
  :group 'flywrite)


(defconst flywrite--default-model-anthropic "claude-sonnet-4-20250514"
  "Default model for Anthropic API.")

(defconst flywrite--default-model-openai "gpt-4o"
  "Default model for OpenAI and OpenAI-compatible APIs.")

(defconst flywrite--default-model-gemini "gemini-2.5-flash"
  "Default model for Google Gemini API.")


;; System prompt for general prose writing feedback.
(defconst flywrite--prose-prompt
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
- Focus on objective errors: misspellings, wrong words
  (e.g., affect/effect, there/their), subject-verb disagreement,
  pronoun case, missing or wrong punctuation, and redundant words.
- Do not flag style preferences or debatable grammar rules
  (e.g., comma before 'which', comma after introductory phrase,
  'like' vs 'such as', split infinitives, ending sentences
  with prepositions).  When a comma is optional, do not flag it.
- Err on the side of not flagging.  Only flag clear, unambiguous errors.
- Ignore markup like LaTeX, HTML, or Org-mode.")


;; System prompt for academic writing feedback.
(defconst flywrite--academic-prompt
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
- Ignore markup like LaTeX, HTML, or Org-mode.
- Flag informal language, contractions, and colloquialisms
- Flag vague hedging
  (e.g., 'a lot', 'things', 'stuff', 'really')
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


(defconst flywrite--prompt-alist
  `((prose . ,flywrite--prose-prompt)
    (academic . ,flywrite--academic-prompt))
  "Alist mapping prompt style symbols to prompt strings.")


(defcustom flywrite-system-prompt 'academic
  "System prompt sent with every API call.
Can be a symbol selecting a built-in prompt style or a custom
string.  Built-in styles: `prose' (general writing feedback)
and `academic' (adds rules for formal academic writing).

The prompt must instruct the model to return JSON with a
\"suggestions\" array.  Each element needs \"quote\" and \"reason\"
keys.  Customize this to change tone, strictness, or focus areas
while preserving the JSON output format."
  :type '(choice (const :tag "Prose" prose)
                 (const :tag "Academic" academic)
                 (string :tag "Custom prompt"))
  :group 'flywrite)

;;;###autoload
(put 'flywrite-system-prompt 'safe-local-variable
     (lambda (v) (memq v '(prose academic))))


(defun flywrite--get-system-prompt ()
  "Return the system prompt string.
If `flywrite-system-prompt' is a string, return it as-is.
If it is a symbol, look it up in `flywrite--prompt-alist'."
  (cond
   ((stringp flywrite-system-prompt) flywrite-system-prompt)
   ((symbolp flywrite-system-prompt)
    (let ((entry (assq flywrite-system-prompt flywrite--prompt-alist)))
      (unless entry
        (error "Unknown flywrite-system-prompt style: %s"
               flywrite-system-prompt))
      (cdr entry)))
   (t (error "Bad flywrite-system-prompt type: %S"
             flywrite-system-prompt))))


;;;; ---- Logging ----


(defun flywrite--log (format-string &rest args)
  "Log to `*flywrite-log*' when `flywrite-debug' is non-nil.
FORMAT-STRING and ARGS are passed to `format'."
  (when flywrite-debug
    (with-current-buffer (get-buffer-create "*flywrite-log*")
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] ")
              (apply #'format format-string args)
              "\n"))))

;;;; ---- Paragraph boundary helpers ----


(defun flywrite--paragraph-bounds-at-pos (pos)
  "Return (beg . end) of the paragraph containing POS."
  (save-excursion
    (goto-char pos)
    (let (beg end)
      (backward-paragraph)
      (skip-chars-forward " \t\n")
      (setq beg (point))
      (forward-paragraph)
      (skip-chars-backward " \t\n")
      (setq end (point))
      (when (< end beg) (setq end beg))
      (cons beg end))))


;;;; ---- Hashing ----


(defun flywrite--content-hash (beg end)
  "Compute MD5 hash of buffer text between BEG and END."
  (md5 (buffer-substring-no-properties beg end)))


;;;; ---- Mode-aware suppression ----


(defun flywrite--should-skip-p (pos)
  "Return non-nil if text at POS should be skipped.
Checks font-lock faces and major mode."
  ;; Skip if major mode derives from any mode in flywrite-skip-modes
  (or (cl-some (lambda (mode) (derived-mode-p mode)) flywrite-skip-modes)
      ;; Skip code/comment regions based on font-lock face
      (let ((face (get-text-property pos 'face)))
        (when face
          (let ((faces (if (listp face) face (list face))))
            (cl-some (lambda (f)
                       (memq f '(font-lock-comment-face
                                 font-lock-comment-delimiter-face
                                 font-lock-string-face
                                 font-lock-doc-face
                                 org-block
                                 org-code
                                 org-verbatim
                                 markdown-code-face
                                 markdown-inline-code-face
                                 markdown-pre-face)))
                     faces))))))


;;;; ---- Change detection ----


(defun flywrite--clear-paragraph-diagnostics (ubeg uend)
  "Remove diagnostics overlapping UBEG..UEND and re-report."
  (when flywrite--diagnostics
    (let ((old-count (length flywrite--diagnostics)))
      (setq flywrite--diagnostics
            (cl-remove-if
             (lambda (diag)
               (let ((dbeg (flymake-diagnostic-beg diag))
                     (dend (flymake-diagnostic-end diag)))
                 (or (not (and dbeg dend))
                     (and (>= dbeg ubeg) (<= dend uend)))))
             flywrite--diagnostics))
      (when (and (/= old-count (length flywrite--diagnostics))
                 flywrite--report-fn)
        (funcall flywrite--report-fn flywrite--diagnostics)))))


(defun flywrite--update-region-hash (ubeg uend hash)
  "Update region hash for UBEG..UEND to HASH, clearing stale entries."
  (let* ((region-key (format "%d-%d" ubeg uend))
         (old-hash (gethash region-key flywrite--region-hashes)))
    (when (and old-hash (not (string= old-hash hash)))
      (remhash old-hash flywrite--checked-paragraphs))
    (puthash region-key hash flywrite--region-hashes)))


(defun flywrite--process-changed-paragraph (ubeg uend hash)
  "Process a single changed paragraph bounded by UBEG..UEND with content HASH."
  (flywrite--clear-paragraph-diagnostics ubeg uend)
  (flywrite--update-region-hash ubeg uend hash)

  ;; Remove stale pending queue entries for this region
  (setq flywrite--pending-queue
        (cl-remove-if (lambda (entry)
                        (and (eq (nth 0 entry) (current-buffer))
                             (<= (nth 1 entry) uend)
                             (>= (nth 2 entry) ubeg)))
                      flywrite--pending-queue))

  ;; Skip if already checked with same hash
  (unless (gethash hash flywrite--checked-paragraphs)
    ;; Remove any existing dirty entry for overlapping region
    (setq flywrite--dirty-registry
          (cl-remove-if (lambda (entry)
                          (and (<= (nth 0 entry) uend)
                               (>= (nth 1 entry) ubeg)))
                        flywrite--dirty-registry))

    ;; Add new dirty entry
    (push (list ubeg uend hash) flywrite--dirty-registry)
    (flywrite--log "Dirty: [%d-%d] hash=%s queue=%d text=%S"
                   ubeg uend hash
                   (length flywrite--dirty-registry)
                   (truncate-string-to-width
                    (string-trim
                     (buffer-substring-no-properties ubeg uend))
                    80 nil nil t))))


(defun flywrite--after-change (beg end _len)
  "Hook for `after-change-functions'.  Mark dirty paragraphs.
BEG and END are the changed region boundaries."
  (when flywrite-mode
    (condition-case err
        (let* ((bounds1 (flywrite--paragraph-bounds-at-pos beg))
               (bounds2 (when (and end (> end beg))
                          (flywrite--paragraph-bounds-at-pos end)))
               (paras (if (and bounds2 (not (equal bounds1 bounds2)))
                          (list bounds1 bounds2)
                        (list bounds1))))

          ;; An edit near a paragraph boundary can dirty two paragraphs.
          (dolist (bounds paras)
            (flywrite--process-changed-paragraph
             (car bounds) (cdr bounds)
             (flywrite--content-hash (car bounds) (cdr bounds)))))
      (error
       (flywrite--log "Error in after-change: %s buf=%s"
                      (error-message-string err) (buffer-name))))))


;;;; ---- API call ----


(defun flywrite--read-api-key-file ()
  "Read and return the API key from `flywrite-api-key-file', or nil.
Signal an error if the file is set but not readable."
  (when flywrite-api-key-file
    (unless (file-readable-p flywrite-api-key-file)
      (error "Cannot read flywrite-api-key-file: %s"
             flywrite-api-key-file))
    (let ((key (string-trim
                (with-temp-buffer
                  (insert-file-contents flywrite-api-key-file)
                  (buffer-substring-no-properties
                   (point-min) (line-end-position))))))
      (unless (string-empty-p key) key))))


(defun flywrite--get-api-key ()
  "Return the API key, or nil if none is configured.
Checks `flywrite-api-key', then `flywrite-api-key-file', then
the FLYWRITE_API_KEY environment variable.  Returns nil when no
key is found (e.g., for local providers like Ollama)."
  (or flywrite-api-key
      (flywrite--read-api-key-file)
      (getenv "FLYWRITE_API_KEY")))


(defun flywrite--anthropic-api-p ()
  "Return non-nil if `flywrite-api-url' points to the Anthropic API."
  (and flywrite-api-url
       (string-match-p "api\\.anthropic\\.com" flywrite-api-url)))


(defun flywrite--effective-model ()
  "Return the model to use for API call.
If `flywrite-api-model' is non-nil, return it.  Otherwise
auto-detect from `flywrite-api-url'."
  (or flywrite-api-model
      (cond
       ((null flywrite-api-url)
        (error "Set flywrite-api-url or flywrite-api-model"))
       ((string-match-p "api\\.anthropic\\.com" flywrite-api-url)
        flywrite--default-model-anthropic)
       ((string-match-p
         "generativelanguage\\.googleapis\\.com"
         flywrite-api-url)
        flywrite--default-model-gemini)
       (t flywrite--default-model-openai))))


(defun flywrite--build-request (text api-key)
  "Build an API request for TEXT, returning (PAYLOAD . HEADERS).
PAYLOAD is a JSON-encoded string.  HEADERS is an alist suitable
for `url-request-extra-headers'.  API-KEY may be nil for local
providers."
  (let* ((anthropic-p (flywrite--anthropic-api-p))
         (model (flywrite--effective-model))
         (prompt (flywrite--get-system-prompt))
         ;; Anthropic caching wraps the prompt in a content block:
         ;;   "system": [{"type":"text", "text":"...",
         ;;               "cache_control":{"type":"ephemeral"}}]
         ;; Without caching, use the plain prompt string.
         (system-msg (if (and anthropic-p flywrite-enable-caching)
                         `[((type . "text")
                            (text . ,prompt)
                            (cache_control . ((type . "ephemeral"))))]
                       prompt))

         ;; Anthropic: system prompt is a top-level "system" field.
         ;;   {"model":"...", "system":"...", "messages":[{"role":"user",...}]}
         ;;
         ;; OpenAI-compatible: system prompt is a message with role "system".
         ;;   {"model":"...", "messages":[{"role":"system",...},
         ;;    {"role":"user",...}]}
         (payload (json-encode
                   (if anthropic-p
                       `((model . ,model)
                         (max_tokens . 4096)
                         (temperature . ,flywrite-api-temperature)
                         (system . ,system-msg)
                         (messages . [((role . "user")
                                       (content . ,text))]))
                     `((model . ,model)
                       (max_tokens . 4096)
                       (temperature . ,flywrite-api-temperature)
                       (messages . [((role . "system")
                                     (content . ,prompt))
                                    ((role . "user")
                                     (content . ,text))])))))

         ;; Anthropic: "x-api-key: sk-..." + "anthropic-version: 2023-06-01"
         ;; Others:    "Authorization: Bearer sk-..."
         (headers
          (append `(("Content-Type" . "application/json")
                    ,@(cond
                       (anthropic-p
                        `(("x-api-key" . ,api-key)
                          ("anthropic-version" . "2023-06-01")))
                       (api-key
                        `(("Authorization" . ,(concat "Bearer " api-key))))))
                  flywrite-api-headers)))
    (cons payload headers)))


(defun flywrite--validate-config ()
  "Validate flywrite configuration.
Signal an error if configuration is invalid, preventing mode activation."
  (flywrite--log "Validating API configuration")
  (condition-case err
      (progn
        ;; API URL must be set and well-formed.
        (unless flywrite-api-url
          (error "Set flywrite-api-url"))
        (flywrite--log "API URL: %s" flywrite-api-url)
        (unless (string-match-p "\\`https?://" flywrite-api-url)
          (error "Flywrite-api-url must start with http(s)://: %s"
                 flywrite-api-url))

        ;; API key is required for remote providers but optional for
        ;; local ones (e.g., Ollama on localhost).
        (let* ((local-p (string-match-p
                         "\\(?:localhost\\|127\\.0\\.0\\.1\\)"
                         flywrite-api-url))
               (api-key (flywrite--get-api-key)))
          (flywrite--log "API key source: %s"
                         (cond (flywrite-api-key "flywrite-api-key variable")
                               ((flywrite--read-api-key-file)
                                (format "flywrite-api-key-file (%s)"
                                        flywrite-api-key-file))
                               ((getenv "FLYWRITE_API_KEY")
                                "FLYWRITE_API_KEY env var")
                               (local-p "none (local provider)")
                               (t "none")))
          (when (and (not api-key) (not local-p))
            (error "API key is not set, see the README for configuration")))

        ;; Model resolves without error
        (flywrite--log "API model: %s" (flywrite--effective-model))

        ;; System prompt resolves without error
        (flywrite--get-system-prompt)
        (flywrite--log "Config valid"))
    (error
     (flywrite--log "Config validation failed: %s" (error-message-string err))
     (signal (car err) (cdr err)))))


(cl-defun flywrite--send-request (buf beg end hash)
  "Send an API request for the text in BUF between BEG and END.
HASH is the content hash at time of dispatch for stale checking."
  ;; Skip if already checked (catches duplicates from queue)
  (when (with-current-buffer buf
          (gethash hash flywrite--checked-paragraphs))
    (flywrite--log "Skipping already-checked hash=%s" hash)
    (cl-return-from flywrite--send-request))

  ;; Extract text from the source buffer, build headers + JSON payload,
  ;; and fire the async HTTP request.
  (condition-case err
      (let* ((text (with-current-buffer buf
                     (buffer-substring-no-properties beg end)))

             ;; Resolve API key and build the request
             (api-key (flywrite--get-api-key))
             (_ (when (and (flywrite--anthropic-api-p) (not api-key))
                  (error "An API key is required for the Anthropic API")))
             (request (flywrite--build-request text api-key))
             (payload (car request))

             ;; Bind url-retrieve dynamic variables
             (url-request-method "POST")
             (url-request-extra-headers (cdr request))
             (url-request-data (encode-coding-string payload 'utf-8))
             (start-time (current-time)))

        (flywrite--log "API call: [%d-%d] buf=%s url=%s text=%.80s hash=%s"
                       beg end (buffer-name buf) flywrite-api-url text hash)

        ;; Increment in-flight counter and mark hash as checked before the
        ;; async call so that no duplicate request is dispatched while this
        ;; one is still in progress.
        (with-current-buffer buf
          (cl-incf flywrite--in-flight)
          (puthash hash t flywrite--checked-paragraphs))

        ;; Fire async HTTP request; track the connection buffer for cleanup.
        (let ((conn-buf
               (url-retrieve
                flywrite-api-url
                (lambda (status)
                  (flywrite--handle-response
                   status buf beg end hash start-time))
                nil t t)))
          (when (and conn-buf (buffer-live-p conn-buf))
            (with-current-buffer buf
              (push conn-buf flywrite--connection-buffers)))))
    (error
     (flywrite--log "Request error: %s url=%s hash=%s"
                    (error-message-string err) flywrite-api-url hash)
     (message
      "flywrite: request error, check *flywrite-log* for details"))))


;;;; ---- Response handler helpers ----


(defun flywrite--response-body-snippet ()
  "Return the first 500 characters of the HTTP response body.
Assumes the current buffer contains a raw HTTP response.
Returns nil if no body separator is found."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "\r?\n\r?\n" nil t)
      (truncate-string-to-width
       (buffer-substring-no-properties (point) (point-max))
       500 nil nil t))))


(defun flywrite--flush-queue ()
  "Clear the pending queue in the current buffer."
  (when flywrite--pending-queue
    (flywrite--log "Clearing %d queued requests"
                   (length flywrite--pending-queue))
    (setq flywrite--pending-queue nil)))


(defun flywrite--duplicate-callback-p (response-buf hash)
  "Return non-nil if RESPONSE-BUF callback was already handled.
Marks the buffer as handled on first call.  HASH is for logging."
  (when (buffer-live-p response-buf)
    (with-current-buffer response-buf
      (if (bound-and-true-p flywrite--response-handled)
          (progn
            (flywrite--log "Ignoring duplicate callback for hash=%s" hash)
            t)
        (setq-local flywrite--response-handled t)
        nil))))


(defun flywrite--check-http-error (status buf latency hash)
  "Signal an error if STATUS indicates an HTTP failure.
BUF is the source buffer, LATENCY and HASH are for logging.
Clears the pending queue on 429 rate-limit errors."
  (when-let ((err-info (plist-get status :error)))
    (let ((err-body (flywrite--response-body-snippet)))
      (flywrite--log "API HTTP error: %s (%.2fs) hash=%s\nResponse body: %s"
                     err-info latency hash (or err-body "<empty>"))

      ;; On 429 rate-limit or 529 overload, flush the queue to avoid
      ;; hammering the API.
      (when (and (listp err-info)
                 (or (member 429 err-info) (member 529 err-info)))
        (let ((reason (if (member 429 err-info)
                          "rate limit" "API overload")))
          (flywrite--log "%s hash=%s" reason hash)
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (flywrite--flush-queue)))))
      (error (if (and (listp err-info) (member 529 err-info))
                 "API overloaded (529), try again later"
               (format "API request failed: %s" err-info))))))


(defun flywrite--extract-response-text ()
  "Parse the current response buffer and return the LLM text.
Skips HTTP headers, parses JSON, and returns (TEXT . JSON-DATA)
or nil if no text could be extracted.  Signals on malformed HTTP."
  (goto-char (point-min))
  (let ((http-status (when (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
                       (match-string 1))))
    (unless (re-search-forward "\r?\n\r?\n" nil t)
      (error "Malformed HTTP response"))

    ;; Parse JSON body (json-read returns alists with symbol keys)
    ;; Anthropic: {content: [{type:"text", text:"..."}]}
    ;; OpenAI:    {choices: [{message: {content: "..."}}]}
    (let* ((json-data (json-read))
           (text (if (flywrite--anthropic-api-p)
                     (let* ((content (alist-get 'content json-data))
                            (text-block (and (arrayp content)
                                             (> (length content) 0)
                                             (aref content 0))))
                       (and text-block (alist-get 'text text-block)))
                   (let* ((choices (alist-get 'choices json-data))
                          (choice (and (arrayp choices)
                                       (> (length choices) 0)
                                       (aref choices 0)))
                          (message (and choice (alist-get 'message choice))))
                     (and message (alist-get 'content message))))))
      (list http-status json-data text))))


(defun flywrite--handle-stale-response (beg end hash)
  "Return non-nil if the response for BEG..END with HASH is stale.
When stale, removes the old hash and re-dirties the paragraph."
  ;; The text may have changed while the API call was in-flight.
  ;; Detect this via hash mismatch and re-dirty instead of applying.
  (when (or (> end (point-max))
            (< beg (point-min))
            (not (string= hash (flywrite--content-hash beg end))))
    (flywrite--log "Stale response discarded: [%d-%d] hash=%s" beg end hash)
    (remhash hash flywrite--checked-paragraphs)
    (let ((new-hash (when (and (<= beg (point-max)) (<= end (point-max)))
                      (flywrite--content-hash beg end))))
      (when (and new-hash (not (gethash new-hash flywrite--checked-paragraphs)))
        (push (list beg end new-hash) flywrite--dirty-registry)))
    t))


(defun flywrite--parse-response-json (text)
  "Parse TEXT as JSON, stripping markdown code fences if present.
TEXT is the raw LLM response string.  Returns the parsed alist.
Also strips trailing commas before ] or } which some LLMs produce."
  (let* ((json-array-type 'list)
         (clean (replace-regexp-in-string
                 "\\`[ \t\n]*```\\(?:json\\)?[ \t]*\n?" ""
                 (replace-regexp-in-string
                  "\n?```[ \t\n]*\\'" "" text)))
         (clean (replace-regexp-in-string
                 ",[ \t\n]*\\([]}]\\)" "\\1" clean)))
    (json-read-from-string clean)))


(defun flywrite--apply-suggestions (buf beg end hash text)
  "Parse TEXT as suggestion JSON and create diagnostics in BUF.
BEG, END, HASH identify the checked region."
  (condition-case parse-err
      (let* ((parsed (flywrite--parse-response-json text))
             (suggestions (alist-get 'suggestions parsed)))
        (flywrite--log "Suggestions: %d for [%d-%d] hash=%s"
                       (length suggestions) beg end hash)

        ;; Remove old diagnostics for this region
        (setq flywrite--diagnostics
              (cl-remove-if
               (lambda (diag)
                 (and (>= (flymake-diagnostic-beg diag) beg)
                      (<= (flymake-diagnostic-end diag) end)))
               flywrite--diagnostics))

        ;; Add new diagnostics
        (let ((region-text (buffer-substring-no-properties beg end)))
          (dolist (suggestion (append suggestions nil))
            (flywrite--make-suggestion-diagnostic
             buf beg region-text suggestion hash)))

        ;; Report to flymake and mark checked
        (flywrite--report-to-flymake hash)
        (puthash hash t flywrite--checked-paragraphs))
    (error
     (flywrite--log "LLM unparseable response: %s hash=%s\n%s"
                    (error-message-string parse-err) hash text)
     (message "flywrite: invalid JSON, see *flywrite-log*"))))


(defun flywrite--make-suggestion-diagnostic
    (buf beg region-text suggestion hash)
  "Create a diagnostic from SUGGESTION and add it to `flywrite--diagnostics'.
BUF is the source buffer, BEG is the region start, REGION-TEXT is
the region content.  HASH is for logging."
  (let* ((quote-str (alist-get 'quote suggestion))
         (reason (alist-get 'reason suggestion))
         (match-pos (and quote-str
                         (string-match (regexp-quote quote-str) region-text))))
    (if match-pos
        (let ((diag-beg (+ beg match-pos))
              (diag-end (+ beg match-pos (length quote-str))))
          (push (flymake-make-diagnostic
                 buf diag-beg diag-end 'flywrite-diagnostic-type
                 (concat reason " [flywrite]"))
                flywrite--diagnostics)
          (flywrite--log "Diagnostic: [%d-%d] %s hash=%s"
                         diag-beg diag-end reason hash))
      (flywrite--log "Quote not found, skipping: %s hash=%s" quote-str hash))))


(defun flywrite--report-to-flymake (hash)
  "Report `flywrite--diagnostics' to flymake.  HASH is for logging."
  (if flywrite--report-fn
      (funcall flywrite--report-fn flywrite--diagnostics)
    (flywrite--log "Warning: report-fn nil, diag-fns=%s hash=%s"
                   flymake-diagnostic-functions hash)
    (unless (memq #'flywrite-flymake flymake-diagnostic-functions)
      (flywrite--log "Re-adding flywrite-flymake backend hash=%s" hash)
      (add-hook 'flymake-diagnostic-functions #'flywrite-flymake nil t))
    (when (bound-and-true-p flymake-mode)
      (flymake-start))))


;;;; ---- Response handler ----


(defun flywrite--process-response (status buf beg end hash latency)
  "Process a non-duplicate API response in the response buffer.
STATUS is from `url-retrieve'.  BUF, BEG, END, HASH identify the
request.  LATENCY is the elapsed time in seconds.
Called with the response buffer current.  May signal on errors."
  (flywrite--check-http-error status buf latency hash)
  (cl-destructuring-bind (http-status json-data text)
      (flywrite--extract-response-text)
    (flywrite--log "Response: HTTP %s %.2fs hash=%s JSON=%S"
                   (or http-status "?") latency hash json-data)
    (unless text
      (flywrite--log "No extractable text, skipping hash=%s json=%S"
                     hash json-data))
    (when (and text (buffer-live-p buf))
      (with-current-buffer buf
        (unless (flywrite--handle-stale-response beg end hash)
          (flywrite--apply-suggestions buf beg end hash text))))))


(cl-defun flywrite--handle-response (status buf beg end hash start-time)
  "Handle API response.
STATUS is from `url-retrieve'.  BUF, BEG, END, HASH identify the
request.  START-TIME is used for latency logging."
  (let ((latency (float-time (time-subtract (current-time) start-time)))
        (response-buf (current-buffer)))

    ;; Ignore duplicate callbacks from url-retrieve
    (when (flywrite--duplicate-callback-p response-buf hash)
      (when (buffer-live-p response-buf)
        (kill-buffer response-buf))
      (cl-return-from flywrite--handle-response))

    ;; Remove from connection tracking
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq flywrite--connection-buffers
              (delq response-buf flywrite--connection-buffers))))

    ;; Process the response; always decrement in-flight and drain queue.
    (unwind-protect
        (condition-case err
            (flywrite--process-response status buf beg end hash latency)
          (error
           (let ((body (ignore-errors
                         (flywrite--response-body-snippet))))
             (flywrite--log "Response handler error: %s hash=%s\n%s"
                            (error-message-string err) hash
                            (or body "<empty>"))
             (message "flywrite: %s" (error-message-string err)))))

      ;; Always: decrement counter and drain queue
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (cl-decf flywrite--in-flight)
          (when (< flywrite--in-flight 0)
            (setq flywrite--in-flight 0))
          (flywrite--drain-queue)))

      ;; Clean up response buffer
      (kill-buffer response-buf))))


;;;; ---- Idle timer callback ----


(defun flywrite--eager-scan ()
  "Add the paragraph at point to the dirty registry.
Allows reviewing existing text by moving the cursor through it,
without requiring an edit to trigger checking."
  (condition-case err
      (let* ((bounds (flywrite--paragraph-bounds-at-pos (point)))
             (pbeg (car bounds))
             (pend (cdr bounds))
             (entry (when (> pend pbeg)
                      (flywrite--try-collect-paragraph
                       pbeg pend (make-hash-table :test 'eql)))))
        (when entry
          (push entry flywrite--dirty-registry)))
    (error
     (flywrite--log "Error in eager scan: %s buf=%s"
                    (error-message-string err) (buffer-name)))))


(defun flywrite--dispatch-entry (buf beg end hash seen)
  "Validate and dispatch or queue a single dirty entry.
BUF is the buffer, BEG/END are bounds, HASH is the content hash,
SEEN is a hash table for deduplication within this batch."
  ;; Guard: only proceed if bounds are valid, the hash hasn't already
  ;; been checked or seen in this batch, and the region is prose.
  (when (and (<= end (point-max))
             (>= beg (point-min))
             (not (gethash hash flywrite--checked-paragraphs))
             (not (gethash hash seen))
             (or (not (flywrite--should-skip-p beg))
                 (progn
                   (flywrite--log "Skipped (non-prose region): [%d-%d] hash=%s"
                                  beg end hash)
                   nil)))

    ;; Record in batch-local SEEN table to deduplicate within this dispatch.
    (puthash hash t seen)

    ;; Send immediately if under the concurrency cap, otherwise append
    ;; to the pending queue for later draining.
    (if (< flywrite--in-flight flywrite-max-concurrent)
        (flywrite--send-request buf beg end hash)
      (flywrite--log "Queued: [%d-%d] (at cap %d) hash=%s"
                     beg end flywrite--in-flight hash)
      (setq flywrite--pending-queue
            (append flywrite--pending-queue
                    (list (list buf beg end hash)))))))


(defun flywrite--dispatch-dirty-registry (buf)
  "Snapshot and clear the dirty registry, dispatch or queue entries for BUF."
  ;; Snapshot-and-clear so new edits during dispatch go into a fresh registry.
  (when flywrite--dirty-registry
    (let ((snapshot flywrite--dirty-registry)
          (seen (make-hash-table :test 'equal)))
      (setq flywrite--dirty-registry nil)
      (dolist (entry snapshot)
        (flywrite--dispatch-entry buf
                                  (nth 0 entry) (nth 1 entry) (nth 2 entry)
                                  seen)))))


(defun flywrite--idle-timer-fn (buf)
  "Idle timer callback for buffer BUF.
Snapshots and clears the dirty registry, dispatches or queues requests."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when flywrite-mode
        (when flywrite-eager
          (flywrite--eager-scan))
        (flywrite--dispatch-dirty-registry buf)))))

;;;; ---- Pending queue drain ----


(defun flywrite--drain-queue ()
  "Dispatch pending requests when slots are available."
  (while (and flywrite--pending-queue
              (< flywrite--in-flight flywrite-max-concurrent))
    (let* ((entry (pop flywrite--pending-queue))
           (buf (nth 0 entry))
           (beg (nth 1 entry))
           (end (nth 2 entry))
           (hash (nth 3 entry)))
      (when (and (buffer-live-p buf)
                 (<= end (with-current-buffer buf (point-max)))
                 (not (gethash hash (buffer-local-value
                                     'flywrite--checked-paragraphs buf))))
        (flywrite--log "Draining queue: [%d-%d] hash=%s" beg end hash)
        (flywrite--send-request buf beg end hash)))))


;;;; ---- Flymake backend ----


(defun flywrite-flymake (report-fn &rest _args)
  "Flymake backend for flywrite.  Store REPORT-FN for later use.
Reports any existing diagnostics immediately so flymake can display them."
  (flywrite--log "flywrite-flymake called by flymake, report-fn set")
  (setq flywrite--report-fn report-fn)
  (funcall report-fn flywrite--diagnostics))


;;;; ---- Interactive commands ----


(defun flywrite--try-collect-paragraph (ubeg uend seen)
  "Return a (ubeg uend hash) triple if paragraph UBEG..UEND should be collected.
SEEN is a hash table of already-visited paragraph starts.  Returns nil
if the paragraph is empty, duplicate, already checked, or in a skip region."
  (when (and (> uend ubeg)
             (not (gethash ubeg seen)))
    (puthash ubeg t seen)
    (let ((hash (flywrite--content-hash ubeg uend)))
      (unless (or (gethash hash flywrite--checked-paragraphs)
                  (flywrite--should-skip-p ubeg))
        (list ubeg uend hash)))))


(defun flywrite--collect-paragraphs-in-region (beg end)
  "Collect all paragraphs in region BEG to END.
Returns a list of (beg end hash) triples."
  (let ((paragraphs nil)
        (seen (make-hash-table :test 'eql)))
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let* ((bounds (flywrite--paragraph-bounds-at-pos (point)))
               (ubeg (car bounds))
               (uend (cdr bounds))
               (entry (when (<= uend end)
                        (flywrite--try-collect-paragraph ubeg uend seen))))
          (when entry (push entry paragraphs))

          ;; Move past current paragraph and inter-paragraph whitespace
          (goto-char (max (1+ (point)) uend))
          (skip-chars-forward " \t\n"))))
    (nreverse paragraphs)))


(defun flywrite-check-buffer ()
  "Queue all paragraphs in the buffer for checking.
Prompts for confirmation when the count exceeds
`flywrite-check-confirm-threshold'."
  (interactive)
  (unless flywrite-mode
    (flywrite--log "check-buffer: mode not enabled")
    (user-error "Flywrite-mode is not enabled"))
  (let ((paras (flywrite--collect-paragraphs-in-region
                (point-min) (point-max))))
    (when (and (> (length paras) flywrite-check-confirm-threshold)
               (not (y-or-n-p (format "Check %d paragraphs? "
                                      (length paras)))))
      (flywrite--log "check-buffer: cancelled by user (%d paragraphs)"
                     (length paras))
      (user-error "Cancelled"))
    (let ((count 0))
      (dolist (entry paras)
        (push entry flywrite--dirty-registry)
        (setq count (1+ count))
        (flywrite--log "Dirty: [%d-%d] hash=%s queue=%d text=%S"
                       (nth 0 entry) (nth 1 entry)
                       (nth 2 entry)
                       (length flywrite--dirty-registry)
                       (truncate-string-to-width
                        (string-trim
                         (buffer-substring-no-properties
                          (nth 0 entry) (nth 1 entry)))
                        80 nil nil t)))
      (flywrite--log "Queued %d paragraphs for buffer check" count)
      (message "flywrite: queued %d paragraphs for checking" count))))


(defun flywrite-check-region (beg end)
  "Queue all paragraphs between BEG and END for checking.
Prompts for confirmation when the count exceeds
`flywrite-check-confirm-threshold'."
  (interactive "r")
  (unless flywrite-mode
    (flywrite--log "check-region: mode not enabled")
    (user-error "Flywrite-mode is not enabled"))
  (unless (use-region-p)
    (flywrite--log "check-region: no active region")
    (user-error "No active region"))
  (let ((paras (flywrite--collect-paragraphs-in-region beg end)))
    (when (and (> (length paras) flywrite-check-confirm-threshold)
               (not (y-or-n-p (format "Check %d paragraphs? "
                                      (length paras)))))
      (flywrite--log "check-region: cancelled by user (%d paragraphs)"
                     (length paras))
      (user-error "Cancelled"))
    (let ((count 0))
      (dolist (entry paras)

        ;; Remove from checked so re-checks work
        (remhash (nth 2 entry) flywrite--checked-paragraphs)
        (push entry flywrite--dirty-registry)
        (setq count (1+ count))
        (flywrite--log "Dirty: [%d-%d] hash=%s queue=%d text=%S"
                       (nth 0 entry) (nth 1 entry)
                       (nth 2 entry)
                       (length flywrite--dirty-registry)
                       (truncate-string-to-width
                        (string-trim
                         (buffer-substring-no-properties
                          (nth 0 entry) (nth 1 entry)))
                        80 nil nil t)))
      (flywrite--log "Queued %d paragraphs in region for checking" count)
      (message "flywrite: queued %d paragraphs in region for checking"
               count)

      ;; Dispatch immediately rather than waiting for idle timer
      (flywrite--idle-timer-fn (current-buffer)))))


(defun flywrite-check-at-point ()
  "Queue the paragraph at point for checking."
  (interactive)
  (unless flywrite-mode
    (flywrite--log "check-at-point: mode not enabled")
    (user-error "Flywrite-mode is not enabled"))
  (let* ((bounds (flywrite--paragraph-bounds-at-pos (point)))
         (ubeg (car bounds))
         (uend (cdr bounds))
         (hash (flywrite--content-hash ubeg uend)))
    (when (flywrite--should-skip-p ubeg)
      (flywrite--log "check-at-point: skipped region at [%d-%d]" ubeg uend)
      (user-error "Point is in a skipped region"))

    ;; Remove from checked so it gets re-checked even if seen before
    (remhash hash flywrite--checked-paragraphs)
    (push (list ubeg uend hash) flywrite--dirty-registry)
    (flywrite--log "Queued paragraph at point [%d-%d] hash=%s"
                   ubeg uend hash)
    (message "flywrite: queued paragraph at point for checking")

    ;; Dispatch immediately rather than waiting for idle timer
    (flywrite--idle-timer-fn (current-buffer))))


(defun flywrite-clear ()
  "Clear all flywrite diagnostics and reset caches."
  (interactive)
  (setq flywrite--diagnostics nil)
  (setq flywrite--dirty-registry nil)
  (setq flywrite--pending-queue nil)
  (clrhash flywrite--checked-paragraphs)
  (clrhash flywrite--region-hashes)
  (when flywrite--report-fn
    (funcall flywrite--report-fn nil))
  (when (bound-and-true-p flymake-mode)
    (flymake-start))
  (flywrite--log "Cleared all diagnostics and caches")
  (message "flywrite: cleared all diagnostics and caches"))


(defun flywrite-set-prompt (style)
  "Set the system prompt for the current buffer.
STYLE is a symbol from `flywrite--prompt-alist' (e.g., `prose'
or `academic'), chosen interactively with completion.  When the
current prompt is a custom string, \"custom\" appears as an option
that preserves it."
  (interactive
   (let* ((styles (mapcar (lambda (c) (symbol-name (car c)))
                          flywrite--prompt-alist))
          (custom-p (stringp flywrite-system-prompt))
          (current (if custom-p "custom"
                     (symbol-name flywrite-system-prompt)))
          (candidates (if custom-p
                          (append styles '("custom"))
                        styles))
          (choice (completing-read
                   (format "Prompt style (current: %s): "
                           current)
                   candidates nil t nil nil current)))
     (list (if (string= choice "custom")
               flywrite-system-prompt
             (intern choice)))))
  (setq-local flywrite-system-prompt style)
  (message "flywrite: prompt set to %s"
           (if (stringp style) "custom" style)))


(defun flywrite--prompt-watcher (_symbol newval operation where)
  "Handle a `flywrite-system-prompt' change by clearing diagnostics.
OPERATION is the type of change; NEWVAL is the new value; WHERE
is the buffer for buffer-local sets or nil for global sets."
  (when (eq operation 'set)
    (let ((label (if (symbolp newval) (symbol-name newval) "custom"))
          (bufs (if (and where (buffer-live-p where))
                    (list where)
                  (buffer-list)))
          ;; Resolve from newval — the variable watcher fires before
          ;; the variable is actually updated.
          (prompt (let ((flywrite-system-prompt newval))
                    (flywrite--get-system-prompt))))
      (dolist (buf bufs)
        (with-current-buffer buf
          ;; Guard with flywrite--idle-timer so we skip changes that
          ;; arrive before deferred enable (e.g., file-local variables
          ;; processed during find-file).
          (when (and flywrite-mode flywrite--idle-timer)
            (flywrite--log "System prompt changed to %s in %s"
                           label (buffer-name))
            (flywrite--log "System prompt:\n%s" prompt)
            (flywrite-clear)))))))

(add-variable-watcher 'flywrite-system-prompt #'flywrite--prompt-watcher)


;;;; ---- Minor mode definition ----

;;;###autoload
(define-minor-mode flywrite-mode
  "Minor mode for inline writing suggestions via LLM.
Provides grammar, clarity, and style feedback as flymake diagnostics."
  :lighter " Flywrite"
  :group 'flywrite
  (cond
   ((not flywrite-mode)
    (flywrite--disable))
   (flywrite--idle-timer
    ;; Already active — skip duplicate setup (e.g., multiple hooks firing)
    nil)
   (t
    (condition-case err
        (flywrite--enable)
      (error
       (setq flywrite-mode nil)
       (signal (car err) (cdr err)))))))


(defun flywrite--ensure-flymake-backend ()
  "Ensure `flywrite-flymake' is in `flymake-diagnostic-functions'.
Eglot replaces the buffer-local value with only its own backend."
  (when (and flywrite-mode
             (not (memq #'flywrite-flymake flymake-diagnostic-functions)))
    (flywrite--log "Re-adding flywrite-flymake after eglot setup")
    (add-hook 'flymake-diagnostic-functions #'flywrite-flymake nil t)))


(defun flywrite--enable ()
  "Set up `flywrite-mode' in the current buffer."
  ;; Validate config before any setup — signals error on bad config
  (flywrite--validate-config)

  ;; Initialize buffer-local state
  (setq flywrite--dirty-registry nil)
  (setq flywrite--checked-paragraphs (make-hash-table :test 'equal))
  (setq flywrite--region-hashes (make-hash-table :test 'equal))
  (setq flywrite--in-flight 0)
  (setq flywrite--pending-queue nil)
  (setq flywrite--connection-buffers nil)
  (setq flywrite--diagnostics nil)
  (setq flywrite--report-fn nil)

  ;; Enable flymake and register our diagnostic backend.
  ;; Do this before adding our after-change hook so that our hook is
  ;; at the head of the list and runs before flymake's hook.
  (unless (bound-and-true-p flymake-mode)
    (flymake-mode 1))

  ;; Register change-detection hook (must come after flymake-mode
  ;; enablement so our hook is first in after-change-functions)
  (add-hook 'after-change-functions #'flywrite--after-change nil t)
  (add-hook 'flymake-diagnostic-functions #'flywrite-flymake nil t)

  ;; Eglot replaces flymake-diagnostic-functions with only its own
  ;; backend, so re-add ours after eglot setup.
  (when (fboundp 'eglot-managed-mode-hook)
    (add-hook 'eglot-managed-mode-hook
              #'flywrite--ensure-flymake-backend nil t))

  ;; Start the idle timer that drains the dirty registry
  (setq flywrite--idle-timer
        (run-with-idle-timer flywrite-idle-delay t
                             #'flywrite--idle-timer-fn (current-buffer)))

  ;; Defer system prompt logging so file-local variables are in
  ;; effect.  During find-file, mode hooks run before
  ;; hack-local-variables; a 0-delay timer fires after find-file
  ;; completes.
  (let ((buf (current-buffer)))
    (run-with-timer
     0 nil
     (lambda ()
       (when (and (buffer-live-p buf)
                  (buffer-local-value 'flywrite-mode buf))
         (with-current-buffer buf
           (flywrite--log "prompt=%s"
                          (if (symbolp flywrite-system-prompt)
                              flywrite-system-prompt "custom"))
           (flywrite--log "System prompt:\n%s"
                          (flywrite--get-system-prompt)))))))

  (flywrite--log (concat "flywrite-mode enabled in %s"
                         " (emacs %s, url=%s, model=%s,"
                         " idle=%.1f,"
                         " max-concurrent=%d, eager=%s,"
                         " caching=%s)")
                 (buffer-name) emacs-version
                 (or flywrite-api-url "nil")
                 (or flywrite-api-model "auto")
                 flywrite-idle-delay flywrite-max-concurrent
                 flywrite-eager flywrite-enable-caching))


(defun flywrite--disable ()
  "Tear down `flywrite-mode' in the current buffer."
  (flywrite--log (concat "flywrite-mode disabled in %s"
                         " (in-flight=%d, pending=%d,"
                         " dirty=%d)")
                 (buffer-name) flywrite--in-flight
                 (length flywrite--pending-queue)
                 (length flywrite--dirty-registry))

  ;; Cancel idle timer
  (when flywrite--idle-timer
    (cancel-timer flywrite--idle-timer)
    (setq flywrite--idle-timer nil))

  ;; Kill in-flight HTTP buffers so network processes don't linger
  (dolist (conn-buf flywrite--connection-buffers)
    (when (buffer-live-p conn-buf)
      (let ((proc (get-buffer-process conn-buf)))
        (when proc
          (delete-process proc)))
      (kill-buffer conn-buf)))
  (setq flywrite--connection-buffers nil)

  ;; Unhook from after-change and eglot
  (remove-hook 'after-change-functions #'flywrite--after-change t)
  (remove-hook 'eglot-managed-mode-hook #'flywrite--ensure-flymake-backend t)

  ;; Clear diagnostics before reporting so flymake-start doesn't
  ;; re-report stale diagnostics via the flywrite-flymake backend
  (setq flywrite--diagnostics nil)
  (when flywrite--report-fn
    (funcall flywrite--report-fn nil))
  (when (bound-and-true-p flymake-mode)
    (flymake-start))
  (remove-hook 'flymake-diagnostic-functions #'flywrite-flymake t)

  ;; Reset all state
  (setq flywrite--dirty-registry nil)
  (setq flywrite--pending-queue nil)
  (clrhash flywrite--checked-paragraphs)
  (clrhash flywrite--region-hashes))

(provide 'flywrite-mode)

;;; flywrite-mode.el ends here
