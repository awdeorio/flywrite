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
        (flywrite-flymake (lambda (_diags) (setq called t)))
        (should called)
        (should flywrite--report-fn))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-flymake-backend-reports-existing-diags ()
  "The flymake backend reports existing diagnostics immediately."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Test text.")
      ;; Add a fake diagnostic
      (push (flymake-make-diagnostic
             (current-buffer) 1 5 :note "test [flywrite]")
            flywrite--diagnostics)
      (let ((reported nil))
        (flywrite-flymake (lambda (diags) (setq reported diags)))
        (should (= (length reported) 1)))
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
        (should (= (length flywrite--diagnostics) 1))
        (let ((diag (car flywrite--diagnostics)))
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
        (should (= (length flywrite--diagnostics) 0)))

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

        (should (= (length flywrite--diagnostics) 1))
        (let ((diag (car flywrite--diagnostics)))
          ;; "The show" starts at position 27, not 16
          (should (= (flymake-diagnostic-beg diag) 27))
          (should (= (flymake-diagnostic-end diag) 35))))

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
          (flywrite-system-prompt 'academic))
      (flywrite-mode 1)
      (setq flywrite--diagnostics '(fake-diag))
      (setq-local flywrite-system-prompt 'prose)
      (should (null flywrite--diagnostics))
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

;;; test-flywrite.el ends here
