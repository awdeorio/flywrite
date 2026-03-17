;;; flywrite-mode.el --- Inline writing suggestions via LLM -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrew DeOrio

;; Author: Andrew DeOrio <awdeorio@umich.edu>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: writing, style, grammar, flymake
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

(defcustom flywrite-model "claude-sonnet-4-20250514"
  "Model to use for writing suggestions."
  :type 'string
  :group 'flywrite)

(defcustom flywrite-idle-delay 1.5
  "Seconds of idle time before checking dirty sentences."
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

(defcustom flywrite-granularity 'sentence
  "Unit of text to check: `sentence' or `paragraph'."
  :type '(choice (const :tag "Sentence" sentence)
                 (const :tag "Paragraph" paragraph))
  :group 'flywrite)

(defcustom flywrite-check-confirm-threshold 50
  "Prompt for confirmation when `flywrite-check-buffer' would make
more than this many API calls."
  :type 'integer
  :group 'flywrite)

(defcustom flywrite-long-sentence-threshold 500
  "Max characters per unit.
Longer units are passed through without truncation or splitting."
  :type 'integer
  :group 'flywrite)

(defcustom flywrite-skip-modes '(prog-mode)
  "Major modes where checking is suppressed."
  :type '(repeat symbol)
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

(defcustom flywrite-debug nil
  "When non-nil, log API calls, responses, and events to `*flywrite-log*'."
  :type 'boolean
  :group 'flywrite)

(defcustom flywrite-test-on-load t
  "When non-nil, test the API connection when `flywrite-mode' is enabled."
  :type 'boolean
  :group 'flywrite)

;; Forward-declare the minor-mode variable (defined by define-minor-mode
;; below) so the byte compiler doesn't warn about a free variable.
(defvar flywrite-mode)

;;;; ---- Buffer-local state ----

(defvar-local flywrite--dirty-registry nil
  "List of (beg end hash) triples for sentences needing a check.")

(defvar-local flywrite--checked-sentences (make-hash-table :test 'equal)
  "Hash table mapping content-hash → t for already-checked sentences.")

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
  "Accumulated list of flymake diagnostics for this buffer.")

;;;; ---- Constants ----

(defcustom flywrite-api-url nil
  "LLM API endpoint URL.
If nil, `flywrite-mode' will display an error asking you to
configure it.  See the README for details."
  :type '(choice (const :tag "Not set" nil)
                 (string :tag "URL"))
  :group 'flywrite)

(defcustom flywrite-system-prompt
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
- Ignore markup and formatting commands (LaTeX, HTML, Org-mode, etc.) -- only evaluate the prose content"
  "System prompt sent with every API call.
The prompt must instruct the model to return JSON with a
\"suggestions\" array.  Each element needs \"quote\" and \"reason\"
keys.  Customize this to change tone, strictness, or focus areas
while preserving the JSON output format."
  :type 'string
  :group 'flywrite)

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

;;;; ---- Unit boundary helpers ----

(defun flywrite--unit-bounds-at-pos (pos)
  "Return (beg . end) of the sentence or paragraph containing POS.
Respects `flywrite-granularity'."
  (save-excursion
    (goto-char pos)
    (if (eq flywrite-granularity 'paragraph)
        (let (beg end)
          (backward-paragraph)
          (skip-chars-forward " \t\n")
          (setq beg (point))
          (forward-paragraph)
          (skip-chars-backward " \t\n")
          (setq end (point))
          (when (< end beg) (setq end beg))
          (cons beg end))
      ;; sentence granularity — treat single space as sentence boundary
      ;; regardless of the user's `sentence-end-double-space' setting
      (let ((sentence-end-double-space nil)
            beg end)
        (backward-sentence)
        (skip-chars-forward " \t\n")
        (setq beg (point))
        (forward-sentence)
        (setq end (point))
        (when (< end beg) (setq end beg))
        (cons beg end)))))

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

(defun flywrite--after-change (beg end _len)
  "Hook for `after-change-functions'.  Marks dirty sentences.
BEG and END are the changed region boundaries."
  (when flywrite-mode
    (condition-case err
        (let* ((bounds1 (flywrite--unit-bounds-at-pos beg))
               (bounds2 (when (and end (> end beg))
                          (flywrite--unit-bounds-at-pos end)))
               (units (if (and bounds2 (not (equal bounds1 bounds2)))
                          (list bounds1 bounds2)
                        (list bounds1))))
          (dolist (bounds units)
            (let* ((ubeg (car bounds))
                   (uend (cdr bounds))
                   (hash (flywrite--content-hash ubeg uend)))
              ;; Skip if already checked with same hash
              (unless (gethash hash flywrite--checked-sentences)
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
                                80 nil nil t))))))
      (error
       (flywrite--log "Error in after-change: %s buf=%s" (error-message-string err) (buffer-name))))))

;;;; ---- API call ----

(defun flywrite--read-api-key-file ()
  "Read and return the API key from `flywrite-api-key-file', or nil.
Signal an error if the file is set but not readable."
  (when flywrite-api-key-file
    (unless (file-readable-p flywrite-api-key-file)
      (error "flywrite-api-key-file %s not found or not readable"
             flywrite-api-key-file))
    (let ((key (string-trim
                (with-temp-buffer
                  (insert-file-contents flywrite-api-key-file)
                  (buffer-substring-no-properties
                   (point-min) (line-end-position))))))
      (when (> (length key) 0) key))))

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

(defun flywrite--test-connection ()
  "Send a test request to verify the API connection.
Shows status in the minibuffer.  On failure, suggests enabling
`flywrite-debug' for troubleshooting."
  (message "flywrite: testing connection")
  (flywrite--log "Connection test: starting")
  (condition-case err
      (let* ((_ (unless flywrite-api-url
                  (error "flywrite-api-url is not set.  Try M-x customize-variable flywrite-api-url")))
             (text "The quick brown fox jumped over the lazy dog.")
             (api-key (flywrite--get-api-key))
             (anthropic-p (flywrite--anthropic-api-p))
             (local-p (and flywrite-api-url
                          (string-match-p "\\(?:localhost\\|127\\.0\\.0\\.1\\)" flywrite-api-url)))
             (_ (when (and (not api-key) (not local-p))
                  (error "API key is not set.  See the README for configuration")))
             (system-msg (if (and anthropic-p flywrite-enable-caching)
                             `[((type . "text")
                                (text . ,flywrite-system-prompt)
                                (cache_control . ((type . "ephemeral"))))]
                           flywrite-system-prompt))
             (payload (json-encode
                       (if anthropic-p
                           `((model . ,flywrite-model)
                             (max_tokens . 300)
                             (system . ,system-msg)
                             (messages . [((role . "user")
                                           (content . ,text))]))
                         `((model . ,flywrite-model)
                           (max_tokens . 300)
                           (messages . [((role . "system")
                                         (content . ,flywrite-system-prompt))
                                        ((role . "user")
                                         (content . ,text))])))))
             (url-request-method "POST")
             (url-request-extra-headers
              (append `(("Content-Type" . "application/json")
                        ,@(cond
                           (anthropic-p
                            `(("x-api-key" . ,api-key)
                              ("anthropic-version" . "2023-06-01")))
                           (api-key
                            `(("Authorization" . ,(concat "Bearer " api-key))))))
                      flywrite-api-headers))
             (url-request-data (encode-coding-string payload 'utf-8)))
        (flywrite--log "Connection test: sending request to %s JSON=%s" flywrite-api-url payload)
        (url-retrieve
         flywrite-api-url
         (lambda (status)
           (unwind-protect
               (condition-case cb-err
                   (progn
                     (when (plist-get status :error)
                       (error "API request failed: %s" (plist-get status :error)))
                     (goto-char (point-min))
                     (unless (re-search-forward "\r?\n\r?\n" nil t)
                       (error "Malformed HTTP response"))
                     (let ((json-data (json-read)))
                       (flywrite--log "Connection test response: success JSON=%S" json-data))
                     (message "flywrite: connection test success"))
                 (error
                  (flywrite--log "Connection test failed: %s JSON=%s"
                                  (error-message-string cb-err)
                                  (ignore-errors
                                    (goto-char (point-min))
                                    (when (re-search-forward "\r?\n\r?\n" nil t)
                                      (buffer-substring-no-properties (point) (point-max)))))
                  (message "flywrite: connection test failed: %s.  Enable `flywrite-debug' and check *flywrite-log* for details."
                           (error-message-string cb-err))))
             (kill-buffer (current-buffer))))
         nil t t))
    (error
     (flywrite--log "Connection test failed: %s" (error-message-string err))
     (message "flywrite: connection test failed: %s.  Enable `flywrite-debug' and check *flywrite-log* for details."
              (error-message-string err)))))

(defun flywrite--send-request (buf beg end hash)
  "Send an API request for the text in BUF between BEG and END.
HASH is the content hash at time of dispatch for stale checking."
  ;; Skip if already checked (catches duplicates from queue)
  (if (with-current-buffer buf
        (gethash hash flywrite--checked-sentences))
      (flywrite--log "Skipping already-checked hash=%s" hash)
    (unless flywrite-api-url
      (flywrite--log "ERROR: flywrite-api-url is not set")
      (error "flywrite-api-url is not set.  See the README for configuration"))
    (let* ((text (with-current-buffer buf
                    (buffer-substring-no-properties beg end)))
           (api-key (flywrite--get-api-key))
         (anthropic-p (flywrite--anthropic-api-p))
         (system-msg (if (and anthropic-p flywrite-enable-caching)
                         `[((type . "text")
                            (text . ,flywrite-system-prompt)
                            (cache_control . ((type . "ephemeral"))))]
                       flywrite-system-prompt))
         (payload (json-encode
                   (if anthropic-p
                       `((model . ,flywrite-model)
                         (max_tokens . 300)
                         (system . ,system-msg)
                         (messages . [((role . "user")
                                       (content . ,text))]))
                     `((model . ,flywrite-model)
                       (max_tokens . 300)
                       (messages . [((role . "system")
                                     (content . ,flywrite-system-prompt))
                                    ((role . "user")
                                     (content . ,text))])))))
         (url-request-method "POST")
         (url-request-extra-headers
          (append `(("Content-Type" . "application/json")
                    ,@(cond
                       (anthropic-p
                        (unless api-key
                          (error "Anthropic API requires an API key"))
                        `(("x-api-key" . ,api-key)
                          ("anthropic-version" . "2023-06-01")))
                       (api-key
                        `(("Authorization" . ,(concat "Bearer " api-key))))))
                  flywrite-api-headers))
         (url-request-data (encode-coding-string payload 'utf-8))
         (start-time (current-time)))
    (flywrite--log "API call: [%d-%d] buf=%s url=%s text=%.80s hash=%s"
                   beg end (buffer-name buf) flywrite-api-url text hash)
    (with-current-buffer buf
      (cl-incf flywrite--in-flight)
      ;; Mark as checked now to prevent duplicate in-flight requests
      (puthash hash t flywrite--checked-sentences))
    (let ((conn-buf
           (url-retrieve
            flywrite-api-url
            (lambda (status)
              (flywrite--handle-response status buf beg end hash start-time))
            nil t t)))
      (when (and conn-buf (buffer-live-p conn-buf))
        (with-current-buffer buf
          (push conn-buf flywrite--connection-buffers)))))))

;;;; ---- Response handler ----

(defun flywrite--handle-response (status buf beg end hash start-time)
  "Handle API response.
STATUS is from `url-retrieve'.  BUF, BEG, END, HASH identify the
request.  START-TIME is used for latency logging."
  (let ((latency (float-time (time-subtract (current-time) start-time)))
        (response-buf (current-buffer))
        (duplicate nil))
    ;; Guard against duplicate callbacks (url-retrieve can fire twice
    ;; on connection errors: once for "failed", once for "deleted").
    ;; Use a buffer-local flag on the response buffer.
    (when (buffer-live-p response-buf)
      (with-current-buffer response-buf
        (if (bound-and-true-p flywrite--response-handled)
            (progn
              (flywrite--log "Ignoring duplicate callback for hash=%s"
                             hash)
              (setq duplicate t))
          (setq-local flywrite--response-handled t))))
    (if duplicate
        (when (buffer-live-p response-buf)
          (kill-buffer response-buf))
    ;; Remove from connection tracking
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq flywrite--connection-buffers
              (delq response-buf flywrite--connection-buffers))))
    (unwind-protect
        (condition-case err
            (progn
              ;; Check for HTTP errors
              (when (plist-get status :error)
                (let* ((err-info (plist-get status :error))
                       (err-body (save-excursion
                                   (goto-char (point-min))
                                   (when (re-search-forward "\r?\n\r?\n" nil t)
                                     (truncate-string-to-width
                                      (buffer-substring-no-properties (point) (point-max))
                                      500 nil nil t)))))
                  (flywrite--log "API HTTP error: %s (%.2fs) hash=%s\nResponse body: %s"
                                 err-info latency hash (or err-body "<empty>"))
                  ;; On 429, also clear pending queue to stop hammering
                  (when (and (listp err-info)
                             (member 429 err-info))
                    (flywrite--log "Rate limited (429) hash=%s"
                                   hash)
                    (when (buffer-live-p buf)
                      (with-current-buffer buf
                        (when flywrite--pending-queue
                          (flywrite--log "Clearing %d queued requests due to rate limit hash=%s"
                                         (length flywrite--pending-queue) hash)
                          (setq flywrite--pending-queue nil)))))
                  (error "API request failed: %s" err-info)))

              ;; Extract HTTP status code and skip headers
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

                (flywrite--log "Response: HTTP %s %.2fs hash=%s JSON=%S"
                               (or http-status "?") latency hash json-data)

                (unless text
                  (flywrite--log "Response had no extractable text, skipping hash=%s json=%S"
                                 hash json-data))
                (when (and text (buffer-live-p buf))
                  (with-current-buffer buf
                    ;; Stale check: verify the sentence hasn't changed
                    (if (or (> end (point-max))
                            (< beg (point-min))
                            (not (string= hash (flywrite--content-hash beg end))))
                        (progn
                          (flywrite--log "Stale response discarded: [%d-%d] hash=%s" beg end hash)
                          ;; Remove stale hash so updated content can be checked
                          (remhash hash flywrite--checked-sentences)
                          ;; Re-dirty so it gets re-checked
                          (let ((new-hash (when (and (<= beg (point-max))
                                                     (<= end (point-max)))
                                            (flywrite--content-hash beg end))))
                            (when (and new-hash (not (gethash new-hash flywrite--checked-sentences)))
                              (push (list beg end new-hash) flywrite--dirty-registry))))

                      ;; Parse suggestions (strip markdown code fences if present)
                      (condition-case parse-err
                          (let* ((clean-text (replace-regexp-in-string
                                              "\\`[ \t\n]*```\\(?:json\\)?[ \t]*\n?" ""
                                              (replace-regexp-in-string
                                               "\n?```[ \t\n]*\\'" "" text)))
                                 (parsed (json-read-from-string clean-text))
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
                            (dolist (suggestion (append suggestions nil))
                              (let* ((quote-str (alist-get 'quote suggestion))
                                     (reason (alist-get 'reason suggestion))
                                     (region-text (buffer-substring-no-properties beg end))
                                     (match-pos (and quote-str
                                                     (string-match (regexp-quote quote-str)
                                                                   region-text))))
                                (if match-pos
                                    (let ((diag-beg (+ beg match-pos))
                                          (diag-end (+ beg match-pos (length quote-str))))
                                      (push (flymake-make-diagnostic
                                             buf diag-beg diag-end :note
                                             (concat reason " [flywrite]"))
                                            flywrite--diagnostics)
                                      (flywrite--log "Diagnostic: [%d-%d] %s hash=%s"
                                                     diag-beg diag-end reason hash))
                                  (flywrite--log "Quote not found, skipping: %s hash=%s" quote-str hash))))
                            ;; Report all diagnostics to flymake
                            (if flywrite--report-fn
                                (funcall flywrite--report-fn flywrite--diagnostics)
                              (flywrite--log "Warning: report-fn nil, diag-fns=%s hash=%s"
                                             flymake-diagnostic-functions hash)
                              ;; Re-add backend if something removed it
                              (unless (memq #'flywrite-flymake
                                            flymake-diagnostic-functions)
                                (flywrite--log "Re-adding flywrite-flymake backend hash=%s" hash)
                                (add-hook 'flymake-diagnostic-functions
                                          #'flywrite-flymake nil t))
                              (when (bound-and-true-p flymake-mode)
                                (flymake-start)))
                            ;; Mark as checked
                            (puthash hash t flywrite--checked-sentences))
                        (error
                         (flywrite--log "LLM returned unparseable response: %s hash=%s\nRaw text: %s"
                                        (error-message-string parse-err) hash text)
                         (message "flywrite: LLM returned invalid JSON (not a bug in flywrite). Enable `flywrite-debug' and check *flywrite-log* for details.")))))))))
          (error
           (flywrite--log "Response handler error: %s hash=%s" (error-message-string err) hash)
           (message "flywrite: API error: %s" (error-message-string err))
           ;; Keep hash in checked-sentences to prevent automatic retry.
           ;; User can use flywrite-clear or flywrite-check-at-point to
           ;; force a recheck after fixing connectivity / rate limits.
           ))

      ;; Always: decrement counter and drain queue
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (cl-decf flywrite--in-flight)
          (when (< flywrite--in-flight 0)
            (setq flywrite--in-flight 0))
          (flywrite--drain-queue)))
      ;; Clean up response buffer
      (kill-buffer response-buf)))))

;;;; ---- Idle timer callback ----

(defun flywrite--idle-timer-fn (buf)
  "Idle timer callback for buffer BUF.
Snapshots and clears the dirty registry, dispatches or queues requests."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when flywrite-mode
        (when flywrite-eager
          (condition-case err
              (save-excursion
                (let (pbeg pend)
                  (backward-paragraph)
                  (skip-chars-forward " \t\n")
                  (setq pbeg (point))
                  (forward-paragraph)
                  (skip-chars-backward " \t\n")
                  (setq pend (point))
                  (when (> pend pbeg)
                    (dolist (entry (flywrite--collect-units-in-region pbeg pend))
                      (push entry flywrite--dirty-registry)))))
            (error
             (flywrite--log "Error in eager scan: %s buf=%s"
                            (error-message-string err) (buffer-name)))))
        (when flywrite--dirty-registry
          (let ((snapshot flywrite--dirty-registry)
                (seen (make-hash-table :test 'equal)))
            (setq flywrite--dirty-registry nil)
          (dolist (entry snapshot)
            (let ((beg (nth 0 entry))
                  (end (nth 1 entry))
                  (hash (nth 2 entry)))
              ;; Re-verify bounds, skip check, and dedup by hash
              (when (and (<= end (point-max))
                         (>= beg (point-min))
                         (not (gethash hash flywrite--checked-sentences))
                         (not (gethash hash seen))
                         (or (not (flywrite--should-skip-p beg))
                             (progn
                               (flywrite--log "Skipped (non-prose region): [%d-%d] hash=%s" beg end hash)
                               nil)))
                (puthash hash t seen)
                (if (< flywrite--in-flight flywrite-max-concurrent)
                    (flywrite--send-request buf beg end hash)
                  (progn
                    (flywrite--log "Queued: [%d-%d] (at cap %d) hash=%s" beg end flywrite--in-flight hash)
                    (setq flywrite--pending-queue
                          (append flywrite--pending-queue
                                  (list (list buf beg end hash)))))))))))))))

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
                 (not (gethash hash (buffer-local-value 'flywrite--checked-sentences buf))))
        (flywrite--log "Draining queue: [%d-%d] hash=%s" beg end hash)
        (flywrite--send-request buf beg end hash)))))

;;;; ---- Flymake backend ----

(defun flywrite-flymake (report-fn &rest _args)
  "Flymake backend for flywrite.  Stores REPORT-FN for later use.
Reports any existing diagnostics immediately so flymake can display them."
  (flywrite--log "flywrite-flymake called by flymake, report-fn set")
  (setq flywrite--report-fn report-fn)
  (funcall report-fn flywrite--diagnostics))

;;;; ---- Interactive commands ----

(defun flywrite--collect-units-in-region (beg end)
  "Collect all sentence/paragraph units in region BEG to END.
Returns a list of (unit-beg unit-end hash) triples."
  (let ((units nil)
        (seen (make-hash-table :test 'eql))
        (pos beg))
    (save-excursion
      (goto-char pos)
      (while (< (point) end)
        (let* ((bounds (flywrite--unit-bounds-at-pos (point)))
               (ubeg (car bounds))
               (uend (cdr bounds)))
          (when (and (> uend ubeg) (<= uend end)
                     (not (gethash ubeg seen)))
            (puthash ubeg t seen)
            (let ((hash (flywrite--content-hash ubeg uend)))
              (unless (or (gethash hash flywrite--checked-sentences)
                          (flywrite--should-skip-p ubeg)
)                (push (list ubeg uend hash) units))))
          ;; Move past current unit and inter-sentence whitespace
          (goto-char (max (1+ (point)) uend))
          (skip-chars-forward " \t\n"))))
    (nreverse units)))

(defun flywrite-check-buffer ()
  "Queue all sentences in the buffer for checking.
Prompts for confirmation when the count exceeds
`flywrite-check-confirm-threshold'."
  (interactive)
  (unless flywrite-mode
    (user-error "flywrite-mode is not enabled"))
  (let ((units (flywrite--collect-units-in-region (point-min) (point-max))))
    (when (and (> (length units) flywrite-check-confirm-threshold)
               (not (y-or-n-p (format "Check %d sentences? " (length units)))))
      (user-error "Cancelled"))
    (let ((count 0))
      (dolist (entry units)
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
      (message "flywrite: queued %d sentences for checking" count))))

(defun flywrite-check-region (beg end)
  "Queue all sentences in the region for checking.
Prompts for confirmation when the count exceeds
`flywrite-check-confirm-threshold'."
  (interactive "r")
  (unless flywrite-mode
    (user-error "flywrite-mode is not enabled"))
  (unless (use-region-p)
    (user-error "No active region"))
  (let ((units (flywrite--collect-units-in-region beg end)))
    (when (and (> (length units) flywrite-check-confirm-threshold)
               (not (y-or-n-p (format "Check %d sentences? " (length units)))))
      (user-error "Cancelled"))
    (let ((count 0))
      (dolist (entry units)
        ;; Remove from checked so re-checks work
        (remhash (nth 2 entry) flywrite--checked-sentences)
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
      (message "flywrite: queued %d sentences in region for checking" count)
      ;; Dispatch immediately rather than waiting for idle timer
      (flywrite--idle-timer-fn (current-buffer)))))

(defun flywrite-check-at-point ()
  "Queue the sentence or paragraph at point for checking.
Respects `flywrite-granularity'."
  (interactive)
  (unless flywrite-mode
    (user-error "flywrite-mode is not enabled"))
  (let* ((bounds (flywrite--unit-bounds-at-pos (point)))
         (ubeg (car bounds))
         (uend (cdr bounds))
         (hash (flywrite--content-hash ubeg uend)))
    (when (flywrite--should-skip-p ubeg)
      (user-error "Point is in a skipped region"))
    ;; Remove from checked so it gets re-checked even if seen before
    (remhash hash flywrite--checked-sentences)
    (push (list ubeg uend hash) flywrite--dirty-registry)
    (message "flywrite: queued %s at point for checking"
             (if (eq flywrite-granularity 'paragraph) "paragraph" "sentence"))
    ;; Dispatch immediately rather than waiting for idle timer
    (flywrite--idle-timer-fn (current-buffer))))

(defun flywrite-clear ()
  "Clear all flywrite diagnostics and reset caches."
  (interactive)
  (setq flywrite--diagnostics nil)
  (setq flywrite--dirty-registry nil)
  (setq flywrite--pending-queue nil)
  (clrhash flywrite--checked-sentences)
  (when flywrite--report-fn
    (funcall flywrite--report-fn nil))
  (when (bound-and-true-p flymake-mode)
    (flymake-start))
  (message "flywrite: cleared all diagnostics and caches"))

;;;; ---- Minor mode definition ----

;;;###autoload
(define-minor-mode flywrite-mode
  "Minor mode for inline writing suggestions via LLM.
Provides sentence-level grammar, clarity, and style feedback as
flymake diagnostics."
  :lighter " FlyW"
  :group 'flywrite
  (cond
   ((not flywrite-mode)
    (flywrite--disable))
   (flywrite--idle-timer
    ;; Already active — skip duplicate setup (e.g., multiple hooks firing)
    nil)
   (t
    (flywrite--enable))))

(defun flywrite--ensure-flymake-backend ()
  "Ensure `flywrite-flymake' is in `flymake-diagnostic-functions'.
Eglot replaces the buffer-local value with only its own backend."
  (when (and flywrite-mode
             (not (memq #'flywrite-flymake flymake-diagnostic-functions)))
    (flywrite--log "Re-adding flywrite-flymake after eglot setup")
    (add-hook 'flymake-diagnostic-functions #'flywrite-flymake nil t)))

(defun flywrite--enable ()
  "Set up flywrite-mode in the current buffer."
  ;; Initialize buffer-local state
  (setq flywrite--dirty-registry nil)
  (setq flywrite--checked-sentences (make-hash-table :test 'equal))
  (setq flywrite--in-flight 0)
  (setq flywrite--pending-queue nil)
  (setq flywrite--connection-buffers nil)
  (setq flywrite--diagnostics nil)
  (setq flywrite--report-fn nil)

  ;; Hook into after-change-functions
  (add-hook 'after-change-functions #'flywrite--after-change nil t)

  ;; Enable flymake and add our backend
  (unless (bound-and-true-p flymake-mode)
    (flymake-mode 1))
  (add-hook 'flymake-diagnostic-functions #'flywrite-flymake nil t)

  ;; Re-add our backend after eglot setup (eglot replaces
  ;; flymake-diagnostic-functions with only its own backend)
  (when (fboundp 'eglot-managed-mode-hook)
    (add-hook 'eglot-managed-mode-hook #'flywrite--ensure-flymake-backend nil t))

  ;; Start idle timer
  (setq flywrite--idle-timer
        (run-with-idle-timer flywrite-idle-delay t
                             #'flywrite--idle-timer-fn (current-buffer)))

  (flywrite--log "flywrite-mode enabled in %s (emacs %s, url=%s, model=%s, granularity=%s, idle=%.1f, max-concurrent=%d, eager=%s, caching=%s)"
                 (buffer-name) emacs-version
                 (or flywrite-api-url "nil")
                 flywrite-model flywrite-granularity
                 flywrite-idle-delay flywrite-max-concurrent
                 flywrite-eager flywrite-enable-caching)

  ;; Test API connection on startup
  (when flywrite-test-on-load
    (flywrite--test-connection)))

(defun flywrite--disable ()
  "Tear down flywrite-mode in the current buffer."
  (flywrite--log "flywrite-mode disabled in %s (in-flight=%d, pending=%d, dirty=%d)"
                 (buffer-name) flywrite--in-flight
                 (length flywrite--pending-queue)
                 (length flywrite--dirty-registry))
  ;; Cancel idle timer
  (when flywrite--idle-timer
    (cancel-timer flywrite--idle-timer)
    (setq flywrite--idle-timer nil))

  ;; Kill in-flight HTTP connection buffers so network processes don't linger
  (dolist (conn-buf flywrite--connection-buffers)
    (when (buffer-live-p conn-buf)
      (let ((proc (get-buffer-process conn-buf)))
        (when proc
          (delete-process proc)))
      (kill-buffer conn-buf)))
  (setq flywrite--connection-buffers nil)

  ;; Remove hooks
  (remove-hook 'after-change-functions #'flywrite--after-change t)
  (remove-hook 'flymake-diagnostic-functions #'flywrite-flymake t)
  (remove-hook 'eglot-managed-mode-hook #'flywrite--ensure-flymake-backend t)

  ;; Clear diagnostics
  (when flywrite--report-fn
    (funcall flywrite--report-fn nil))
  (setq flywrite--diagnostics nil)
  (setq flywrite--dirty-registry nil)
  (setq flywrite--pending-queue nil)
  (clrhash flywrite--checked-sentences))

(provide 'flywrite-mode)

;;; flywrite-mode.el ends here
