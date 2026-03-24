;;; test-flywrite-prompt.el --- Prompt regression tests  -*- lexical-binding: t; indent-tabs-mode: nil; fill-column: 80; -*-

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
  `((:text "The quick brown fox jumped over the lazy dog."
           :description "clean"
           :expected ((prose . 0) (academic . 0)))
    (:text ,(concat "The morning light filtered through the "
                    "curtains and cast long shadows across "
                    "the floor.")
           :description "clean"
           :expected ((prose . 0) (academic . 0)))
    (:text ,(concat "She picked up her coffee, took a quiet "
                    "sip, and turned to the first page of "
                    "the newspaper.")
           :description "clean"
           :expected ((prose . 0) (academic . 0)))
    (:text ,(concat "The results don't support the "
                    "hypothesis, and it's really not "
                    "a big deal.")
           :description ,(concat "contractions and informal "
                                 "language in academic writing")
           :expected ((prose . 1) (academic . 3)))
    (:text ,(concat "Him and his friend went to the store "
                    "to buy some grocerys.")
           :description "pronoun case error and misspelling"
           :expected ((prose . 2) (academic . 2)))
    (:text ,(concat "Their going to the park later today, "
                    "irregardless of the rain.")
           :description "wrong homophone and nonstandard word"
           :expected ((prose . 2) (academic . 2)))
    (:text ,(concat "Each of the students need to submit "
                    "there homework by Friday.")
           :description ,(concat "subject-verb disagreement "
                                 "and wrong homophone")
           :expected ((prose . 2) (academic . 2)))
    (:text ,(concat "She could of finished the report on "
                    "time if she would have started "
                    "earlier.")
           :description "could of and would have"
           :expected ((prose . 2) (academic . 2)))
    (:text ,(concat "Between you and I, this project is "
                    "more bigger than we expected.")
           :description "pronoun case and double comparative"
           :expected ((prose . 2) (academic . 2)))
    (:text ,(concat "The weather was very extremely hot "
                    "outside yesterday.")
           :description "redundant intensifiers"
           :expected ((prose . 1) (academic . 1)))
    ;; From samples/example.txt
    (:text ,(concat "The optimization had a significant "
                    "affect on runtime performance.")
           :description "affect/effect, weasel word"
           :expected ((prose . 1) (academic . 2)))
    (:text ,(concat "The benchmarks show the approach is "
                    "more efficient then brute force "
                    "search.")
           :description "then/than word-choice error"
           :expected ((prose . 1) (academic . 1)))
    (:text "We feel the results are promising."
           :description "subjective, vague"
           :expected ((prose . 0) (academic . 2)))
    ;; From samples/text-general-and-academic.txt
    (:text ,(concat "The students who was in the program "
                    "recieved there certificates at the "
                    "ceremony last friday.")
           :description ,(concat "subject-verb agreement, "
                                 "misspelling, homophone, "
                                 "and capitalization")
           :expected ((prose . 4) (academic . 4)))
    (:text ,(concat "So, the results clearly show that "
                    "this has a positive impact on stuff.")
           :description ,(concat "informal transition, subjective "
                                 "qualifier, ambiguous \"this\", "
                                 "vague term")
           :expected ((prose . 1) (academic . 4))))
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

(defvar flywrite-prompt-test--prompts nil
  "In-memory prompt table: alist mapping prompt hash to prompt text.")

(defun flywrite-prompt-test--load-cache ()
  "Load cache from `flywrite-prompt-test--cache-file'."
  (let ((data (and (file-readable-p flywrite-prompt-test--cache-file)
                   (condition-case nil
                       (let ((json-array-type 'list)
                             (json-object-type 'alist)
                             (json-key-type 'string))
                         (json-read-file flywrite-prompt-test--cache-file))
                     (error nil)))))
    (if (and data (listp data) (assoc "entries" data))
        (setq flywrite-prompt-test--prompts
              (let ((p (alist-get "prompts" data nil nil #'equal)))
                (if (listp p) p nil))
              flywrite-prompt-test--cache
              (alist-get "entries" data nil nil #'equal))
      ;; Legacy flat array format.
      (setq flywrite-prompt-test--prompts nil
            flywrite-prompt-test--cache (if (listp data) data nil)))))

(defconst flywrite-prompt-test--key-order
  '("text" "prompt_hash" "model" "temperature" "response" "timestamp")
  "Canonical key order for cache entry fields.")

(defun flywrite-prompt-test--value< (a b)
  "Return non-nil if A sorts before B.
nil sorts before numbers, numbers before strings.
Numbers compare with `<', strings with `string<'."
  (cond
   ((equal a b) nil)
   ((null a) t)
   ((null b) nil)
   ((and (numberp a) (numberp b)) (< a b))
   ((and (stringp a) (stringp b)) (string< a b))
   ((numberp a) t)
   (t nil)))

(defun flywrite-prompt-test--entry< (a b)
  "Return non-nil if cache entry A sorts before B.
Compares by text, prompt-hash, model, then temperature."
  (let ((keys '("text" "prompt_hash" "model" "temperature")))
    (cl-loop for key in keys
             for va = (alist-get key a nil nil #'equal)
             for vb = (alist-get key b nil nil #'equal)
             if (flywrite-prompt-test--value< va vb) return t
             if (flywrite-prompt-test--value< vb va) return nil
             finally return nil)))

(defun flywrite-prompt-test--normalize-entry (entry)
  "Return ENTRY with keys in canonical order and nil suggestions as [].
Keys follow `flywrite-prompt-test--key-order'."
  (let* ((resp (alist-get "response" entry nil nil #'equal))
         (sugs (and resp (or (alist-get 'suggestions resp)
                             (cdr (assoc "suggestions" resp))))))
    (when (and resp (null sugs))
      (let ((cell (or (assoc 'suggestions resp)
                      (assoc "suggestions" resp))))
        (when cell (setcdr cell [])))))
  (mapcar (lambda (key)
            (cons key (alist-get key entry nil nil #'equal)))
          flywrite-prompt-test--key-order))

(defun flywrite-prompt-test--save-cache ()
  "Write cache to `flywrite-prompt-test--cache-file'.
Entries are sorted and keys are in canonical order for stable diffs.
Prompts are sorted by hash."
  (with-temp-file flywrite-prompt-test--cache-file
    (let* ((sorted-entries (sort (mapcar #'flywrite-prompt-test--normalize-entry
                                         flywrite-prompt-test--cache)
                                 #'flywrite-prompt-test--entry<))
           (sorted-prompts (or (sort (copy-sequence
                                      flywrite-prompt-test--prompts)
                                     (lambda (a b) (string< (car a) (car b))))
                               (make-hash-table)))
           (obj `(("prompts" . ,sorted-prompts)
                  ("entries" . ,sorted-entries))))
      (insert (json-encode obj)))
    (json-pretty-print (point-min) (point-max))))

(defun flywrite-prompt-test--cache-lookup (text model prompt-hash temperature)
  "Find a cache entry matching TEXT, MODEL, PROMPT-HASH, and TEMPERATURE."
  (cl-find-if
   (lambda (entry)
     (and (equal (alist-get "text" entry nil nil #'equal) text)
          (equal (alist-get "model" entry nil nil #'equal) model)
          (equal (alist-get "prompt_hash" entry nil nil #'equal) prompt-hash)
          (equal (alist-get "temperature" entry nil nil #'equal) temperature)))
   flywrite-prompt-test--cache))

(defun flywrite-prompt-test--parse-response-string (response-text)
  "Parse RESPONSE-TEXT (a JSON string, possibly wrapped in markdown) to alist.
Empty arrays are preserved as empty vectors so `json-encode' writes []."
  (let ((parsed (flywrite--parse-response-json response-text)))
    (when (null (alist-get 'suggestions parsed))
      (setf (alist-get 'suggestions parsed) []))
    parsed))

(defun flywrite-prompt-test--cache-store (text model prompt-hash temperature
                                               prompt-text response)
  "Store a cache entry and register the prompt text.
TEXT, MODEL, PROMPT-HASH, and TEMPERATURE form the cache key.
PROMPT-TEXT is the system prompt string (stored in the prompts table).
RESPONSE is the raw API response string; it is parsed to JSON for storage."
  (let* ((response-obj (flywrite-prompt-test--parse-response-string response))
         (ts (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
         (entry `(("text" . ,text)
                  ("model" . ,model)
                  ("prompt_hash" . ,prompt-hash)
                  ("temperature" . ,temperature)
                  ("response" . ,response-obj)
                  ("timestamp" . ,ts))))
    (setf (alist-get prompt-hash flywrite-prompt-test--prompts
                     nil nil #'equal)
          prompt-text)
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
         (url-request-data
          (encode-coding-string (car request) 'utf-8))
         (response-buf
          (url-retrieve-synchronously flywrite-api-url t nil 30)))
    (unless response-buf
      (error "API call returned no response buffer"))
    (unwind-protect
        (with-current-buffer response-buf
          (cl-destructuring-bind (_status _json resp-text)
              (flywrite--extract-response-text)
            (unless resp-text
              (error "No text in API response"))
            resp-text))
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
    (setq flywrite-api-url "https://api.anthropic.com/v1/messages")))

;;;; ---- Core test runner ----

(defun flywrite-prompt-test--run-one (input style)
  "Run a single prompt test for INPUT plist with prompt STYLE.
STYLE is a symbol from `flywrite--prompt-alist' (e.g., `prose' or `academic').
Returns the number of suggestions from the API (using cache when available)."
  (flywrite-prompt-test--configure)
  (let* ((flywrite-system-prompt style)
         (text (plist-get input :text))
         (model (flywrite--effective-model))
         (temperature flywrite-api-temperature)
         (prompt-text (flywrite--get-system-prompt))
         (prompt-hash (md5 prompt-text))
         (cached (flywrite-prompt-test--cache-lookup
                  text model prompt-hash temperature))
         (response-text
          (if cached
              (progn
                (message "  [cached] [%s] %s"
                         style (plist-get input :description))
                (alist-get "response" cached nil nil #'equal))
            (message "  [api] [%s] %s"
                     style (plist-get input :description))
            (let ((resp (flywrite-prompt-test--call-api text)))
              (flywrite-prompt-test--cache-store
               text model prompt-hash temperature prompt-text resp)
              resp)))
         (suggestions (flywrite-prompt-test--parse-suggestions response-text)))
    (length suggestions)))

(defun flywrite-prompt-test--prune-cache ()
  "Remove cache entries whose prompt hash is not current.
Also remove orphaned prompts.  Current hashes are computed from
each style in `flywrite--prompt-alist'."
  (let ((current-hashes (mapcar (lambda (style-entry)
                                  (let ((flywrite-system-prompt
                                         (car style-entry)))
                                    (md5 (flywrite--get-system-prompt))))
                                flywrite--prompt-alist)))
    (setq flywrite-prompt-test--cache
          (cl-remove-if-not
           (lambda (entry)
             (member (alist-get "prompt_hash" entry nil nil #'equal)
                     current-hashes))
           flywrite-prompt-test--cache))
    (setq flywrite-prompt-test--prompts
          (cl-remove-if-not
           (lambda (pair) (member (car pair) current-hashes))
           flywrite-prompt-test--prompts))))

;;;; ---- ERT tests ----

(defun flywrite-prompt-test--run-all ()
  "Run all prompt regression tests for every prompt style.
Return list of (style input expected count pass) tuples."
  (flywrite-prompt-test--load-cache)
  ;; Build flat list of (style . input) pairs across all prompt styles.
  (let ((pairs (cl-loop for style-entry in flywrite--prompt-alist
                        for style = (car style-entry)
                        nconc (mapcar (lambda (input) (cons style input))
                                      flywrite-prompt-test--inputs)))
        (results nil)
        (prev-style nil))
    (dolist (pair pairs)
      (let* ((style (car pair))
             (input (cdr pair))
             (expected-alist (plist-get input :expected))
             (expected (alist-get style expected-alist 'missing))
             (_ (when (eq expected 'missing)
                  (error
                   "No expected count for style `%s' in input: %s"
                   style (plist-get input :description))))
             (count (flywrite-prompt-test--run-one input style))
             (pass (= count expected)))
        (unless (eq style prev-style)
          (message "Testing prompt: %s" style)
          (setq prev-style style))
        (push (list style input expected count pass) results)))
    (flywrite-prompt-test--prune-cache)
    (flywrite-prompt-test--save-cache)
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
