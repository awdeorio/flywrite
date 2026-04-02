;;; test-flywrite.el --- ERT tests for flywrite -*- lexical-binding: t; indent-tabs-mode: nil; fill-column: 80; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -l flywrite.el -l test-flywrite.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'flywrite)

(defvar flywrite-test--gemini-url
  (concat "https://generativelanguage.googleapis.com"
          "/v1beta/openai/chat/completions")
  "Gemini API URL used in tests.")

;;;; ---- Content hashing ----


(ert-deftest flywrite-test-content-hash-deterministic ()
  "Same content produces the same hash."
  (with-temp-buffer
    (insert "Hello world.")
    (let ((h1 (flywrite--content-hash 1 (point-max)))
          (h2 (flywrite--content-hash 1 (point-max))))
      (should (stringp h1))
      (should (string= h1 h2)))))


(ert-deftest flywrite-test-content-hash-differs ()
  "Different content produces different hashes."
  (let (h1 h2)
    (with-temp-buffer
      (insert "Hello world.")
      (setq h1 (flywrite--content-hash 1 (point-max))))
    (with-temp-buffer
      (insert "Goodbye world.")
      (setq h2 (flywrite--content-hash 1 (point-max))))
    (should-not (string= h1 h2))))


;;;; ---- Anthropic API detection ----


(ert-deftest flywrite-test-anthropic-api-p-yes ()
  "Detects Anthropic API URL."
  (let ((flywrite-api-url "https://api.anthropic.com/v1/messages"))
    (should (flywrite--anthropic-api-p))))


(ert-deftest flywrite-test-anthropic-api-p-no ()
  "Non-Anthropic URL returns nil."
  (let ((flywrite-api-url "https://api.openai.com/v1/chat/completions"))
    (should-not (flywrite--anthropic-api-p))))


(ert-deftest flywrite-test-anthropic-api-p-nil ()
  "Nil URL returns nil."
  (let ((flywrite-api-url nil))
    (should-not (flywrite--anthropic-api-p))))


;;;; ---- API key resolution ----


(ert-deftest flywrite-test-get-api-key-direct ()
  "Direct key takes priority."
  (let ((flywrite-api-key "sk-test-123")
        (flywrite-api-key-file nil))
    (should (string= (flywrite--get-api-key) "sk-test-123"))))


(ert-deftest flywrite-test-get-api-key-file ()
  "Key file is read when direct key is nil."
  (let* ((tmpfile (make-temp-file "flywrite-test-key"))
         (flywrite-api-key nil)
         (flywrite-api-key-file tmpfile))
    (unwind-protect
        (progn
          (with-temp-file tmpfile (insert "sk-from-file\n"))
          (should (string= (flywrite--get-api-key) "sk-from-file")))
      (delete-file tmpfile))))


(ert-deftest flywrite-test-get-api-key-file-strips-whitespace ()
  "Whitespace is stripped from key file."
  (let* ((tmpfile (make-temp-file "flywrite-test-key"))
         (flywrite-api-key nil)
         (flywrite-api-key-file tmpfile))
    (unwind-protect
        (progn
          (with-temp-file tmpfile (insert "  sk-trimmed  \n"))
          (should (string= (flywrite--get-api-key) "sk-trimmed")))
      (delete-file tmpfile))))


(ert-deftest flywrite-test-get-api-key-nil ()
  "Returns nil when nothing is configured."
  (let ((flywrite-api-key nil)
        (flywrite-api-key-file nil)
        (process-environment (cons "FLYWRITE_API_KEY=" process-environment)))
    ;; Unset the env var for this test
    (setenv "FLYWRITE_API_KEY" nil)
    (should-not (flywrite--get-api-key))))


;;;; ---- Paragraph boundary detection ----


(ert-deftest flywrite-test-paragraph-bounds ()
  "Paragraph boundaries are detected correctly."
  (with-temp-buffer
    (insert (concat "First paragraph line one.\n"
                    "First paragraph line two.\n"
                    "\nSecond paragraph.\n"
                    "\nThird paragraph."))
    ;; First paragraph
    (let* ((bounds (flywrite--paragraph-bounds-at-pos 1))
           (text (buffer-substring-no-properties
                  (car bounds) (cdr bounds))))
      (should (= (car bounds) 1))
      (should (string-match-p "First paragraph line one" text))
      (should-not (string-match-p "Second" text)))
    ;; Second paragraph
    (let* ((bounds (flywrite--paragraph-bounds-at-pos 55))
           (text (buffer-substring-no-properties
                  (car bounds) (cdr bounds))))
      (should (string= text "Second paragraph."))
      (should-not (string-match-p "First" text)))
    ;; Third paragraph
    (let* ((bounds (flywrite--paragraph-bounds-at-pos (- (point-max) 1)))
           (text (buffer-substring-no-properties
                  (car bounds) (cdr bounds))))
      (should (string= text "Third paragraph.")))))


(ert-deftest flywrite-test-paragraph-bounds-abbreviations ()
  "Abbreviations (Dr., et. al., etc.) stay within one paragraph."
  (with-temp-buffer
    (insert (concat "This Emacs mode was developed in"
                    " collaboration with Claude Code"
                    " March 2026 by Dr. Andrew DeOrio."
                    "  The regression test includes"
                    " unit tests, linting, et. al."
                    "  Claude Code needed guidance with"
                    " code style, nesting depth, etc.,"
                    " as well as testing."))
    (let ((paras (flywrite--collect-paragraphs-in-region
                  1 (point-max))))
      (should (= (length paras) 1)))))


(ert-deftest flywrite-test-paragraph-bounds-nonempty ()
  "Paragraph bounds end >= beg (never negative-length)."
  (with-temp-buffer
    (insert "A.")
    (let ((bounds (flywrite--paragraph-bounds-at-pos 1)))
      (should (>= (cdr bounds) (car bounds))))))

;;;; ---- Mode-aware suppression ----


(ert-deftest flywrite-test-skip-prog-mode ()
  "Text in prog-mode buffers is skipped."
  (let ((flywrite-skip-modes '(prog-mode)))
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "some text")
      (should (flywrite--should-skip-p 1)))))


(ert-deftest flywrite-test-no-skip-text-mode ()
  "Text in text-mode buffers is not skipped."
  (let ((flywrite-skip-modes '(prog-mode)))
    (with-temp-buffer
      (text-mode)
      (insert "some text")
      (should-not (flywrite--should-skip-p 1)))))


;;;; ---- Dirty registry (after-change) ----


(ert-deftest flywrite-test-after-change-marks-dirty ()
  "Editing text marks the containing paragraph dirty."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Hello world.")
      ;; Simulate a change
      (flywrite--after-change 1 (point-max) 0)
      (should flywrite--dirty-registry)
      (flywrite-mode -1))))


(ert-deftest flywrite-test-after-change-dedup ()
  "Same content hash is not re-dirtied after being marked checked."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Hello world.")
      (let ((hash (flywrite--content-hash 1 (point-max))))
        (puthash hash t flywrite--checked-paragraphs)
        (setq flywrite--dirty-registry nil)
        (flywrite--after-change 1 (point-max) 0)
        (should-not flywrite--dirty-registry))
      (flywrite-mode -1))))

;;;; ---- Clear ----


(ert-deftest flywrite-test-clear-resets-state ()
  "flywrite-clear resets all buffer-local state."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (push '(1 10 "fakehash") flywrite--dirty-registry)
      (puthash "abc" t flywrite--checked-paragraphs)
      (push '(buf 1 10 "fakehash") flywrite--pending-queue)
      (flywrite-clear)
      (should-not flywrite--dirty-registry)
      (should-not flywrite--pending-queue)
      (should (= (hash-table-count flywrite--checked-paragraphs) 0))
      (flywrite-mode -1))))


;;;; ---- Collect paragraphs in region ----


(ert-deftest flywrite-test-collect-paragraphs-basic ()
  "Collecting paragraphs finds unchecked paragraphs in a region."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert (concat "First paragraph.\n\n"
                      "Second paragraph.\n\n"
                      "Third paragraph."))
      (let ((paras (flywrite--collect-paragraphs-in-region
                    1 (point-max))))
        (should (= (length paras) 3)))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-collect-paragraphs-skips-checked ()
  "Already-checked paragraphs are not collected."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Only paragraph.")
      (let ((hash (flywrite--content-hash 1 (point-max))))
        (puthash hash t flywrite--checked-paragraphs))
      (let ((paras (flywrite--collect-paragraphs-in-region
                    1 (point-max))))
        (should (= (length paras) 0)))
      (flywrite-mode -1))))


;;;; ---- Mode enable/disable ----


(ert-deftest flywrite-test-mode-enable-disable ()
  "Enabling and disabling the mode sets up and tears down state."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (should flywrite-mode)
      (should flywrite--idle-timer)
      (should (memq #'flywrite-flymake flymake-diagnostic-functions))
      (flywrite-mode -1)
      (should-not flywrite-mode)
      (should-not flywrite--idle-timer))))


;;;; ---- Paragraph boundaries (markdown-simple.md) ----


(ert-deftest flywrite-test-paragraph-bounds-multi ()
  "Paragraph detection in multi-paragraph text (like markdown-simple.md)."
  (with-temp-buffer
    (insert (concat "The quick brown fox jumpted over"
                    " the lazy dog. "
                    "Him and his friend went to"
                    " the store."
                    "\n\n"
                    "Their going to the park later"
                    " today, irregardless of the"
                    " rain. Each of the students"
                    " need to submit there homework."
                    "\n\n"
                    "The morning light filtered"
                    " through the curtains and cast"
                    " long shadows across the"
                    " floor."))
    ;; First paragraph
    (let ((bounds (flywrite--paragraph-bounds-at-pos 1)))
      (should (string-match-p
               "quick brown fox"
               (buffer-substring-no-properties
                (car bounds) (cdr bounds))))
      (should (string-match-p
               "grocerys\\|store"
               (buffer-substring-no-properties
                (car bounds) (cdr bounds)))))
    ;; Second paragraph
    (let* ((para2-start
            (+ 1 (string-match
                  "\n\nTheir"
                  (buffer-substring-no-properties
                   1 (point-max)))))
           (bounds (flywrite--paragraph-bounds-at-pos
                    (+ 3 para2-start))))
      (should (string-match-p
               "Their going"
               (buffer-substring-no-properties
                (car bounds) (cdr bounds)))))))


(ert-deftest flywrite-test-collect-paragraphs-multi ()
  "Collect paragraphs from multi-paragraph content."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert (concat "First paragraph content here."
                      "\n\n"
                      "Second paragraph content here."
                      "\n\n"
                      "Third paragraph content here."))
      (let ((paras (flywrite--collect-paragraphs-in-region
                    1 (point-max))))
        (should (= (length paras) 3)))
      (flywrite-mode -1))))


;;;; ---- LaTeX content (latex-simple.tex, latex-itemize.tex) ----


(ert-deftest flywrite-test-paragraph-bounds-latex ()
  "Paragraph detection works inside LaTeX document body."
  (with-temp-buffer
    (insert (concat "\\begin{document}\n\n"
                    "The quick brown fox jumpted"
                    " over the lazy dog. "
                    "Him and his friend went"
                    " to the store."
                    "\n\n\\end{document}"))
    ;; Find the paragraph inside the document body
    (let ((bounds (flywrite--paragraph-bounds-at-pos 20)))
      (should (string-match-p
               "quick brown fox"
               (buffer-substring-no-properties
                (car bounds) (cdr bounds))))
      (should (string-match-p
               "the store\\."
               (buffer-substring-no-properties
                (car bounds) (cdr bounds)))))))


;;;; ---- Content hashing with different formats ----


(ert-deftest flywrite-test-hash-ignores-surrounding-whitespace-in-buffer ()
  "Hash depends on exact buffer content between positions."
  (let (h1 h2)
    (with-temp-buffer
      (insert "  Hello world.  ")
      (setq h1 (flywrite--content-hash 1 (point-max))))
    (with-temp-buffer
      (insert "Hello world.")
      (setq h2 (flywrite--content-hash 1 (point-max))))
    ;; Different because the buffer content differs
    (should-not (string= h1 h2))))


(ert-deftest flywrite-test-hash-subregion ()
  "Hash of a subregion differs from hash of the whole buffer."
  (with-temp-buffer
    (insert "First sentence. Second sentence.")
    (let ((h-all (flywrite--content-hash 1 (point-max)))
          (h-part (flywrite--content-hash 1 16)))
      (should-not (string= h-all h-part)))))


;;;; ---- Dirty registry with realistic edits ----


(ert-deftest flywrite-test-after-change-multi-sentence ()
  "After-change with multiple paragraphs marks at least one dirty."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "First sentence. Second sentence. Third sentence.")
      (flywrite--after-change 1 17 0)
      (should flywrite--dirty-registry)
      (flywrite-mode -1))))


(ert-deftest flywrite-test-after-change-replaces-overlapping ()
  "A second change to the same region replaces the dirty entry."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Hello world.")
      (flywrite--after-change 1 (point-max) 0)
      (let ((count-before (length flywrite--dirty-registry)))
        ;; Same region, same content — should not add duplicate
        (flywrite--after-change 1 (point-max) 0)
        (should (= (length flywrite--dirty-registry) count-before)))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-dirty-registry-cleared-on-disable ()
  "Disabling the mode clears the dirty registry."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Hello world.")
      (flywrite--after-change 1 (point-max) 0)
      (should flywrite--dirty-registry)
      (flywrite-mode -1)
      (should-not flywrite--dirty-registry))))


;;;; ---- Skip detection ----


(ert-deftest flywrite-test-skip-faces ()
  "Text with code-related font-lock faces is skipped."
  (let ((flywrite-skip-modes nil))
    (with-temp-buffer
      (text-mode)
      (insert "some code here")
      ;; Simulate font-lock applying a code face
      (put-text-property 1 15 'face 'font-lock-comment-face)
      (should (flywrite--should-skip-p 1)))))


(ert-deftest flywrite-test-skip-markdown-code-face ()
  "Text with markdown-code-face is skipped."
  (let ((flywrite-skip-modes nil))
    (with-temp-buffer
      (text-mode)
      (insert "def count_words(text):")
      (put-text-property 1 (point-max) 'face 'markdown-code-face)
      (should (flywrite--should-skip-p 1)))))


(ert-deftest flywrite-test-no-skip-plain-text ()
  "Plain text without special faces is not skipped."
  (let ((flywrite-skip-modes nil))
    (with-temp-buffer
      (text-mode)
      (insert "Normal prose text here.")
      (should-not (flywrite--should-skip-p 1)))))


(ert-deftest flywrite-test-skip-list-face ()
  "Text with face as a list is checked correctly."
  (let ((flywrite-skip-modes nil))
    (with-temp-buffer
      (text-mode)
      (insert "some text")
      (put-text-property 1 10 'face '(font-lock-string-face bold))
      (should (flywrite--should-skip-p 1)))))

;;;; ---- Collect paragraphs deduplication ----


(ert-deftest flywrite-test-collect-paragraphs-no-duplicates ()
  "Collecting paragraphs does not produce duplicate entries."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "One sentence. Another sentence.")
      (let* ((paras (flywrite--collect-paragraphs-in-region
                     1 (point-max)))
             (begs (mapcar #'car paras)))
        ;; No duplicate start positions
        (should (= (length begs) (length (delete-dups (copy-sequence begs))))))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-collect-paragraphs-empty-buffer ()
  "Collecting paragraphs in an empty buffer returns nil."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (let ((paras (flywrite--collect-paragraphs-in-region
                    1 (point-max))))
        (should (= (length paras) 0)))
      (flywrite-mode -1))))


;;;; ---- Check buffer ----


(ert-deftest flywrite-test-check-buffer-enqueues-paragraphs ()
  "check-buffer enqueues each paragraph as a separate dirty entry."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions")
        (flywrite-check-confirm-threshold 100))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert (concat "First paragraph here.\n\n"
                      "Second paragraph here.\n\n"
                      "Third paragraph here."))
      (setq flywrite--dirty-registry nil)
      (flywrite-check-buffer)
      ;; Should enqueue 3 separate entries, one per paragraph
      (should (= (length flywrite--dirty-registry) 3))
      ;; Each entry should cover only its own paragraph
      (let ((texts (mapcar (lambda (entry)
                             (buffer-substring-no-properties
                              (nth 0 entry) (nth 1 entry)))
                           flywrite--dirty-registry)))
        (should (member "First paragraph here." texts))
        (should (member "Second paragraph here." texts))
        (should (member "Third paragraph here." texts)))
      (flywrite-mode -1))))


;;;; ---- Flymake backend ----


(ert-deftest flywrite-test-flymake-backend-stores-report-fn ()
  "The flymake backend stores the report function."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (let ((called nil))
        (flywrite-flymake (lambda (_diags &rest _args) (setq called t)))
        (should called)
        (should flywrite--report-fn))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-flymake-backend-reports-empty-region ()
  "The flymake backend stores report-fn and reports empty region."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Test text.")
      (let ((called nil)
            (called-region nil))
        (flywrite-flymake
         (lambda (_diags &rest args)
           (setq called t)
           (setq called-region (plist-get args :region))))
        (should called)
        (should flywrite--report-fn)
        (should (equal called-region (cons 1 1))))
      (flywrite-mode -1))))


;;;; ---- API key env var ----


(ert-deftest flywrite-test-get-api-key-env ()
  "Falls back to FLYWRITE_API_KEY env var."
  (let ((flywrite-api-key nil)
        (flywrite-api-key-file nil)
        (process-environment
         (cons "FLYWRITE_API_KEY=sk-env-123"
               process-environment)))
    (should (string= (flywrite--get-api-key) "sk-env-123"))))


(ert-deftest flywrite-test-api-key-priority ()
  "Direct key takes priority over file and env var."
  (let* ((tmpfile (make-temp-file "flywrite-test-key"))
         (flywrite-api-key "sk-direct")
         (flywrite-api-key-file tmpfile)
         (process-environment
          (cons "FLYWRITE_API_KEY=sk-env"
                process-environment)))
    (unwind-protect
        (progn
          (with-temp-file tmpfile (insert "sk-from-file\n"))
          (should (string= (flywrite--get-api-key) "sk-direct")))
      (delete-file tmpfile))))


;;;; ---- Drain queue ----


(ert-deftest flywrite-test-drain-queue-skips-checked ()
  "Drain queue skips entries already in checked-paragraphs."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Hello world.")
      (let ((hash (flywrite--content-hash 1 (point-max))))
        (puthash hash t flywrite--checked-paragraphs)
        (setq flywrite--pending-queue
              (list (list (current-buffer) 1 (point-max) hash)))
        (setq flywrite--in-flight 0)
        ;; drain-queue should skip the checked entry
        ;; (it won't call send-request since api-url is nil, but it
        ;; removes the entry from the queue)
        (flywrite--drain-queue)
        (should-not flywrite--pending-queue))
      (flywrite-mode -1))))


;;;; ---- Logging ----


(ert-deftest flywrite-test-log-when-debug ()
  "Logging writes to *flywrite-log* when debug is on."
  (let ((flywrite-debug t))
    (flywrite--log "test message %d" 42)
    (with-current-buffer "*flywrite-log*"
      (should (string-match-p "test message 42"
                              (buffer-substring-no-properties 1 (point-max)))))
    (kill-buffer "*flywrite-log*")))


(ert-deftest flywrite-test-log-silent-when-no-debug ()
  "Logging does nothing when debug is off."
  (let ((flywrite-debug nil))
    (when (get-buffer "*flywrite-log*")
      (kill-buffer "*flywrite-log*"))
    (flywrite--log "should not appear")
    (should-not (get-buffer "*flywrite-log*"))))


;;;; ---- Mode idempotency ----


(ert-deftest flywrite-test-mode-enable-twice ()
  "Enabling the mode twice does not create duplicate timers."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (let ((timer1 flywrite--idle-timer))
        (flywrite-mode 1)
        ;; Timer should be the same object (no duplicate)
        (should (eq flywrite--idle-timer timer1)))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-mode-disable-twice ()
  "Disabling the mode twice is harmless."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (flywrite-mode -1)
      (flywrite-mode -1)
      (should-not flywrite-mode)
      (should-not flywrite--idle-timer))))


;;;; ---- Connection cleanup on disable ----


(ert-deftest flywrite-test-disable-kills-connection-buffers ()
  "Disabling the mode kills tracked connection buffers."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      ;; Simulate tracked connection buffers
      (let ((fake-conn1 (generate-new-buffer " *test-conn1*"))
            (fake-conn2 (generate-new-buffer " *test-conn2*")))
        (setq flywrite--connection-buffers (list fake-conn1 fake-conn2))
        (flywrite-mode -1)
        (should-not (buffer-live-p fake-conn1))
        (should-not (buffer-live-p fake-conn2))
        (should-not flywrite--connection-buffers)))))


(ert-deftest flywrite-test-disable-handles-dead-connection-buffers ()
  "Disabling the mode handles already-dead connection buffers gracefully."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (let ((fake-conn (generate-new-buffer " *test-conn*")))
        (kill-buffer fake-conn)
        (setq flywrite--connection-buffers (list fake-conn))
        ;; Should not error
        (flywrite-mode -1)
        (should-not flywrite--connection-buffers)))))


(ert-deftest flywrite-test-connection-buffers-initialized ()
  "Connection buffers list is initialized on enable."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (should-not flywrite--connection-buffers)
      (flywrite-mode -1))))


;;;; ---- 429 rate limit handling ----


(ert-deftest flywrite-test-429-keeps-hash-checked ()
  "A 429 error keeps the hash in checked-sentences to prevent retry."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Test sentence.")
      (let* ((hash (flywrite--content-hash 1 (point-max)))
             (buf (current-buffer))
             (status `(:error (error http 429))))
        (puthash hash t flywrite--checked-paragraphs)
        (setq flywrite--in-flight 1)
        ;; Create a fake response buffer for the handler
        (with-temp-buffer
          (insert "HTTP/1.1 429 Too Many Requests\r\n\r\n{}")
          (goto-char (point-min))
          (flywrite--handle-response status buf 1 15 hash (current-time)))
        ;; Hash should still be checked (not removed)
        (should (gethash hash flywrite--checked-paragraphs)))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-429-clears-pending-queue ()
  "A 429 error clears the pending queue to stop hammering the API."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Test sentence.")
      (let* ((hash (flywrite--content-hash 1 (point-max)))
             (buf (current-buffer))
             (status `(:error (error http 429))))
        (puthash hash t flywrite--checked-paragraphs)
        (setq flywrite--in-flight 1)
        (setq flywrite--pending-queue
              (list (list buf 1 15 "fakehash1")
                    (list buf 1 15 "fakehash2")))
        (with-temp-buffer
          (insert "HTTP/1.1 429 Too Many Requests\r\n\r\n{}")
          (goto-char (point-min))
          (flywrite--handle-response status buf 1 15 hash (current-time)))
        (should-not flywrite--pending-queue))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-non-429-error-keeps-hash ()
  "Any error keeps the hash checked to prevent automatic retry."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Test sentence.")
      (let* ((hash (flywrite--content-hash 1 (point-max)))
             (buf (current-buffer))
             (status `(:error (error http 500))))
        (puthash hash t flywrite--checked-paragraphs)
        (setq flywrite--in-flight 1)
        (with-temp-buffer
          (insert "HTTP/1.1 500 Internal Server Error\r\n\r\n{}")
          (goto-char (point-min))
          (flywrite--handle-response status buf 1 15 hash (current-time)))
        ;; Hash stays checked — user can flywrite-clear to force recheck
        (should (gethash hash flywrite--checked-paragraphs)))
      (flywrite-mode -1))))

;;;; ---- 529 overload handling ----


(ert-deftest flywrite-test-529-clears-pending-queue ()
  "A 529 error clears the pending queue to stop hammering an overloaded API."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Test sentence.")
      (let* ((hash (flywrite--content-hash 1 (point-max)))
             (buf (current-buffer))
             (status `(:error (error http 529))))
        (puthash hash t flywrite--checked-paragraphs)
        (setq flywrite--in-flight 1)
        (setq flywrite--pending-queue
              (list (list buf 1 15 "fakehash1")
                    (list buf 1 15 "fakehash2")))
        (with-temp-buffer
          (insert "HTTP/1.1 529 Overloaded\r\n\r\n{}")
          (goto-char (point-min))
          (flywrite--handle-response status buf 1 15 hash (current-time)))
        (should-not flywrite--pending-queue))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-529-keeps-hash-checked ()
  "A 529 error keeps the hash in checked-sentences to prevent retry."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Test sentence.")
      (let* ((hash (flywrite--content-hash 1 (point-max)))
             (buf (current-buffer))
             (status `(:error (error http 529))))
        (puthash hash t flywrite--checked-paragraphs)
        (setq flywrite--in-flight 1)
        (with-temp-buffer
          (insert "HTTP/1.1 529 Overloaded\r\n\r\n{}")
          (goto-char (point-min))
          (flywrite--handle-response status buf 1 15 hash (current-time)))
        (should (gethash hash flywrite--checked-paragraphs)))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-529-user-message ()
  "A 529 error shows a user-facing message mentioning overloaded."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Test sentence.")
      (let* ((hash (flywrite--content-hash 1 (point-max)))
             (buf (current-buffer))
             (status `(:error (error http 529)))
             (messages nil))
        (puthash hash t flywrite--checked-paragraphs)
        (setq flywrite--in-flight 1)
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (with-temp-buffer
            (insert "HTTP/1.1 529 Overloaded\r\n\r\n{}")
            (goto-char (point-min))
            (flywrite--handle-response status buf 1 15 hash (current-time))))
        (should (cl-some
                 (lambda (m)
                   (string-match-p "overloaded" m))
                 messages)))
      (flywrite-mode -1))))


;;;; ---- Duplicate callback guard ----


(ert-deftest flywrite-test-duplicate-callback-ignored ()
  "Second callback for the same request is ignored."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Test sentence.")
      (let* ((hash (flywrite--content-hash 1 (point-max)))
             (buf (current-buffer))
             (status `(:error (error connection-failed)))
             (response-buf (generate-new-buffer " *test-response*")))
        (puthash hash t flywrite--checked-paragraphs)
        (setq flywrite--in-flight 1)
        ;; First callback
        (with-current-buffer response-buf
          (insert "HTTP/1.1 500\r\n\r\n{}")
          (goto-char (point-min))
          (flywrite--handle-response status buf 1 15 hash (current-time)))
        ;; in-flight should be 0 after first callback
        (should (= flywrite--in-flight 0))
        ;; Second callback on a new buffer (simulating url-retrieve behavior)
        (let ((response-buf2 (generate-new-buffer " *test-response2*")))
          (with-current-buffer response-buf2
            ;; Mark as already handled (same flag the first callback sets)
            (setq-local flywrite--response-handled t)
            (flywrite--handle-response status buf 1 15 hash (current-time)))
          ;; in-flight should still be 0, not -1
          (should (= flywrite--in-flight 0))))
      (flywrite-mode -1))))


;;;; ---- Config validation ----


(ert-deftest flywrite-test-validate-config-no-url ()
  "Config validation signals error when API URL is not set."
  (let ((flywrite-api-url nil))
    (with-temp-buffer
      (text-mode)
      (should-error (flywrite--validate-config) :type 'error))))


(ert-deftest flywrite-test-validate-config-no-api-key-anthropic ()
  "Config validation signals error when Anthropic API key is missing."
  (let ((flywrite-api-url "https://api.anthropic.com/v1/messages")
        (flywrite-api-key nil)
        (flywrite-api-key-file nil)
        (process-environment (cons "FLYWRITE_API_KEY=" process-environment)))
    (setenv "FLYWRITE_API_KEY" nil)
    (with-temp-buffer
      (text-mode)
      (should-error (flywrite--validate-config) :type 'error))))


(ert-deftest flywrite-test-validate-config-no-api-key-openai ()
  "Config validation signals error when OpenAI API key is missing."
  (let ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
        (flywrite-api-key nil)
        (flywrite-api-key-file nil)
        (process-environment (cons "FLYWRITE_API_KEY=" process-environment)))
    (setenv "FLYWRITE_API_KEY" nil)
    (with-temp-buffer
      (text-mode)
      (should-error (flywrite--validate-config) :type 'error))))


(ert-deftest flywrite-test-validate-config-no-api-key-gemini ()
  "Config validation signals error when Gemini API key is missing."
  (let ((flywrite-api-url flywrite-test--gemini-url)
        (flywrite-api-key nil)
        (flywrite-api-key-file nil)
        (process-environment (cons "FLYWRITE_API_KEY=" process-environment)))
    (setenv "FLYWRITE_API_KEY" nil)
    (with-temp-buffer
      (text-mode)
      (should-error (flywrite--validate-config) :type 'error))))


;;;; ---- End-to-end: mock API ----


(defun flywrite-test--diag-text-at-overlay (diag)
  "Return the buffer text under DIAG's overlay.
Uses the overlay position (which auto-adjusts with buffer edits)
rather than the struct field (which can become stale)."
  (let ((ov (flymake--diag-overlay diag)))
    (when (and ov (overlayp ov) (overlay-buffer ov))
      (buffer-substring-no-properties
       (overlay-start ov) (overlay-end ov)))))


(defun flywrite-test--make-response-buffer (json-body)
  "Create a buffer mimicking an HTTP 200 response with JSON-BODY string."
  (let ((buf (generate-new-buffer " *test-http-response*")))
    (with-current-buffer buf
      (insert "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
              json-body))
    buf))


(ert-deftest flywrite-test-e2e-mock-api ()
  "End-to-end: insert error, check, fix, re-check, verify."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         ;; Track calls to url-retrieve
         (api-call-count 0)
         ;; Response to return (swapped between calls)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)

      ;; --- Step 1: Insert a sentence with an error ---
      (insert "Him went to the store.")

      ;; Enable flywrite-mode (mocking url-retrieve to prevent real HTTP)
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     ;; Synchronously invoke the callback in the response buffer
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        ;; --- Step 2: Enable mode and trigger check ---
        (flywrite-mode 1)

        ;; Set mock response: one suggestion for "Him"
        (let ((inner (json-encode
                      '((suggestions
                         . [((quote . "Him")
                             (reason
                              . "Use \"He\" (subject pronoun)")
                             )])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        ;; Trigger check: dirty the sentence and fire the idle timer
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 3: Verify diagnostic was created ---
        (should (= api-call-count 1))
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (= (flymake-diagnostic-beg diag) 1))
          (should (= (flymake-diagnostic-end diag) 4))
          (should (string-match-p "subject pronoun"
                                  (flymake-diagnostic-text diag)))
          (should (string-match-p "\\[flywrite\\]"
                                  (flymake-diagnostic-text diag))))

        ;; --- Step 4: Fix the error ---
        (goto-char 1)
        (delete-region 1 4)
        (insert "He")

        ;; --- Step 5: Set mock response: no suggestions ---
        (let ((inner (json-encode
                      '((suggestions . [])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        ;; Fire idle timer to dispatch re-check
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 6: Verify diagnostic removed, API called ---
        (should (= api-call-count 2))
        (should (= (length (flymake-diagnostics)) 0)))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-case-sensitive-quote-match ()
  "Diagnostic underlines the exact-case occurrence, not a case-folded match."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)
      ;; "the show" appears at pos 16 (lowercase) and pos 27 (uppercase).
      ;; With case-fold-search=t, "The show" would wrongly match at pos 16.
      (insert "He went to see the show.  The show was great.")

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)

        ;; LLM flags "The show" (capitalized) — must NOT match "the show"
        (let ((inner (json-encode
                      '((suggestions
                         . [((quote . "The show")
                             (reason . "Consider lowercase"))])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          ;; "The show" starts at position 27, not 16
          (should (= (flymake-diagnostic-beg diag) 27))
          (should (= (flymake-diagnostic-end diag) 35))))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-duplicate-quote-positions ()
  "Two suggestions with identical quotes underline different occurrences."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)
      ;; "him" appears at pos 8-11 and pos 38-41
      (insert "First, him went to the store. Later, him went to the park.")

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)

        ;; LLM flags both occurrences of "him"
        (let ((inner (json-encode
                      '((suggestions
                         . [((quote . "him")
                             (reason . "Use \"he\" (subject pronoun)"))
                            ((quote . "him")
                             (reason
                              . "Use \"he\" (subject pronoun)"))])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        (should (= (length (flymake-diagnostics)) 2))
        ;; flymake-diagnostics returns overlays in position order
        (let ((diags (flymake-diagnostics)))
          ;; First "him" at positions 8-11
          (should (= (flymake-diagnostic-beg (nth 0 diags)) 8))
          (should (= (flymake-diagnostic-end (nth 0 diags)) 11))
          ;; Second "him" at positions 38-41
          (should (= (flymake-diagnostic-beg (nth 1 diags)) 38))
          (should (= (flymake-diagnostic-end (nth 1 diags)) 41))))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-diagnostic-survives-other-paragraph-edit ()
  "Diagnostic on paragraph 2 survives an edit to paragraph 1.
Verifies underlined strings, not numeric positions."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)

      ;; Two paragraphs: first has no errors, second has "Him"
      (insert "The weather is nice today.\n\nHim went to the store.")

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)

        ;; Mock response: flag "Him" — only found in paragraph 2
        (let ((inner (json-encode
                      '((suggestions
                         . [((quote . "Him")
                             (reason
                              . "Use \"He\" (subject pronoun)"))])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        ;; --- Step 1: Check both paragraphs ---
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 2: Verify one diagnostic, underlined text is "Him" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (buffer-substring-no-properties
                            (flymake-diagnostic-beg diag)
                            (flymake-diagnostic-end diag)))))

        ;; --- Step 3: Edit paragraph 1 (length-changing replacement) ---
        (goto-char 1)
        (search-forward "nice")
        (replace-match "beautiful")

        ;; --- Step 4: Re-check (paragraph 1 is re-dirtied) ---
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 5: Verify diagnostic still underlines "Him" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (flywrite-test--diag-text-at-overlay diag)))))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-diagnostic-survives-large-insert ()
  "Diagnostic on paragraph 2 survives a large insertion in paragraph 1.
The inserted text is longer than the entire original paragraph."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)

      ;; Short paragraph 1, paragraph 2 has "Him"
      (insert "Hi.\n\nHim went to the store.")

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)

        ;; Mock response: flag "Him" — only found in paragraph 2
        (let ((inner (json-encode
                      '((suggestions
                         . [((quote . "Him")
                             (reason
                              . "Use \"He\" (subject pronoun)"))])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        ;; --- Step 1: Check both paragraphs ---
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 2: Verify diagnostic underlines "Him" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (buffer-substring-no-properties
                            (flymake-diagnostic-beg diag)
                            (flymake-diagnostic-end diag)))))

        ;; --- Step 3: Insert text much longer than original paragraph ---
        ;; "Hi." is 3 chars; the replacement is ~60 chars.
        (goto-char 1)
        (search-forward "Hi")
        (replace-match
         "Hello there, the weather is absolutely wonderful today")

        ;; --- Step 4: Re-check ---
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 5: Verify diagnostic still underlines "Him" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (flywrite-test--diag-text-at-overlay diag)))))


      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-diagnostic-survives-large-delete ()
  "Diagnostic on paragraph 2 survives a large deletion in paragraph 1."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)

      ;; Long paragraph 1 (58 chars), then paragraph 2 with "Him"
      (insert (concat "The weather is absolutely wonderful and "
                      "beautiful today.\n\n"
                      "Him went to the store."))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)

        ;; Mock response: flag "Him" — only found in paragraph 2
        (let ((inner (json-encode
                      '((suggestions
                         . [((quote . "Him")
                             (reason
                              . "Use \"He\" (subject pronoun)"))])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        ;; --- Step 1: Check both paragraphs ---
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 2: Verify diagnostic underlines "Him" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (buffer-substring-no-properties
                            (flymake-diagnostic-beg diag)
                            (flymake-diagnostic-end diag)))))

        ;; --- Step 3: Delete most of paragraph 1 ---
        ;; "absolutely wonderful and beautiful" (34 chars) removed.
        (goto-char 1)
        (search-forward "absolutely wonderful and beautiful")
        (replace-match "fine")

        ;; --- Step 4: Re-check ---
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 5: Verify diagnostic still underlines "Him" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (flywrite-test--diag-text-at-overlay diag)))))


      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-diagnostic-race-edit-before-response ()
  "Diagnostic placed correctly when paragraph 1 is edited while API is
in-flight for paragraph 2.  Paragraph 2 has two sentences: the first is
correct, the second contains one error.  The response arrives after
paragraph 1 changes length, so the original beg/end are stale."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil)
         ;; Deferred callback: captured by the first url-retrieve call
         (deferred-callback nil)
         (deferred-resp-buf nil)
         ;; After the deferred call, switch to synchronous mode
         (synchronous nil))
    (with-temp-buffer
      (text-mode)

      ;; Two paragraphs.  P1 has no errors.  P2's second sentence
      ;; has "Him" (should be "He").
      (insert "The weather is nice today.\n\n"
              "The sun is bright. Him went to the store.")

      ;; Build the mock response once — flag "Him"
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason
                            . "Use \"He\" (subject pronoun)"))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (if synchronous
                         ;; Second call onwards: invoke callback immediately
                         (progn
                           (with-current-buffer resp-buf
                             (goto-char (point-min))
                             (funcall callback nil))
                           resp-buf)
                       ;; First call: capture callback for deferred invocation
                       (setq deferred-callback callback
                             deferred-resp-buf resp-buf)
                       resp-buf)))))

        (flywrite-mode 1)

        ;; --- Step 1: Dirty only paragraph 2 ---
        (let ((p2-beg (save-excursion
                        (goto-char (point-min))
                        (forward-paragraph)
                        (skip-chars-forward "\n")
                        (point)))
              (p2-end (point-max)))
          (flywrite--after-change p2-beg p2-end 0))

        ;; --- Step 2: Dispatch request (callback is deferred) ---
        (flywrite--idle-timer-fn (current-buffer))
        (should deferred-callback)

        ;; --- Step 3: Edit paragraph 1 — length-changing replacement ---
        ;; "nice" (4 chars) → "beautiful" (9 chars), +5 chars
        (goto-char 1)
        (search-forward "nice")
        (replace-match "beautiful")

        ;; --- Step 4: Now the deferred response arrives ---
        ;; Switch to synchronous for re-check requests
        (setq synchronous t)
        (with-current-buffer deferred-resp-buf
          (goto-char (point-min))
          (funcall deferred-callback nil))

        ;; The stale check should have re-dirtied paragraph 2.
        ;; Fire idle timer to dispatch the re-check.
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 5: Verify one diagnostic underlining "Him" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (buffer-substring-no-properties
                            (flymake-diagnostic-beg diag)
                            (flymake-diagnostic-end diag))))))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-race-same-paragraph-edit ()
  "Same-paragraph race: edit first sentence while API checks paragraph.
One paragraph, two sentences.  First sentence correct, second has
\"Him\".  Request dispatched, then first sentence edited (length
change), then response arrives stale, re-check places diagnostic."
  (let* ((flywrite-api-url
          "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil)
         (deferred-callback nil)
         (deferred-resp-buf nil)
         (synchronous nil))
    (with-temp-buffer
      (text-mode)

      (insert "The weather is nice today.  "
              "Him went to the store.")

      ;; Mock response: flag "Him"
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason
                            . "Use \"He\" as subject"))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback
                               &optional _cbargs _silent _inhibit)
                   (let ((resp-buf
                          (flywrite-test--make-response-buffer
                           mock-response-json)))
                     (if synchronous
                         (progn
                           (with-current-buffer resp-buf
                             (goto-char (point-min))
                             (funcall callback nil))
                           resp-buf)
                       (setq deferred-callback callback
                             deferred-resp-buf resp-buf)
                       resp-buf)))))

        (flywrite-mode 1)

        ;; --- Step 1: Dirty and dispatch (deferred) ---
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))
        (should deferred-callback)

        ;; --- Step 2: Edit first sentence (length change) ---
        ;; "nice" (4) -> "beautiful" (9), +5 chars
        (goto-char 1)
        (search-forward "nice")
        (replace-match "beautiful")

        ;; --- Step 3: Deferred response arrives (stale) ---
        (setq synchronous t)
        (with-current-buffer deferred-resp-buf
          (goto-char (point-min))
          (funcall deferred-callback nil))

        ;; --- Step 4: Re-check via idle timer ---
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 5: Verify diagnostic underlines "Him" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should
           (string= "Him"
                    (buffer-substring-no-properties
                     (flymake-diagnostic-beg diag)
                     (flymake-diagnostic-end diag))))))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-race-same-paragraph-fix ()
  "Same-paragraph race: user fixes error while API is in-flight.
The edit changes \"Him\" to \"He\" before the response arrives.
Stale response is discarded, re-check finds no errors."
  (let* ((flywrite-api-url
          "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil)
         (deferred-callback nil)
         (deferred-resp-buf nil)
         (synchronous nil))
    (with-temp-buffer
      (text-mode)

      (insert "The weather is nice today.  "
              "Him went to the store.")

      ;; Initial mock: flag "Him"
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason
                            . "Use \"He\" as subject"))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback
                               &optional _cbargs _silent _inhibit)
                   (let ((resp-buf
                          (flywrite-test--make-response-buffer
                           mock-response-json)))
                     (if synchronous
                         (progn
                           (with-current-buffer resp-buf
                             (goto-char (point-min))
                             (funcall callback nil))
                           resp-buf)
                       (setq deferred-callback callback
                             deferred-resp-buf resp-buf)
                       resp-buf)))))

        (flywrite-mode 1)

        ;; --- Step 1: Dirty and dispatch (deferred) ---
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))
        (should deferred-callback)

        ;; --- Step 2: Fix the error before response ---
        (goto-char 1)
        (search-forward "Him")
        (replace-match "He")

        ;; --- Step 3: Swap mock to empty suggestions ---
        (let ((inner (json-encode
                      '((suggestions . [])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        ;; --- Step 4: Deferred response arrives (stale) ---
        (setq synchronous t)
        (with-current-buffer deferred-resp-buf
          (goto-char (point-min))
          (funcall deferred-callback nil))

        ;; --- Step 5: Re-check via idle timer ---
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 6: Verify no diagnostics ---
        (should (= (length (flymake-diagnostics)) 0)))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-race-same-paragraph-new-error ()
  "Same-paragraph race: user fixes one error but introduces another.
\"Him went\" becomes \"He wented\" before the response arrives.
Re-check flags \"wented\" instead of the original \"Him\"."
  (let* ((flywrite-api-url
          "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil)
         (deferred-callback nil)
         (deferred-resp-buf nil)
         (synchronous nil))
    (with-temp-buffer
      (text-mode)

      (insert "The weather is nice today.  "
              "Him went to the store.")

      ;; Initial mock: flag "Him"
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason
                            . "Use \"He\" as subject"))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback
                               &optional _cbargs _silent _inhibit)
                   (let ((resp-buf
                          (flywrite-test--make-response-buffer
                           mock-response-json)))
                     (if synchronous
                         (progn
                           (with-current-buffer resp-buf
                             (goto-char (point-min))
                             (funcall callback nil))
                           resp-buf)
                       (setq deferred-callback callback
                             deferred-resp-buf resp-buf)
                       resp-buf)))))

        (flywrite-mode 1)

        ;; --- Step 1: Dirty and dispatch (deferred) ---
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))
        (should deferred-callback)

        ;; --- Step 2: Fix "Him" but introduce "wented" ---
        (goto-char 1)
        (search-forward "Him went")
        (replace-match "He wented")

        ;; --- Step 3: Swap mock to flag "wented" ---
        (let ((inner (json-encode
                      '((suggestions
                         . [((quote . "wented")
                             (reason
                              . "Not a word; use \"went\"")
                             )])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        ;; --- Step 4: Deferred response arrives (stale) ---
        (setq synchronous t)
        (with-current-buffer deferred-resp-buf
          (goto-char (point-min))
          (funcall deferred-callback nil))

        ;; --- Step 5: Re-check via idle timer ---
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 6: Verify diagnostic underlines "wented" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should
           (string= "wented"
                    (buffer-substring-no-properties
                     (flymake-diagnostic-beg diag)
                     (flymake-diagnostic-end diag))))))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-race-concurrent-multi-paragraph ()
  "Concurrent requests across 3 paragraphs with edits during flight.
P1 has no errors, P2 has \"Him\", P3 has no errors.  Concurrency
cap is 2, so P1 and P2 dispatch immediately while P3 is queued.
P1 is edited (length change) while requests are in-flight,
shifting P2 and P3 positions.  All deferred responses are
delivered, stale ones re-dirtied, and a final re-check produces
the correct diagnostic on \"Him\"."
  (let* ((flywrite-api-url
          "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (flywrite-max-concurrent 2)
         (mock-response-json nil)
         ;; Deferred callbacks: list of (callback . resp-buf)
         (deferred-calls nil)
         (synchronous nil))

    (with-temp-buffer
      (text-mode)

      ;; Three paragraphs
      (insert "The weather is nice today.\n\n"
              "Him went to the store.\n\n"
              "The birds are singing.")

      ;; Mock response flags "Him".  For paragraphs without
      ;; "Him" the quote search fails silently (no diagnostic).
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason
                            . "Use \"He\" as subject"))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf
          (((symbol-function 'url-retrieve)
            (lambda (_url callback
                          &optional _cbargs _silent _inhibit)
              (let ((resp-buf
                     (flywrite-test--make-response-buffer
                      mock-response-json)))
                (if synchronous
                    (progn
                      (with-current-buffer resp-buf
                        (goto-char (point-min))
                        (funcall callback nil))
                      resp-buf)
                  (push (cons callback resp-buf)
                        deferred-calls)
                  resp-buf)))))

        (flywrite-mode 1)

        ;; --- Step 1: Dirty all paragraphs and dispatch ---
        (dolist (entry (flywrite--collect-paragraphs-in-region
                        1 (point-max)))
          (push entry flywrite--dirty-registry))
        ;; Cap=2: P1 and P2 dispatch; P3 queued.
        (flywrite--idle-timer-fn (current-buffer))
        (should (= (length deferred-calls) 2))
        (should (= flywrite--in-flight 2))
        (should (= (length flywrite--pending-queue) 1))

        ;; --- Step 2: Edit P1 (length change) ---
        ;; "nice" (4) -> "beautiful" (9), +5 chars
        (goto-char 1)
        (search-forward "nice")
        (replace-match "beautiful")

        ;; --- Step 3: Deliver all deferred responses ---
        ;; Each delivery decrements in-flight and may drain
        ;; the queue (P3 dispatched, also deferred).
        (while deferred-calls
          (let* ((entry (pop deferred-calls))
                 (cb (car entry))
                 (buf (cdr entry)))
            (with-current-buffer buf
              (goto-char (point-min))
              (funcall cb nil))))

        ;; --- Step 4: Switch to synchronous, re-check ---
        (setq synchronous t)

        ;; Deliver any callbacks queued during step 3
        ;; (P3 drained from pending queue).
        (while deferred-calls
          (let* ((entry (pop deferred-calls))
                 (cb (car entry))
                 (buf (cdr entry)))
            (with-current-buffer buf
              (goto-char (point-min))
              (funcall cb nil))))

        ;; Fire idle timer for re-dirtied paragraphs
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 5: Verify exactly one diagnostic on "Him" ---
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should
           (string= "Him"
                    (buffer-substring-no-properties
                     (flymake-diagnostic-beg diag)
                     (flymake-diagnostic-end diag))))))

      (flywrite-mode -1))))


;;;; ---- System prompt resolution ----


(ert-deftest flywrite-test-prompt-prose-symbol ()
  "Symbol `prose' resolves to the prose prompt string."
  (let ((flywrite-system-prompt 'prose))
    (should (string= (flywrite--get-system-prompt) flywrite-prose-prompt))))


(ert-deftest flywrite-test-prompt-academic-symbol ()
  "Symbol `academic' resolves to a string with academic-specific rules."
  (let ((flywrite-system-prompt 'academic))
    (let ((prompt (flywrite--get-system-prompt)))
      (should (stringp prompt))
      (should (string-match-p "informal language" prompt))
      (should (string-match-p "nominalizations" prompt))
      (should (string-match-p "weasel words" prompt)))))


(ert-deftest flywrite-test-prompt-unknown-symbol-errors ()
  "An unknown symbol signals an error."
  (let ((flywrite-system-prompt 'nonexistent))
    (should-error (flywrite--get-system-prompt) :type 'error)))


(ert-deftest flywrite-test-prompt-safe-local-variable-builtin ()
  "Built-in prompt styles are safe as file-local variables."
  (let ((safe-p (get 'flywrite-system-prompt 'safe-local-variable)))
    (should (functionp safe-p))
    (should (funcall safe-p 'prose))
    (should (funcall safe-p 'academic))))


(ert-deftest flywrite-test-prompt-safe-local-variable-rejects-unknown ()
  "Unknown symbols are not safe as file-local variables."
  (let ((safe-p (get 'flywrite-system-prompt 'safe-local-variable)))
    (should-not (funcall safe-p 'nonexistent))))


(ert-deftest flywrite-test-prompt-user-defined-style ()
  "Users can register a custom named style via `flywrite-prompt-alist'."
  (defvar flywrite-test--scifi-prompt "You are a sci-fi editor.")
  (let ((flywrite-prompt-alist flywrite-prompt-alist)
        (flywrite-system-prompt 'scifi))
    (push '(scifi . flywrite-test--scifi-prompt) flywrite-prompt-alist)
    (should (string= (flywrite--get-system-prompt)
                     "You are a sci-fi editor."))
    ;; User-added style is also accepted by safe-local-variable predicate.
    (let ((safe-p (get 'flywrite-system-prompt 'safe-local-variable)))
      (should (funcall safe-p 'scifi)))))


(ert-deftest flywrite-test-prompt-file-local-variable ()
  "Setting `flywrite-system-prompt' via file-local variable works."
  (let ((temp-file (make-temp-file "flywrite-test" nil ".txt")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert
             "-*- flywrite-system-prompt: prose -*-\n\n"
             "Some sample text.\n"))
          (with-current-buffer (find-file-noselect temp-file)
            (unwind-protect
                (should (eq flywrite-system-prompt 'prose))
              (kill-buffer))))
      (delete-file temp-file))))


(ert-deftest flywrite-test-prompt-change-clears-diagnostics ()
  "Changing `flywrite-system-prompt' clears diagnostics in active buffers."
  (with-temp-buffer
    (let ((flywrite-api-url "https://api.anthropic.com/v1/messages")
          (flywrite-api-key "test-key")
          (flywrite-system-prompt 'academic)
          (clear-called nil))
      (flywrite-mode 1)
      (insert "Test text.")
      ;; Intercept report-fn to detect clearing
      (let ((orig-report-fn flywrite--report-fn))
        (setq flywrite--report-fn
              (lambda (diags &rest args)
                (when (null diags) (setq clear-called t))
                (apply orig-report-fn diags args))))
      (setq-local flywrite-system-prompt 'prose)
      (should clear-called)
      (flywrite-mode -1))))


(ert-deftest flywrite-test-prompt-watcher-logs-new-prompt ()
  "Watcher logs the new prompt text, not the stale pre-set value."
  (with-temp-buffer
    (let ((flywrite-api-url "https://api.anthropic.com/v1/messages")
          (flywrite-api-key "test-key")
          (flywrite-debug t)
          (flywrite-system-prompt 'academic))
      (flywrite-mode 1)
      (setq-local flywrite-system-prompt 'prose)
      (with-current-buffer (get-buffer-create "*flywrite-log*")
        (should (string-match-p "System prompt changed to prose"
                                (buffer-string)))
        (should (string-match-p (regexp-quote flywrite-prose-prompt)
                                (buffer-string)))
        ;; The "System prompt:" log entry should NOT contain the
        ;; academic prompt (which would indicate a stale read).
        (should-not (string-match-p
                     (regexp-quote "Flag informal language")
                     (buffer-string))))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-prompt-watcher-skips-before-enable ()
  "Watcher does not fire when idle-timer is nil (before deferred enable)."
  (with-temp-buffer
    (let ((flywrite-api-url "https://api.anthropic.com/v1/messages")
          (flywrite-api-key "test-key")
          (flywrite-debug t)
          (flywrite-system-prompt 'academic))
      ;; Simulate the state during find-file: flywrite-mode is t but
      ;; flywrite--enable has not yet run (no idle timer).
      (setq flywrite-mode t)
      (let ((log-buf (get-buffer-create "*flywrite-log*")))
        (with-current-buffer log-buf (erase-buffer))
        (setq-local flywrite-system-prompt 'prose)
        (with-current-buffer log-buf
          (should-not (string-match-p "System prompt changed"
                                      (buffer-string))))
        ;; Diagnostics should be untouched (watcher didn't run clear)
        (setq flywrite-mode nil)))))


;;;; ---- Effective model auto-detection ----


(ert-deftest flywrite-test-effective-model-anthropic ()
  "Auto-detect Anthropic model from URL."
  (let ((flywrite-api-model nil)
        (flywrite-api-url "https://api.anthropic.com/v1/messages"))
    (should (string= (flywrite--effective-model)
                     flywrite--default-model-anthropic))))


(ert-deftest flywrite-test-effective-model-openai ()
  "Auto-detect OpenAI model from URL."
  (let ((flywrite-api-model nil)
        (flywrite-api-url "https://api.openai.com/v1/chat/completions"))
    (should (string= (flywrite--effective-model)
                     flywrite--default-model-openai))))


(ert-deftest flywrite-test-effective-model-gemini ()
  "Auto-detect Gemini model from URL."
  (let ((flywrite-api-model nil)
        (flywrite-api-url flywrite-test--gemini-url))
    (should (string= (flywrite--effective-model)
                     flywrite--default-model-gemini))))


(ert-deftest flywrite-test-effective-model-ollama ()
  "Ollama (OpenAI-compatible) defaults to OpenAI model."
  (let ((flywrite-api-model nil)
        (flywrite-api-url "http://localhost:11434/v1/chat/completions"))
    (should (string= (flywrite--effective-model)
                     flywrite--default-model-openai))))


(ert-deftest flywrite-test-effective-model-explicit-override ()
  "Explicit flywrite-api-model overrides auto-detection."
  (let ((flywrite-api-model "my-custom-model")
        (flywrite-api-url "https://api.anthropic.com/v1/messages"))
    (should (string= (flywrite--effective-model) "my-custom-model"))))


(ert-deftest flywrite-test-effective-model-nil-url-errors ()
  "Error when both model and URL are nil."
  (let ((flywrite-api-model nil)
        (flywrite-api-url nil))
    (should-error (flywrite--effective-model) :type 'error)))

(ert-deftest flywrite-test-e2e-same-paragraph-edit-rechecks ()
  "Edit sentence 1 clears diags, re-check restores diag on sentence 2.
One paragraph, two sentences.  First sentence is correct, second has
an error.  Editing the first sentence should clear all diagnostics
in the paragraph, trigger a new API call, and restore the diagnostic
on the unchanged second sentence."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (api-call-count 0)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)

      ;; One paragraph: correct first sentence, error in second
      (insert "The weather is nice today.  Him went to the store.")

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)

        ;; Mock response: flag "Him" in the second sentence
        (let ((inner (json-encode
                      '((suggestions
                         . [((quote . "Him")
                             (reason
                              . "Use \"He\" (subject pronoun)"))])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        ;; --- Step 1: Initial check ---
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 2: Verify one diagnostic underlines "Him" ---
        (should (= api-call-count 1))
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (buffer-substring-no-properties
                            (flymake-diagnostic-beg diag)
                            (flymake-diagnostic-end diag)))))

        ;; --- Step 3: Edit the first sentence (same paragraph) ---
        (goto-char 1)
        (search-forward "nice")
        (replace-match "beautiful")

        ;; --- Step 4: All diagnostics in this paragraph should clear ---
        (should (= (length (flymake-diagnostics)) 0))

        ;; --- Step 5: Re-check fires, same mock response ---
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 6: Verify second API call and diagnostic restored ---
        (should (= api-call-count 2))
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (buffer-substring-no-properties
                            (flymake-diagnostic-beg diag)
                            (flymake-diagnostic-end diag))))))

      (flywrite-mode -1))))

;;;; ---- Race condition: stale response after buffer edit ----


(ert-deftest flywrite-test-race-stale-response-discarded ()
  "Response for a paragraph edited while in-flight is discarded and re-dirtied."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (deferred-callback nil)
         (deferred-resp-buf nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)
      (insert "Him went to the store.")

      ;; Mock response: flag "Him"
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason . "Use \"He\""))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     ;; Defer: capture callback, do not invoke yet
                     (setq deferred-callback callback
                           deferred-resp-buf resp-buf)
                     resp-buf))))

        (flywrite-mode 1)

        ;; Dispatch request (deferred)
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))
        (should deferred-callback)
        (should (= flywrite--in-flight 1))

        ;; Edit the paragraph while request is in-flight
        (goto-char 1)
        (search-forward "store")
        (replace-match "park")

        ;; Now deliver the stale response
        (with-current-buffer deferred-resp-buf
          (goto-char (point-min))
          (funcall deferred-callback nil))

        ;; Stale response should be discarded: no diagnostics applied
        (should (= (length (flymake-diagnostics)) 0))

        ;; The paragraph should be re-dirtied for re-check
        (should flywrite--dirty-registry)

        ;; In-flight should be back to 0
        (should (= flywrite--in-flight 0)))

      (flywrite-mode -1))))


;;;; ---- Race condition: buffer killed while in-flight ----


(ert-deftest flywrite-test-race-buffer-killed-during-flight ()
  "Response arriving after source buffer is killed does not error."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (deferred-callback nil)
         (deferred-resp-buf nil)
         (mock-response-json nil)
         (source-buf nil))

    ;; Mock response: empty suggestions
    (let ((inner (json-encode '((suggestions . [])))))
      (setq mock-response-json
            (json-encode
             `((choices
                . [((message
                     . ((content . ,inner))))])))))

    ;; Pre-create the response buffer so kill-buffer can't destroy it
    ;; (flywrite--disable kills connection-tracked buffers).
    (setq deferred-resp-buf (flywrite-test--make-response-buffer
                             mock-response-json))

    (setq source-buf (generate-new-buffer "*flywrite-test-killed*"))
    (with-current-buffer source-buf
      (text-mode)
      (insert "Hello world.")

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (setq deferred-callback callback)
                   ;; Return a dummy connection buffer (will be killed
                   ;; on disable).  The real response buffer lives
                   ;; outside connection tracking.
                   (generate-new-buffer " *test-conn*"))))

        (flywrite-mode 1)

        ;; Dispatch request (deferred)
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))
        (should deferred-callback)))

    ;; Kill the source buffer while request is in-flight
    (kill-buffer source-buf)
    (should-not (buffer-live-p source-buf))

    ;; Deliver the response — should not error
    (with-current-buffer deferred-resp-buf
      (goto-char (point-min))
      (funcall deferred-callback nil))

    ;; Clean up response buffer if still alive
    (when (buffer-live-p deferred-resp-buf)
      (kill-buffer deferred-resp-buf))))


;;;; ---- Race condition: in-flight counter underflow ----


(ert-deftest flywrite-test-race-inflight-no-underflow ()
  "In-flight counter does not go below 0 when response arrives after disable."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (deferred-callback nil)
         (deferred-resp-buf nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)
      (insert "Hello world.")

      (let ((inner (json-encode '((suggestions . [])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      ;; Pre-create response buffer outside connection tracking
      (setq deferred-resp-buf (flywrite-test--make-response-buffer
                               mock-response-json))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (setq deferred-callback callback)
                   ;; Return a dummy connection buffer
                   (generate-new-buffer " *test-conn*"))))

        (flywrite-mode 1)

        ;; Dispatch request (deferred)
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))
        (should deferred-callback)
        (should (= flywrite--in-flight 1))

        ;; Disable mode — resets in-flight to 0
        (flywrite-mode -1)
        (should (= flywrite--in-flight 0))

        ;; Re-enable so the response handler has a live buffer with state
        (flywrite-mode 1)

        ;; Deliver deferred response
        (with-current-buffer deferred-resp-buf
          (goto-char (point-min))
          (funcall deferred-callback nil))

        ;; In-flight must not go negative
        (should (>= flywrite--in-flight 0)))

      (flywrite-mode -1)
      (when (buffer-live-p deferred-resp-buf)
        (kill-buffer deferred-resp-buf)))))


;;;; ---- Race condition: rapid edit-check-edit ----


(ert-deftest flywrite-test-race-rapid-edit-check-edit ()
  "Rapid edit -> dispatch -> edit discards first response, re-checks."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil)
         (deferred-callback nil)
         (deferred-resp-buf nil)
         (synchronous nil)
         (api-call-count 0))
    (with-temp-buffer
      (text-mode)
      (insert "Him went to the store.")

      ;; Mock: flag "Him"
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason . "Use \"He\""))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (if synchronous
                         (progn
                           (with-current-buffer resp-buf
                             (goto-char (point-min))
                             (funcall callback nil))
                           resp-buf)
                       (setq deferred-callback callback
                             deferred-resp-buf resp-buf)
                       resp-buf)))))

        (flywrite-mode 1)

        ;; Edit 1: dirty and dispatch (deferred)
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))
        (should (= api-call-count 1))

        ;; Edit 2: change the paragraph before response arrives
        (goto-char (point-max))
        (insert "  Really.")

        ;; Deliver first response (stale — paragraph changed)
        (setq synchronous t)
        (with-current-buffer deferred-resp-buf
          (goto-char (point-min))
          (funcall deferred-callback nil))

        ;; First response should be discarded (stale)
        (should (= (length (flymake-diagnostics)) 0))

        ;; Idle timer should dispatch re-check
        (flywrite--idle-timer-fn (current-buffer))
        (should (= api-call-count 2))

        ;; Re-check should produce the diagnostic
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (buffer-substring-no-properties
                            (flymake-diagnostic-beg diag)
                            (flymake-diagnostic-end diag))))))

      (flywrite-mode -1))))


;;;; ---- Race condition: queue drain with stale hash ----


(ert-deftest flywrite-test-race-queue-drain-skips-stale ()
  "Queue drain skips entries whose paragraph was edited after queuing."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (flywrite-max-concurrent 1)
         (api-call-count 0)
         (mock-response-json nil)
         (deferred-callback nil)
         (deferred-resp-buf nil))
    (with-temp-buffer
      (text-mode)
      (insert "First paragraph.\n\nSecond paragraph.")

      (let ((inner (json-encode '((suggestions . [])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     ;; Defer: capture callback, do not invoke yet
                     (setq deferred-callback callback
                           deferred-resp-buf resp-buf)
                     resp-buf))))

        (flywrite-mode 1)

        ;; Manually set up the scenario: P2 dispatched (deferred),
        ;; P1 is queued.  The dirty registry uses push so the last
        ;; entry dispatches first; enqueue P1 first, then P2.
        (let* ((p1-hash (flywrite--content-hash 1 17))
               (p2-hash (flywrite--content-hash 19 36)))
          ;; Queue P1 explicitly in the pending queue
          (setq flywrite--pending-queue
                (list (list (current-buffer) 1 17 p1-hash)))
          ;; Mark P2 as dirty so it dispatches
          (setq flywrite--dirty-registry
                (list (list 19 36 p2-hash))))

        ;; Dispatch: P2 sends (deferred), P1 stays queued.
        (flywrite--idle-timer-fn (current-buffer))
        (should (= api-call-count 1))
        (should (= (length flywrite--pending-queue) 1))

        ;; Verify queued entry is P1 (beg=1)
        (should (= (nth 1 (car flywrite--pending-queue)) 1))

        ;; Edit P1 while it's queued
        (goto-char 1)
        (delete-region 1 6)
        (insert "One")

        ;; Complete P2's request — drain-queue fires and should
        ;; skip P1 (its hash is now stale).
        (with-current-buffer deferred-resp-buf
          (goto-char (point-min))
          (funcall deferred-callback nil))

        ;; Drain should have skipped the stale P1 entry
        (should (= api-call-count 1))
        (should (= flywrite--in-flight 0)))

      (flywrite-mode -1))))


;;;; ---- Race condition: mode disable with pending queue ----


(ert-deftest flywrite-test-race-disable-with-pending-queue ()
  "Disabling mode with entries in the pending queue cleans up."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")

      ;; Manually populate the pending queue
      (let ((buf (current-buffer)))
        (setq flywrite--pending-queue
              (list (list buf 1 17 "hash1")
                    (list buf 19 36 "hash2")
                    (list buf 38 55 "hash3"))))
      (setq flywrite--in-flight 3)

      ;; Disable mode
      (flywrite-mode -1)

      ;; All state should be cleaned up
      (should-not flywrite--pending-queue)
      (should (= flywrite--in-flight 0))
      (should-not flywrite--dirty-registry)
      (should-not flywrite--idle-timer))))


;;;; ---- E2E: multi-paragraph check-buffer ----


(ert-deftest flywrite-test-e2e-check-buffer-multi-paragraph ()
  "check-buffer dispatches all paragraphs, respecting concurrency cap."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (flywrite-max-concurrent 2)
         (flywrite-check-confirm-threshold 100)
         (api-call-count 0)
         (api-call-texts nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)
      (insert (concat "Him went to the store.\n\n"
                      "Her gave it to them.\n\n"
                      "The birds are singing."))

      ;; Mock: flag "Him" and "Her" (birds paragraph won't match)
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason . "Use \"He\""))
                          ((quote . "Her")
                           (reason . "Use \"She\""))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   ;; Record the text sent in the request body
                   (push url-request-data api-call-texts)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)
        (flywrite-check-buffer)

        ;; 3 paragraphs should be dirtied
        (should (= (length flywrite--dirty-registry) 3))

        ;; Fire idle timer to dispatch
        (flywrite--idle-timer-fn (current-buffer))

        ;; All 3 paragraphs should have been checked
        (should (= api-call-count 3))

        ;; "Him" is in paragraph 1, "Her" is in paragraph 2
        ;; Each paragraph is checked independently, so:
        ;; - paragraph 1 has "Him" -> 1 diagnostic
        ;; - paragraph 2 has "Her" -> 1 diagnostic
        ;; - paragraph 3 has no match -> 0 diagnostics
        (should (= (length (flymake-diagnostics)) 2))

        ;; Verify the diagnostic texts
        (let ((texts (mapcar
                      (lambda (d)
                        (buffer-substring-no-properties
                         (flymake-diagnostic-beg d)
                         (flymake-diagnostic-end d)))
                      (flymake-diagnostics))))
          (should (member "Him" texts))
          (should (member "Her" texts))))

      (flywrite-mode -1))))


;;;; ---- E2E: fix one error in multi-diagnostic paragraph ----


(ert-deftest flywrite-test-e2e-fix-one-of-two-diagnostics ()
  "Fix one error in a paragraph with two; re-check keeps the other."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (api-call-count 0)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)
      (insert "Him and her went to the store.")

      ;; Mock: flag both "Him" and "her"
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason . "Use \"He\""))
                          ((quote . "her")
                           (reason . "Use \"she\""))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)

        ;; Initial check: two diagnostics
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))
        (should (= api-call-count 1))
        (should (= (length (flymake-diagnostics)) 2))

        ;; Fix "Him" -> "He"
        (goto-char 1)
        (search-forward "Him")
        (replace-match "He")

        ;; Mock: only flag "her" now
        (let ((inner (json-encode
                      '((suggestions
                         . [((quote . "her")
                             (reason . "Use \"she\""))])))))
          (setq mock-response-json
                (json-encode
                 `((choices
                    . [((message
                         . ((content . ,inner))))])))))

        ;; Re-check
        (flywrite--idle-timer-fn (current-buffer))
        (should (= api-call-count 2))

        ;; Only one diagnostic remaining: "her"
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "her"
                           (buffer-substring-no-properties
                            (flymake-diagnostic-beg diag)
                            (flymake-diagnostic-end diag))))))

      (flywrite-mode -1))))


;;;; ---- E2E: Anthropic response format ----


(ert-deftest flywrite-test-e2e-anthropic-response-format ()
  "End-to-end test with Anthropic API response format."
  (let* ((flywrite-api-url "https://api.anthropic.com/v1/messages")
         (flywrite-api-key "sk-ant-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (api-call-count 0)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)
      (insert "Him went to the store.")

      ;; Anthropic format: content[0].text contains the suggestion JSON
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason . "Use \"He\""))])))))
        (setq mock-response-json
              (json-encode
               `((content . [((type . "text")
                              (text . ,inner))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   ;; Build response with Anthropic HTTP headers
                   (let ((buf (generate-new-buffer " *test-response*")))
                     (with-current-buffer buf
                       (insert
                        "HTTP/1.1 200 OK\r\n"
                        "Content-Type: application/json\r\n\r\n"
                        mock-response-json)
                       (goto-char (point-min))
                       (funcall callback nil))
                     buf))))

        (flywrite-mode 1)

        ;; Dispatch check
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        ;; Verify diagnostic
        (should (= api-call-count 1))
        (should (= (length (flymake-diagnostics)) 1))
        (let ((diag (car (flymake-diagnostics))))
          (should (string= "Him"
                           (buffer-substring-no-properties
                            (flymake-diagnostic-beg diag)
                            (flymake-diagnostic-end diag))))
          (should (string-match-p "\\[flywrite\\]"
                                  (flymake-diagnostic-text diag)))))

      (flywrite-mode -1))))


;;;; ---- E2E: malformed LLM responses ----


(ert-deftest flywrite-test-e2e-malformed-json-no-crash ()
  "Malformed JSON response does not crash; no diagnostics created."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil))
    (with-temp-buffer
      (text-mode)
      (insert "Him went to the store.")

      ;; Mock response: the LLM returns garbage instead of JSON
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (let ((buf (generate-new-buffer " *test-response*")))
                     (with-current-buffer buf
                       (insert "HTTP/1.1 200 OK\r\n"
                               "Content-Type: application/json\r\n\r\n"
                               ;; Inner content is valid JSON wrapping
                               ;; invalid inner JSON
                               (json-encode
                                `((choices
                                   . [((message
                                        . ((content
                                            . "this is not json at all"
                                            ))))]))))
                       (goto-char (point-min))
                       (funcall callback nil))
                     buf))))

        (flywrite-mode 1)
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        ;; Should not crash, no diagnostics
        (should (= (length (flymake-diagnostics)) 0)))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-missing-suggestions-key ()
  "Response JSON with no \"suggestions\" key does not crash."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil))
    (with-temp-buffer
      (text-mode)
      (insert "Him went to the store.")

      ;; Mock response: valid JSON but missing "suggestions"
      (let ((inner (json-encode '((result . "looks good!")))))
        (cl-letf (((symbol-function 'url-retrieve)
                   (lambda (_url callback
                                 &optional _cbargs _silent _inhibit)
                     (let ((buf (generate-new-buffer " *test-response*")))
                       (with-current-buffer buf
                         (insert "HTTP/1.1 200 OK\r\n"
                                 "Content-Type: application/json\r\n\r\n"
                                 (json-encode
                                  `((choices
                                     . [((message
                                          . ((content . ,inner))))]))))
                         (goto-char (point-min))
                         (funcall callback nil))
                       buf))))

          (flywrite-mode 1)
          (flywrite--after-change 1 (point-max) 0)
          (flywrite--idle-timer-fn (current-buffer))

          ;; Should not crash, no diagnostics
          (should (= (length (flymake-diagnostics)) 0))))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-e2e-unmatched-quote-no-diagnostic ()
  "Suggestion with a quote not found in text creates no diagnostic."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)
      (insert "The cat sat on the mat.")

      ;; Mock: the LLM hallucinates a quote not in the text
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "dog ran across")
                           (reason . "Hallucinated quote"))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        ;; No diagnostic because quote doesn't match text
        (should (= (length (flymake-diagnostics)) 0)))

      (flywrite-mode -1))))


;;;; ---- E2E: empty / whitespace-only paragraphs not sent ----


(ert-deftest flywrite-test-empty-paragraph-not-sent ()
  "Empty buffer does not trigger API calls."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (api-call-count 0))
    (with-temp-buffer
      (text-mode)
      ;; Buffer is empty

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    "{}")))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)
        (flywrite--idle-timer-fn (current-buffer))

        ;; No API calls for empty buffer
        (should (= api-call-count 0)))

      (flywrite-mode -1))))


(ert-deftest flywrite-test-whitespace-only-paragraph-not-sent ()
  "Whitespace-only content does not trigger API calls."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (api-call-count 0))
    (with-temp-buffer
      (text-mode)
      (insert "   \n\n   \n\n   ")

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    "{}")))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))

        ;; No API calls for whitespace-only content
        (should (= api-call-count 0)))

      (flywrite-mode -1))))


;;;; ---- E2E: check-at-point dispatches immediately ----


(ert-deftest flywrite-test-e2e-check-at-point-dispatches ()
  "check-at-point removes from checked cache and dispatches immediately."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (api-call-count 0)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)
      (insert "Him went to the store.")

      ;; Mock: flag "Him"
      (let ((inner (json-encode
                    '((suggestions
                       . [((quote . "Him")
                           (reason . "Use \"He\""))])))))
        (setq mock-response-json
              (json-encode
               `((choices
                  . [((message
                       . ((content . ,inner))))])))))

      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (_url callback &optional _cbargs _silent _inhibit)
                   (cl-incf api-call-count)
                   (let ((resp-buf (flywrite-test--make-response-buffer
                                    mock-response-json)))
                     (with-current-buffer resp-buf
                       (goto-char (point-min))
                       (funcall callback nil))
                     resp-buf))))

        (flywrite-mode 1)

        ;; First check: mark as checked via normal flow
        (flywrite--after-change 1 (point-max) 0)
        (flywrite--idle-timer-fn (current-buffer))
        (should (= api-call-count 1))
        (should (= (length (flymake-diagnostics)) 1))

        ;; The paragraph hash is now in checked-paragraphs.
        ;; A normal idle timer would skip it.
        (let ((hash (flywrite--content-hash 1 (point-max))))
          (should (gethash hash flywrite--checked-paragraphs)))

        ;; Use check-at-point to force re-check
        (goto-char 5)
        (flywrite-check-at-point)

        ;; Should have dispatched a second API call
        (should (= api-call-count 2))

        ;; Diagnostic should still be present
        (should (>= (length (flymake-diagnostics)) 1)))

      (flywrite-mode -1))))


;;;; ---- E2E: diagnostics survive paragraph kill and undo ----


(ert-deftest flywrite-test-e2e-diagnostic-survives-para-kill-and-undo ()
  "Diagnostic on paragraph 1 survives killing paragraph 2 and undo.
Para 1 has an error (\"Him\"), para 2 is clean.  Kill para 2,
verify diagnostic persists, undo, verify diagnostic persists."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-idle-delay 0.1)
         (flywrite-eager nil)
         (mock-response-json nil))
    (with-temp-buffer
      (text-mode)

      ;; Para 1 has "Him" (error), para 2 is clean.
      (insert "Him went to the store.\n\nThe weather is nice today.")
      (let ((para2-text "The weather is nice today."))

        (cl-letf (((symbol-function 'url-retrieve)
                   (lambda (_url callback &optional _cbargs _silent _inhibit)
                     (let ((resp-buf (flywrite-test--make-response-buffer
                                      mock-response-json)))
                       (with-current-buffer resp-buf
                         (goto-char (point-min))
                         (funcall callback nil))
                       resp-buf))))

          (flywrite-mode 1)

          ;; Mock response: flag "Him"
          (let ((inner (json-encode
                        '((suggestions
                           . [((quote . "Him")
                               (reason
                                . "Use \"He\" (subject pronoun)"))])))))
            (setq mock-response-json
                  (json-encode
                   `((choices
                      . [((message
                           . ((content . ,inner))))])))))

          ;; --- Step 1: Check all paragraphs ---
          (flywrite--after-change 1 (point-max) 0)
          (flywrite--idle-timer-fn (current-buffer))

          ;; --- Step 2: Verify one diagnostic underlining "Him" ---
          (should (= (length (flymake-diagnostics)) 1))
          (let ((diag (car (flymake-diagnostics))))
            (should (string= "Him"
                             (buffer-substring-no-properties
                              (flymake-diagnostic-beg diag)
                              (flymake-diagnostic-end diag)))))

          ;; --- Step 3: Delete paragraph 2 ---
          (goto-char 1)
          (search-forward "\n\n")
          (delete-region (point) (point-max))

          ;; --- Step 4: Re-check; verify diagnostic still present ---
          (flywrite--idle-timer-fn (current-buffer))
          (should (= (length (flymake-diagnostics)) 1))
          (let ((diag (car (flymake-diagnostics))))
            (should (string= "Him"
                             (flywrite-test--diag-text-at-overlay diag))))

          ;; --- Step 5: Re-insert paragraph 2 (simulates undo) ---
          (goto-char (point-max))
          (insert para2-text)

          ;; --- Step 6: Re-check; verify diagnostic still present ---
          (flywrite--idle-timer-fn (current-buffer))
          (should (= (length (flymake-diagnostics)) 1))
          (let ((diag (car (flymake-diagnostics))))
            (should (string= "Him"
                             (flywrite-test--diag-text-at-overlay diag))))))

      (flywrite-mode -1))))


;;; test-flywrite.el ends here
