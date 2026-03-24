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
           :expected ((prose . 0) (academic . 3)))
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
           :expected ((prose . 1) (academic . 4)))
    ;; From samples/file-local-prose.txt
    (:text ,(concat "This file uses the 'prose' prompt via "
                    "a file-local variable on the first "
                    "line.  Paragraph 1 has general prose "
                    "errors which should be flagged.  "
                    "Paragraph 2 has academic-only errors "
                    "like hedging and weasel words which "
                    "should not be flagged by the prose "
                    "prompt.")
           :description "clean meta-description paragraph"
           :expected ((prose . 0) (academic . 0)))
    (:text ,(concat "I think that this is obviously the most "
                    "important thing we need to address. We "
                    "found that the treatment significantly "
                    "improved outcomes, and a lot of "
                    "participants felt that it was really "
                    "effective. So, the results clearly show "
                    "that this has a positive impact on "
                    "stuff.")
           :description ,(concat "academic-only errors: hedging, "
                                 "weasel words, informal language")
           :expected ((prose . 1) (academic . 11)))
    ;; Paragraph-sized inputs (multi-sentence)
    (:text ,(concat "The quick brown fox jumped over the "
                    "lazy dog.  Him and his friend went to "
                    "the store to buy some grocerys.  The "
                    "weather was very extremely hot outside "
                    "yesterday.")
           :description ,(concat "paragraph with pronoun case, "
                                 "misspelling, and redundant "
                                 "intensifiers")
           :expected ((prose . 3) (academic . 3)))
    (:text ,(concat "The morning light filtered through the "
                    "curtains and cast long shadows across "
                    "the floor.  She picked up her coffee, "
                    "took a quiet sip, and turned to the "
                    "first page of the newspaper.")
           :description "clean paragraph"
           :expected ((prose . 0) (academic . 0)))
    (:text ,(concat "Their going to the park later today, "
                    "irregardless of the rain.  Each of "
                    "the students need to submit there "
                    "homework by Friday.")
           :description ,(concat "paragraph with homophones, "
                                 "nonstandard word, and "
                                 "subject-verb disagreement")
           :expected ((prose . 4) (academic . 4))))
  "Test inputs: each entry is a plist with :text, :description, :expected.
:expected is an alist mapping each prompt style symbol to its
expected suggestion count, e.g., ((prose . 0) (academic . 2)).
Every style in `flywrite--prompt-alist' must have an entry.")

;;;; ---- Cache ----

(defvar flywrite-prompt-test--max-concurrent 8
  "Maximum number of concurrent API requests during prompt tests.")

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
RESPONSE is the raw API response string; it is parsed to JSON for storage.
If RESPONSE cannot be parsed, the entry is stored with an error marker."
  (let* ((response-obj (condition-case nil
                           (flywrite-prompt-test--parse-response-string
                            response)
                         (error `((suggestions . [])
                                  (parse-error . t)))))
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

;;;; ---- API call helpers ----

(defun flywrite-prompt-test--extract-response (response-buf)
  "Extract the LLM response text from RESPONSE-BUF.
Returns the response string, or nil on error.  Kills RESPONSE-BUF."
  (unwind-protect
      (flywrite-prompt-test--parse-response-buf response-buf)
    (when (buffer-live-p response-buf)
      (kill-buffer response-buf))))

(defun flywrite-prompt-test--parse-response-buf (buf)
  "Parse BUF as an HTTP response and return the LLM text, or nil."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (condition-case nil
          (cl-destructuring-bind (_status json resp-text)
              (flywrite--extract-response-text)
            (let ((stop
                   (or (alist-get 'stop_reason json)
                       (let* ((choices (alist-get 'choices json))
                              (c (and (arrayp choices)
                                      (> (length choices) 0)
                                      (aref choices 0))))
                         (and c (alist-get 'finish_reason c))))))
              (when (equal stop "max_tokens")
                (message "  [WARN] Response truncated (max_tokens)")))
            resp-text)
        (error nil)))))

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
    (or (flywrite-prompt-test--extract-response response-buf)
        (error "No text in API response"))))

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

(defun flywrite-prompt-test--build-jobs ()
  "Build a list of test jobs for all (style, input) pairs.
Each job is a plist with :style, :input, :text, :model, :prompt-hash,
:temperature, :prompt-text, :expected, and :cached (the cache entry or nil)."
  (flywrite-prompt-test--configure)
  (cl-loop for style-entry in flywrite--prompt-alist
           for style = (car style-entry)
           nconc
           (mapcar
            (lambda (input)
              (let* ((flywrite-system-prompt style)
                     (text (plist-get input :text))
                     (model (flywrite--effective-model))
                     (temperature flywrite-api-temperature)
                     (prompt-text (flywrite--get-system-prompt))
                     (prompt-hash (md5 prompt-text))
                     (expected-alist (plist-get input :expected))
                     (expected (alist-get style expected-alist 'missing))
                     (cached (flywrite-prompt-test--cache-lookup
                              text model prompt-hash temperature)))
                (when (eq expected 'missing)
                  (error
                   "No expected count for style `%s' in input: %s"
                   style (plist-get input :description)))
                (list :style style :input input :text text
                      :model model :prompt-hash prompt-hash
                      :temperature temperature
                      :prompt-text prompt-text
                      :expected expected :cached cached)))
            flywrite-prompt-test--inputs)))

(defun flywrite-prompt-test--fetch-uncached (jobs)
  "Fetch API responses for uncached JOBS concurrently.
JOBS is a list of plists (from `flywrite-prompt-test--build-jobs')
where :cached is nil.  Returns an alist mapping each job to its
raw response string.  Up to `flywrite-prompt-test--max-concurrent'
requests run in parallel."
  (let ((api-key (or (getenv "FLYWRITE_API_KEY_ANTHROPIC")
                     (error
                      "No API key.  Set FLYWRITE_API_KEY_ANTHROPIC")))
        (pending (copy-sequence jobs))
        (in-flight 0)
        (results nil))
    (cl-labels
        ((dispatch-next ()
           (when (and pending
                      (< in-flight
                         flywrite-prompt-test--max-concurrent))
             (let* ((job (pop pending))
                    (flywrite-system-prompt (plist-get job :style))
                    (text (plist-get job :text))
                    (request (flywrite--build-request text api-key))
                    (url-request-method "POST")
                    (url-request-extra-headers (cdr request))
                    (url-request-data
                     (encode-coding-string (car request) 'utf-8)))
               (message "  [api] [%s] %s"
                        (plist-get job :style)
                        (plist-get (plist-get job :input)
                                   :description))
               (cl-incf in-flight)
               (url-retrieve
                flywrite-api-url
                (lambda (status)
                  (ignore status)
                  (let ((resp
                         (flywrite-prompt-test--extract-response
                          (current-buffer))))
                    (cl-decf in-flight)
                    (push (cons job resp) results)
                    (flywrite-prompt-test--cache-store
                     (plist-get job :text)
                     (plist-get job :model)
                     (plist-get job :prompt-hash)
                     (plist-get job :temperature)
                     (plist-get job :prompt-text)
                     (or resp ""))
                    (dispatch-next)))
                nil t t)
               (dispatch-next)))))
      (dispatch-next)
      (while (> in-flight 0)
        (accept-process-output nil 0.1)))
    results))

(defun flywrite-prompt-test--evaluate-job (job response)
  "Evaluate a single test JOB against RESPONSE.
RESPONSE is the raw API response string or a cached response alist.
Returns (style input expected count suggestions pass)."
  (let* ((style (plist-get job :style))
         (input (plist-get job :input))
         (expected (plist-get job :expected))
         (suggestions
          (condition-case nil
              (flywrite-prompt-test--parse-suggestions response)
            (error
             (message "  [WARN] JSON parse error, treating as 0")
             nil)))
         (count (length suggestions))
         (pass (= count expected)))
    (list style input expected count suggestions pass)))

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
Return list of (style input expected count suggestions pass) tuples.
Uncached API calls run concurrently, up to
`flywrite-prompt-test--max-concurrent' at a time."
  (flywrite-prompt-test--load-cache)
  (let* ((all-jobs (flywrite-prompt-test--build-jobs))
         (cached-jobs (cl-remove-if-not
                       (lambda (j) (plist-get j :cached)) all-jobs))
         (uncached-jobs (cl-remove-if
                         (lambda (j) (plist-get j :cached)) all-jobs))
         ;; Log cached hits.
         (_ (dolist (job cached-jobs)
              (message "  [cached] [%s] %s"
                       (plist-get job :style)
                       (plist-get (plist-get job :input)
                                  :description))))
         ;; Fetch all uncached concurrently.
         (fetched (when uncached-jobs
                    (message "Fetching %d uncached test(s) (%d concurrent)..."
                             (length uncached-jobs)
                             (min (length uncached-jobs)
                                  flywrite-prompt-test--max-concurrent))
                    (flywrite-prompt-test--fetch-uncached uncached-jobs)))
         ;; Build a lookup from fetched results: (style . text) -> resp.
         (fetch-table (let ((ht (make-hash-table :test 'equal)))
                        (dolist (pair fetched)
                          (let ((job (car pair)))
                            (puthash
                             (cons (plist-get job :style)
                                   (plist-get job :text))
                             (cdr pair) ht)))
                        ht))
         ;; Evaluate all jobs in original order.
         (results
          (mapcar
           (lambda (job)
             (let* ((cached (plist-get job :cached))
                    (response
                     (if cached
                         (alist-get "response" cached nil nil #'equal)
                       (gethash (cons (plist-get job :style)
                                      (plist-get job :text))
                                fetch-table))))
               (flywrite-prompt-test--evaluate-job job response)))
           all-jobs)))
    (flywrite-prompt-test--prune-cache)
    (flywrite-prompt-test--save-cache)
    results))

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
             (suggestions (nth 4 result))
             (pass (nth 5 result))
             (text (plist-get input :text))
             (desc (plist-get input :description))
             (sugg-lines
              (mapconcat
               (lambda (s)
                 (let ((quote (or (alist-get 'quote s)
                                  (cdr (assoc "quote" s))
                                  "?"))
                       (reason (or (alist-get 'reason s)
                                   (cdr (assoc "reason" s))
                                   "?")))
                   (format "    - \"%s\" -> %s" quote reason)))
               (append suggestions nil) "\n")))
        (unless pass
          (let ((msg (format (concat "FAIL [%s]: %s\n"
                                     "  text: %s\n"
                                     "  expected: %d, got: %d\n"
                                     "  suggestions:\n%s")
                             style desc text expected count
                             sugg-lines)))
            (message "\n%s" msg)
            (push msg failures)))))
    (when failures
      (ert-fail (format "%d prompt test(s) failed (see messages above)"
                        (length failures))))))

(provide 'test-flywrite-prompt)

;;; test-flywrite-prompt.el ends here
