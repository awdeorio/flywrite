;;; test-flywrite-prompt.el --- Prompt regression tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Regression tests that send text samples to a real LLM API and verify
;; each system prompt catches (or does not flag) specific writing flaws.
;; Every prompt style in `flywrite--prompt-alist' is tested.
;;
;; Requires FLYWRITE_API_KEY_ANTHROPIC env var.
;; Results are cached in test-flywrite-prompt-cache.json to avoid
;; redundant API calls.
;;
;; Run with:
;;   emacs -Q --batch -l flywrite-mode.el -l test-flywrite-prompt.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'flywrite-mode)
(require 'json)
(require 'url)
(require 'url-http)

;;;; ---- Test inputs ----
(defconst flywrite-prompt-test--inputs
  '((:text "The quick brown fox jumped over the lazy dog."
     :description "clean"
     :expected ((prose . 0) (academic . 0)))
    (:text "The morning light filtered through the curtains and cast long shadows across the floor."
     :description "clean"
     :expected ((prose . 0) (academic . 0)))
    (:text "She picked up her coffee, took a quiet sip, and turned to the first page of the newspaper."
     :description "clean"
     :expected ((prose . 0) (academic . 0)))
    (:text "The results don't support the hypothesis, and it's really not a big deal."
     :description "contractions and informal language in academic writing"
     :expected ((prose . 1) (academic . 2)))
    (:text "Him and his friend went to the store to buy some grocerys."
     :description "pronoun case error and misspelling"
     :expected ((prose . 2) (academic . 2)))
    (:text "Their going to the park later today, irregardless of the rain."
     :description "wrong homophone and nonstandard word"
     :expected ((prose . 2) (academic . 2)))
    (:text "Each of the students need to submit there homework by Friday."
     :description "subject-verb disagreement and wrong homophone"
     :expected ((prose . 2) (academic . 2)))
    (:text "She could of finished the report on time if she would have started earlier."
     :description "could of and would have"
     :expected ((prose . 2) (academic . 2)))
    (:text "Between you and I, this project is more bigger than we expected."
     :description "pronoun case and double comparative"
     :expected ((prose . 2) (academic . 2)))
    (:text "The weather was very extremely hot outside yesterday."
     :description "redundant intensifiers"
     :expected ((prose . 1) (academic . 1))))
  "Test inputs: each entry is a plist with :text, :description, :expected.
:expected is an alist mapping each prompt style symbol to its
expected suggestion count, e.g., ((prose . 0) (academic . 2)).
Every style in `flywrite--prompt-alist' must have an entry.")

;;;; ---- Cache ----

(defvar flywrite-prompt-test--cache-file
  (expand-file-name "test-flywrite-prompt-cache.json"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the prompt test cache file.")

(defvar flywrite-prompt-test--cache nil
  "In-memory cache: list of alists read from the cache file.")

(defun flywrite-prompt-test--load-cache ()
  "Load cache from `flywrite-prompt-test--cache-file'."
  (setq flywrite-prompt-test--cache
        (if (file-readable-p flywrite-prompt-test--cache-file)
            (condition-case nil
                (let ((json-array-type 'list)
                      (json-object-type 'alist)
                      (json-key-type 'string))
                  (json-read-file flywrite-prompt-test--cache-file))
              (error nil))
          nil)))

(defun flywrite-prompt-test--save-cache ()
  "Write cache to `flywrite-prompt-test--cache-file'."
  (with-temp-file flywrite-prompt-test--cache-file
    ;; Normalize nil suggestions to empty vectors so json-encode
    ;; writes [] instead of null.
    (let ((normalized
           (mapcar (lambda (entry)
                     (let* ((resp (alist-get "response" entry nil nil #'equal))
                            (sugs (and resp (or (alist-get 'suggestions resp)
                                                (cdr (assoc "suggestions" resp))))))
                       (when (and resp (null sugs))
                         (let ((cell (or (assoc 'suggestions resp)
                                         (assoc "suggestions" resp))))
                           (when cell (setcdr cell []))))
                       entry))
                   flywrite-prompt-test--cache)))
      (insert (json-encode normalized)))
    (json-pretty-print (point-min) (point-max))))

(defun flywrite-prompt-test--prompt-hash ()
  "Return MD5 hash of the current system prompt string."
  (md5 (flywrite--get-system-prompt)))

(defun flywrite-prompt-test--cache-lookup (text model prompt-hash)
  "Find a cache entry matching TEXT, MODEL, and PROMPT-HASH."
  (cl-find-if
   (lambda (entry)
     (and (equal (alist-get "text" entry nil nil #'equal) text)
          (equal (alist-get "model" entry nil nil #'equal) model)
          (equal (alist-get "prompt_hash" entry nil nil #'equal) prompt-hash)))
   flywrite-prompt-test--cache))

(defun flywrite-prompt-test--parse-response-string (response-text)
  "Parse RESPONSE-TEXT (a JSON string, possibly wrapped in markdown) to alist.
Empty arrays are preserved as empty vectors so `json-encode' writes []."
  (let* ((clean (replace-regexp-in-string
                 "\\`[ \t\n]*```\\(?:json\\)?[ \t]*\n?" ""
                 (replace-regexp-in-string
                  "\n?```[ \t\n]*\\'" "" response-text)))
         (json-array-type 'list)
         (parsed (json-read-from-string clean))
         (suggestions (alist-get 'suggestions parsed)))
    (when (null suggestions)
      (setf (alist-get 'suggestions parsed) []))
    parsed))

(defun flywrite-prompt-test--cache-store (text model prompt-hash response)
  "Store a cache entry for TEXT, MODEL, PROMPT-HASH, and RESPONSE.
RESPONSE is the raw API response string; it is parsed to JSON for storage."
  (let* ((response-obj (flywrite-prompt-test--parse-response-string response))
         (entry `(("text" . ,text)
                  ("model" . ,model)
                  ("prompt_hash" . ,prompt-hash)
                  ("response" . ,response-obj)
                  ("timestamp" . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))))
    (push entry flywrite-prompt-test--cache)
    (flywrite-prompt-test--save-cache)))

;;;; ---- Synchronous API call ----

(defun flywrite-prompt-test--call-api (text)
  "Send TEXT to the LLM API synchronously and return the response string.
Uses flywrite configuration for URL, model, API key, and system prompt."
  (let* ((api-key (or (getenv "FLYWRITE_API_KEY_ANTHROPIC")
                      (error "No API key.  Set FLYWRITE_API_KEY_ANTHROPIC")))
         (request (flywrite--build-request text api-key))
         (url-request-method "POST")
         (url-request-extra-headers (cdr request))
         (url-request-data (encode-coding-string (car request) 'utf-8))
         (response-buf (url-retrieve-synchronously flywrite-api-url t nil 30)))
    (unless response-buf
      (error "API call returned no response buffer"))
    (unwind-protect
        (with-current-buffer response-buf
          (goto-char (point-min))
          (unless (re-search-forward "\r?\n\r?\n" nil t)
            (error "Malformed HTTP response"))
          (let* ((json-data (json-read))
                 (text-content
                  (if (flywrite--anthropic-api-p)
                      (let* ((content (alist-get 'content json-data))
                             (block (and (arrayp content)
                                         (> (length content) 0)
                                         (aref content 0))))
                        (and block (alist-get 'text block)))
                    (let* ((choices (alist-get 'choices json-data))
                           (choice (and (arrayp choices)
                                        (> (length choices) 0)
                                        (aref choices 0)))
                           (message (and choice (alist-get 'message choice))))
                      (and message (alist-get 'content message))))))
            (unless text-content
              (error "No text in API response: %S" json-data))
            text-content))
      (kill-buffer response-buf))))

(defun flywrite-prompt-test--parse-suggestions (response)
  "Extract the suggestions list from RESPONSE.
RESPONSE may be a JSON string (from API) or an alist (from cache)."
  (let ((parsed (if (stringp response)
                    (flywrite-prompt-test--parse-response-string response)
                  response)))
    (or (alist-get 'suggestions parsed)
        (cdr (assoc "suggestions" parsed)))))

;;;; ---- Test configuration ----

(defun flywrite-prompt-test--configure ()
  "Set up flywrite API configuration for prompt tests.
Uses Anthropic as the default provider."
  (unless flywrite-api-url
    (setq flywrite-api-url "https://api.anthropic.com/v1/messages"))
  (setq flywrite-api-temperature 0))

;;;; ---- Core test runner ----

(defun flywrite-prompt-test--run-one (input style)
  "Run a single prompt test for INPUT plist with prompt STYLE.
STYLE is a symbol from `flywrite--prompt-alist' (e.g., `prose' or `academic').
Returns the number of suggestions from the API (using cache when available)."
  (flywrite-prompt-test--configure)
  (let* ((flywrite-system-prompt style)
         (text (plist-get input :text))
         (model (flywrite--effective-model))
         (prompt-hash (flywrite-prompt-test--prompt-hash))
         (cached (flywrite-prompt-test--cache-lookup text model prompt-hash))
         (response-text
          (if cached
              (progn
                (message "  [cached] [%s] %s"
                         style (plist-get input :description))
                (alist-get "response" cached nil nil #'equal))
            (message "  [api] [%s] %s"
                     style (plist-get input :description))
            (let ((resp (flywrite-prompt-test--call-api text)))
              (flywrite-prompt-test--cache-store text model prompt-hash resp)
              resp)))
         (suggestions (flywrite-prompt-test--parse-suggestions response-text)))
    (length suggestions)))

;;;; ---- ERT tests ----

(defun flywrite-prompt-test--run-all ()
  "Run all prompt regression tests for every prompt style.
Return list of (style input expected count pass) tuples."
  (flywrite-prompt-test--load-cache)
  (let ((results nil))
    (dolist (style-entry flywrite--prompt-alist)
      (let ((style (car style-entry)))
        (message "Testing prompt: %s" style)
        (dolist (input flywrite-prompt-test--inputs)
          (let* ((expected-alist (plist-get input :expected))
                 (expected (alist-get style expected-alist 'missing))
                 (_ (when (eq expected 'missing)
                      (error "No expected count for style `%s' in input: %s"
                             style (plist-get input :description))))
                 (count (flywrite-prompt-test--run-one input style))
                 (pass (= count expected)))
            (push (list style input expected count pass) results)))))
    (nreverse results)))

(ert-deftest flywrite-prompt-test-regression ()
  "Verify system prompts correctly catch or ignore writing flaws.
Each sample is sent to the LLM under every prompt style and must
return the exact expected number of suggestions."
  (let ((results (flywrite-prompt-test--run-all))
        (failures nil))
    (dolist (result results)
      (let* ((style (nth 0 result))
             (input (nth 1 result))
             (expected (nth 2 result))
             (count (nth 3 result))
             (pass (nth 4 result))
             (text (plist-get input :text))
             (desc (plist-get input :description)))
        (unless pass
          (push (format "FAIL [%s]: %s\n  text: %s\n  expected: %d, got: %d"
                        style desc text expected count)
                failures))))
    (when failures
      (ert-fail (mapconcat #'identity (nreverse failures) "\n\n")))))

(provide 'test-flywrite-prompt)

;;; test-flywrite-prompt.el ends here
