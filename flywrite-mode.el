;;; flywrite-mode.el --- Inline writing suggestions via LLM -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Andrew DeOrio
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: writing, style, grammar, flymake
;; URL: https://github.com/awdeorio/flywrite

;; This file is not part of GNU Emacs.

;;; Commentary:

;; flywrite-mode is a minor mode that provides inline writing suggestions
;; powered by the Anthropic LLM API.  Suggestions appear as flymake
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
  "Anthropic API key.
Falls back to `flywrite-api-key-file', then the ANTHROPIC_API_KEY
environment variable."
  :type '(choice (const :tag "Use file or env var" nil)
                 (string :tag "API key"))
  :group 'flywrite)

(defcustom flywrite-api-key-file nil
  "Path to a file containing the Anthropic API key.
The file should contain the key on its first line.  Leading and
trailing whitespace is stripped.  Checked when `flywrite-api-key'
is nil, before falling back to the ANTHROPIC_API_KEY env var."
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

(defcustom flywrite-debug nil
  "When non-nil, log API calls, responses, and events to `*flywrite-log*'."
  :type 'boolean
  :group 'flywrite)

;;;; ---- Buffer-local state ----

(defvar-local flywrite--dirty-registry nil
  "List of (beg end hash) triples for sentences needing a check.")

(defvar-local flywrite--checked-sentences (make-hash-table :test 'equal)
  "Hash table mapping content-hash → t for already-checked sentences.")

(defvar-local flywrite--in-flight 0
  "Counter of in-flight API requests.")

(defvar-local flywrite--pending-queue nil
  "FIFO list of (buf beg end hash) entries waiting for an API slot.")

(defvar-local flywrite--idle-timer nil
  "The idle timer object for this buffer.")

(defvar-local flywrite--report-fn nil
  "The flymake report function, stored when the backend is invoked.")

(defvar-local flywrite--diagnostics nil
  "Accumulated list of flymake diagnostics for this buffer.")

;;;; ---- Constants ----

(defconst flywrite--api-url "https://api.anthropic.com/v1/messages"
  "Anthropic Messages API endpoint.")

(defconst flywrite--system-prompt
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
- Do not flag correct sentences"
  "System prompt sent with every API call.")

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
      ;; sentence granularity
      (let (beg end)
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
                (flywrite--log "Dirty: [%d-%d] hash=%s" ubeg uend (substring hash 0 8))))))
      (error
       (flywrite--log "Error in after-change: %s" (error-message-string err))))))

;;;; ---- API call ----

(defun flywrite--read-api-key-file ()
  "Read and return the API key from `flywrite-api-key-file', or nil."
  (when (and flywrite-api-key-file
             (file-readable-p flywrite-api-key-file))
    (let ((key (string-trim
                (with-temp-buffer
                  (insert-file-contents flywrite-api-key-file)
                  (buffer-substring-no-properties
                   (point-min) (line-end-position))))))
      (when (> (length key) 0) key))))

(defun flywrite--get-api-key ()
  "Return the API key.
Checks `flywrite-api-key', then `flywrite-api-key-file', then
the ANTHROPIC_API_KEY environment variable."
  (or flywrite-api-key
      (flywrite--read-api-key-file)
      (getenv "ANTHROPIC_API_KEY")
      (error "No API key: set `flywrite-api-key', `flywrite-api-key-file', or ANTHROPIC_API_KEY env var")))

(defun flywrite--send-request (buf beg end hash)
  "Send an API request for the text in BUF between BEG and END.
HASH is the content hash at time of dispatch for stale checking."
  (let* ((text (with-current-buffer buf
                 (buffer-substring-no-properties beg end)))
         (api-key (flywrite--get-api-key))
         (system-msg (if flywrite-enable-caching
                         `[((type . "text")
                            (text . ,flywrite--system-prompt)
                            (cache_control . ((type . "ephemeral"))))]
                       flywrite--system-prompt))
         (payload (json-encode
                   `((model . ,flywrite-model)
                     (max_tokens . 300)
                     (system . ,system-msg)
                     (messages . [((role . "user")
                                   (content . ,text))]))))
         (url-request-method "POST")
         (url-request-extra-headers
          `(("Content-Type" . "application/json")
            ("x-api-key" . ,api-key)
            ("anthropic-version" . "2023-06-01")))
         (url-request-data (encode-coding-string payload 'utf-8))
         (start-time (current-time)))
    (flywrite--log "API call: [%d-%d] text=%.40s hash=%s"
                   beg end text (substring hash 0 8))
    (with-current-buffer buf
      (cl-incf flywrite--in-flight))
    (url-retrieve
     flywrite--api-url
     (lambda (status)
       (flywrite--handle-response status buf beg end hash start-time))
     nil t t)))

;;;; ---- Response handler ----

(defun flywrite--handle-response (status buf beg end hash start-time)
  "Handle API response.
STATUS is from `url-retrieve'.  BUF, BEG, END, HASH identify the
request.  START-TIME is used for latency logging."
  (let ((latency (float-time (time-subtract (current-time) start-time)))
        (response-buf (current-buffer)))
    (unwind-protect
        (condition-case err
            (progn
              ;; Check for HTTP errors
              (when (plist-get status :error)
                (flywrite--log "HTTP error: %s (%.2fs)" (plist-get status :error) latency)
                (error "HTTP error: %s" (plist-get status :error)))

              ;; Skip HTTP headers
              (goto-char (point-min))
              (unless (re-search-forward "\r?\n\r?\n" nil t)
                (error "Malformed HTTP response"))

              ;; Parse JSON body (json-read returns alists with symbol keys)
              (let* ((json-data (json-read))
                     (content (alist-get 'content json-data))
                     (text-block (and (arrayp content) (> (length content) 0)
                                      (aref content 0)))
                     (text (and text-block (alist-get 'text text-block))))

                (flywrite--log "Response: %.2fs hash=%s" latency (substring hash 0 8))

                (when (and text (buffer-live-p buf))
                  (with-current-buffer buf
                    ;; Stale check: verify the sentence hasn't changed
                    (if (or (> end (point-max))
                            (< beg (point-min))
                            (not (string= hash (flywrite--content-hash beg end))))
                        (progn
                          (flywrite--log "Stale response discarded: [%d-%d]" beg end)
                          ;; Re-dirty so it gets re-checked
                          (let ((new-hash (when (and (<= beg (point-max))
                                                     (<= end (point-max)))
                                            (flywrite--content-hash beg end))))
                            (when (and new-hash (not (gethash new-hash flywrite--checked-sentences)))
                              (push (list beg end new-hash) flywrite--dirty-registry))))

                      ;; Parse suggestions
                      (condition-case parse-err
                          (let* ((parsed (json-read-from-string text))
                                 (suggestions (alist-get 'suggestions parsed)))
                            (flywrite--log "Suggestions: %d for [%d-%d]"
                                           (length suggestions) beg end)
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
                                             buf diag-beg diag-end :note reason)
                                            flywrite--diagnostics)
                                      (flywrite--log "Diagnostic: [%d-%d] %s"
                                                     diag-beg diag-end reason))
                                  (flywrite--log "Quote not found, skipping: %s" quote-str))))
                            ;; Report all diagnostics to flymake
                            (when flywrite--report-fn
                              (funcall flywrite--report-fn flywrite--diagnostics))
                            ;; Mark as checked
                            (puthash hash t flywrite--checked-sentences))
                        (error
                         (flywrite--log "JSON parse error: %s" (error-message-string parse-err)))))))))
          (error
           (flywrite--log "Response handler error: %s" (error-message-string err))))

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

(defun flywrite--idle-timer-fn (buf)
  "Idle timer callback for buffer BUF.
Snapshots and clears the dirty registry, dispatches or queues requests."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and flywrite-mode flywrite--dirty-registry)
        (let ((snapshot flywrite--dirty-registry))
          (setq flywrite--dirty-registry nil)
          (dolist (entry snapshot)
            (let ((beg (nth 0 entry))
                  (end (nth 1 entry))
                  (hash (nth 2 entry)))
              ;; Re-verify bounds and skip check
              (when (and (<= end (point-max))
                         (>= beg (point-min))
                         (not (flywrite--should-skip-p beg))
                         (not (gethash hash flywrite--checked-sentences)))
                (if (< flywrite--in-flight flywrite-max-concurrent)
                    (flywrite--send-request buf beg end hash)
                  (progn
                    (flywrite--log "Queued: [%d-%d] (at cap %d)" beg end flywrite--in-flight)
                    (setq flywrite--pending-queue
                          (append flywrite--pending-queue
                                  (list (list buf beg end hash))))))))))))))

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
        (flywrite--log "Draining queue: [%d-%d]" beg end)
        (flywrite--send-request buf beg end hash)))))

;;;; ---- Flymake backend ----

(defun flywrite-flymake (report-fn &rest _args)
  "Flymake backend for flywrite.  Stores REPORT-FN for later use."
  (setq flywrite--report-fn report-fn))

;;;; ---- Interactive commands ----

(defun flywrite--collect-units-in-region (beg end)
  "Collect all sentence/paragraph units in region BEG to END.
Returns a list of (unit-beg unit-end hash) triples."
  (let ((units nil)
        (pos beg))
    (save-excursion
      (goto-char pos)
      (while (< (point) end)
        (let* ((bounds (flywrite--unit-bounds-at-pos (point)))
               (ubeg (car bounds))
               (uend (cdr bounds)))
          (when (and (> uend ubeg) (<= uend end))
            (let ((hash (flywrite--content-hash ubeg uend)))
              (unless (or (gethash hash flywrite--checked-sentences)
                          (flywrite--should-skip-p ubeg))
                (push (list ubeg uend hash) units))))
          ;; Move past current unit
          (goto-char (max (1+ (point)) uend)))))
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
    (dolist (entry units)
      (push entry flywrite--dirty-registry))
    (message "flywrite: queued %d sentences for checking" (length units))))

(defun flywrite-check-paragraph ()
  "Queue all sentences in the current paragraph for checking."
  (interactive)
  (unless flywrite-mode
    (user-error "flywrite-mode is not enabled"))
  (let* ((para-beg (save-excursion (backward-paragraph) (point)))
         (para-end (save-excursion (forward-paragraph) (point)))
         (units (flywrite--collect-units-in-region para-beg para-end)))
    (dolist (entry units)
      (push entry flywrite--dirty-registry))
    (message "flywrite: queued %d sentences for checking" (length units))))

(defun flywrite-clear ()
  "Clear all flywrite diagnostics and reset caches."
  (interactive)
  (setq flywrite--diagnostics nil)
  (setq flywrite--dirty-registry nil)
  (setq flywrite--pending-queue nil)
  (clrhash flywrite--checked-sentences)
  (when flywrite--report-fn
    (funcall flywrite--report-fn nil))
  (message "flywrite: cleared all diagnostics and caches"))

;;;; ---- Keymap ----

(defvar flywrite-mode-map
  (let ((map (make-sparse-keymap))
        (prefix (make-sparse-keymap)))
    (define-key prefix "b" #'flywrite-check-buffer)
    (define-key prefix "p" #'flywrite-check-paragraph)
    (define-key prefix "c" #'flywrite-clear)
    (define-key map (kbd "C-c C-g") prefix)
    map)
  "Keymap for `flywrite-mode'.")

;;;; ---- Minor mode definition ----

;;;###autoload
(define-minor-mode flywrite-mode
  "Minor mode for inline writing suggestions via LLM.
Provides sentence-level grammar, clarity, and style feedback as
flymake diagnostics."
  :lighter " FlyW"
  :keymap flywrite-mode-map
  :group 'flywrite
  (if flywrite-mode
      (flywrite--enable)
    (flywrite--disable)))

(defun flywrite--enable ()
  "Set up flywrite-mode in the current buffer."
  ;; Initialize buffer-local state
  (setq flywrite--dirty-registry nil)
  (setq flywrite--checked-sentences (make-hash-table :test 'equal))
  (setq flywrite--in-flight 0)
  (setq flywrite--pending-queue nil)
  (setq flywrite--diagnostics nil)
  (setq flywrite--report-fn nil)

  ;; Hook into after-change-functions
  (add-hook 'after-change-functions #'flywrite--after-change nil t)

  ;; Enable flymake and add our backend
  (unless (bound-and-true-p flymake-mode)
    (flymake-mode 1))
  (add-hook 'flymake-diagnostic-functions #'flywrite-flymake nil t)

  ;; Start idle timer
  (setq flywrite--idle-timer
        (run-with-idle-timer flywrite-idle-delay t
                             #'flywrite--idle-timer-fn (current-buffer)))

  (flywrite--log "flywrite-mode enabled in %s" (buffer-name)))

(defun flywrite--disable ()
  "Tear down flywrite-mode in the current buffer."
  ;; Cancel idle timer
  (when flywrite--idle-timer
    (cancel-timer flywrite--idle-timer)
    (setq flywrite--idle-timer nil))

  ;; Remove hooks
  (remove-hook 'after-change-functions #'flywrite--after-change t)
  (remove-hook 'flymake-diagnostic-functions #'flywrite-flymake t)

  ;; Clear diagnostics
  (when flywrite--report-fn
    (funcall flywrite--report-fn nil))
  (setq flywrite--diagnostics nil)
  (setq flywrite--dirty-registry nil)
  (setq flywrite--pending-queue nil)
  (clrhash flywrite--checked-sentences)

  (flywrite--log "flywrite-mode disabled in %s" (buffer-name)))

(provide 'flywrite-mode)

;;; flywrite-mode.el ends here
