;;; test-flywrite.el --- ERT tests for flywrite-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -l flywrite-mode.el -l test-flywrite.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'flywrite-mode)

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


;;;; ---- Unit boundary detection ----


(ert-deftest flywrite-test-sentence-bounds ()
  "Sentence boundaries are detected correctly."
  (let ((flywrite-granularity 'sentence))
    (with-temp-buffer
      (insert "First sentence.  Second sentence.  Third sentence.")
      (let ((bounds (flywrite--unit-bounds-at-pos 1)))
        (should (= (car bounds) 1))
        (should (string= (buffer-substring-no-properties
                           (car bounds) (cdr bounds))
                          "First sentence."))))))


(ert-deftest flywrite-test-paragraph-bounds ()
  "Paragraph boundaries are detected correctly."
  (let ((flywrite-granularity 'paragraph))
    (with-temp-buffer
      (insert "First paragraph line one.\nFirst paragraph line two.\n\nSecond paragraph.")
      (let ((bounds (flywrite--unit-bounds-at-pos 1)))
        (should (= (car bounds) 1))
        (should (string-match-p "First paragraph line one"
                                (buffer-substring-no-properties
                                 (car bounds) (cdr bounds))))))))


(ert-deftest flywrite-test-unit-bounds-nonempty ()
  "Unit bounds end >= beg (never negative-length)."
  (let ((flywrite-granularity 'sentence))
    (with-temp-buffer
      (insert "A.")
      (let ((bounds (flywrite--unit-bounds-at-pos 1)))
        (should (>= (cdr bounds) (car bounds)))))))

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
  "Editing text marks the containing sentence dirty."
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
  "Same content hash is not re-dirtied after being checked."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Hello world.")
      (let ((hash (flywrite--content-hash 1 (point-max))))
        (puthash hash t flywrite--checked-sentences)
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
      (puthash "abc" t flywrite--checked-sentences)
      (push '(buf 1 10 "fakehash") flywrite--pending-queue)
      (flywrite-clear)
      (should-not flywrite--dirty-registry)
      (should-not flywrite--pending-queue)
      (should (= (hash-table-count flywrite--checked-sentences) 0))
      (flywrite-mode -1))))


;;;; ---- Collect units in region ----


(ert-deftest flywrite-test-collect-units-basic ()
  "Collecting units finds sentences in a region."
  (let ((flywrite-granularity 'sentence)
        (flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "First sentence.  Second sentence.  Third sentence.")
      (let ((units (flywrite--collect-units-in-region 1 (point-max))))
        (should (>= (length units) 2)))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-collect-units-skips-checked ()
  "Already-checked sentences are not collected."
  (let ((flywrite-granularity 'sentence)
        (flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Only sentence.")
      (let ((hash (flywrite--content-hash 1 (point-max))))
        (puthash hash t flywrite--checked-sentences))
      (let ((units (flywrite--collect-units-in-region 1 (point-max))))
        (should (= (length units) 0)))
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


;;;; ---- Sentence boundaries with test file content (test00.txt) ----


(ert-deftest flywrite-test-sentence-bounds-plain-text ()
  "Sentence detection in multi-sentence plain text (like test00.txt)."
  (let ((flywrite-granularity 'sentence))
    (with-temp-buffer
      (insert "The quick brown fox jumpted over the lazy dog. Him and his friend went to the store to buy some grocerys. The weather was very extremely hot outside yesterday.")
      ;; First sentence
      (let ((bounds (flywrite--unit-bounds-at-pos 1)))
        (should (string= (buffer-substring-no-properties (car bounds) (cdr bounds))
                          "The quick brown fox jumpted over the lazy dog.")))
      ;; Second sentence (start from middle of it)
      (let ((bounds (flywrite--unit-bounds-at-pos 50)))
        (should (string-match-p "Him and his friend"
                                (buffer-substring-no-properties (car bounds) (cdr bounds)))))
      ;; Third sentence (start from near end)
      (let ((bounds (flywrite--unit-bounds-at-pos 110)))
        (should (string-match-p "The weather was"
                                (buffer-substring-no-properties (car bounds) (cdr bounds))))))))


(ert-deftest flywrite-test-collect-units-plain-text ()
  "Collect all sentences from multi-sentence plain text (test00.txt)."
  (let ((flywrite-granularity 'sentence)
        (flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "The quick brown fox jumpted over the lazy dog. Him and his friend went to the store to buy some grocerys. The weather was very extremely hot outside yesterday.")
      (let ((units (flywrite--collect-units-in-region 1 (point-max))))
        (should (= (length units) 3)))
      (flywrite-mode -1))))


;;;; ---- Paragraph boundaries with multi-paragraph content (test01.md) ----


(ert-deftest flywrite-test-paragraph-bounds-multi ()
  "Paragraph detection in multi-paragraph text (like test01.md)."
  (let ((flywrite-granularity 'paragraph))
    (with-temp-buffer
      (insert "The quick brown fox jumpted over the lazy dog. Him and his friend went to the store.\n\nTheir going to the park later today, irregardless of the rain. Each of the students need to submit there homework.\n\nThe morning light filtered through the curtains and cast long shadows across the floor.")
      ;; First paragraph
      (let ((bounds (flywrite--unit-bounds-at-pos 1)))
        (should (string-match-p "quick brown fox"
                                (buffer-substring-no-properties (car bounds) (cdr bounds))))
        (should (string-match-p "grocerys\\|store"
                                (buffer-substring-no-properties (car bounds) (cdr bounds)))))
      ;; Second paragraph
      (let* ((para2-start (+ 1 (string-match "\n\nTheir"
                                              (buffer-substring-no-properties 1 (point-max)))))
             (bounds (flywrite--unit-bounds-at-pos (+ 3 para2-start))))
        (should (string-match-p "Their going"
                                (buffer-substring-no-properties (car bounds) (cdr bounds))))))))


(ert-deftest flywrite-test-collect-units-paragraphs ()
  "Collect paragraph units from multi-paragraph content."
  (let ((flywrite-granularity 'paragraph)
        (flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "First paragraph content here.\n\nSecond paragraph content here.\n\nThird paragraph content here.")
      (let ((units (flywrite--collect-units-in-region 1 (point-max))))
        (should (= (length units) 3)))
      (flywrite-mode -1))))


;;;; ---- LaTeX content (test02.tex, test04.tex) ----


(ert-deftest flywrite-test-sentence-bounds-latex ()
  "Sentence detection works inside LaTeX document body (test02.tex)."
  (let ((flywrite-granularity 'sentence))
    (with-temp-buffer
      (insert "\\begin{document}\n\nThe quick brown fox jumpted over the lazy dog. Him and his friend went to the store.\n\n\\end{document}")
      ;; Find a sentence inside the document body
      (let ((bounds (flywrite--unit-bounds-at-pos 20)))
        (should (string-match-p "quick brown fox"
                                (buffer-substring-no-properties (car bounds) (cdr bounds))))))))


(ert-deftest flywrite-test-collect-units-latex-prose ()
  "Collect units from LaTeX prose, ignoring preamble-like lines."
  (let ((flywrite-granularity 'sentence)
        (flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "The quick brown fox jumpted over the lazy dog. Him and his friend went to the store to buy some grocerys.")
      (let ((units (flywrite--collect-units-in-region 1 (point-max))))
        (should (= (length units) 2)))
      (flywrite-mode -1))))


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
  "After-change with multiple sentences marks at least one dirty."
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

;;;; ---- Collect units deduplication ----


(ert-deftest flywrite-test-collect-units-no-duplicates ()
  "Collecting units does not produce duplicate entries for the same position."
  (let ((flywrite-granularity 'sentence)
        (flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "One sentence. Another sentence.")
      (let* ((units (flywrite--collect-units-in-region 1 (point-max)))
             (begs (mapcar #'car units)))
        ;; No duplicate start positions
        (should (= (length begs) (length (delete-dups (copy-sequence begs))))))
      (flywrite-mode -1))))


(ert-deftest flywrite-test-collect-units-empty-buffer ()
  "Collecting units in an empty buffer returns nil."
  (let ((flywrite-granularity 'sentence)
        (flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (let ((units (flywrite--collect-units-in-region 1 (point-max))))
        (should (= (length units) 0)))
      (flywrite-mode -1))))


;;;; ---- Flymake backend ----


(ert-deftest flywrite-test-flymake-backend-stores-report-fn ()
  "The flymake backend stores the report function."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (let ((called nil))
        (flywrite-flymake (lambda (diags) (setq called t)))
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
      (push (flymake-make-diagnostic (current-buffer) 1 5 :note "test [flywrite]")
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
        (process-environment (cons "FLYWRITE_API_KEY=sk-env-123" process-environment)))
    (should (string= (flywrite--get-api-key) "sk-env-123"))))


(ert-deftest flywrite-test-api-key-priority ()
  "Direct key takes priority over file and env var."
  (let* ((tmpfile (make-temp-file "flywrite-test-key"))
         (flywrite-api-key "sk-direct")
         (flywrite-api-key-file tmpfile)
         (process-environment (cons "FLYWRITE_API_KEY=sk-env" process-environment)))
    (unwind-protect
        (progn
          (with-temp-file tmpfile (insert "sk-from-file\n"))
          (should (string= (flywrite--get-api-key) "sk-direct")))
      (delete-file tmpfile))))


;;;; ---- Drain queue ----


(ert-deftest flywrite-test-drain-queue-skips-checked ()
  "Drain queue skips entries already in checked-sentences."
  (let ((flywrite-api-url "http://localhost:0/v1/chat/completions"))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "Hello world.")
      (let ((hash (flywrite--content-hash 1 (point-max))))
        (puthash hash t flywrite--checked-sentences)
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
        (puthash hash t flywrite--checked-sentences)
        (setq flywrite--in-flight 1)
        ;; Create a fake response buffer for the handler
        (with-temp-buffer
          (insert "HTTP/1.1 429 Too Many Requests\r\n\r\n{}")
          (goto-char (point-min))
          (flywrite--handle-response status buf 1 15 hash (current-time)))
        ;; Hash should still be checked (not removed)
        (should (gethash hash flywrite--checked-sentences)))
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
        (puthash hash t flywrite--checked-sentences)
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
        (puthash hash t flywrite--checked-sentences)
        (setq flywrite--in-flight 1)
        (with-temp-buffer
          (insert "HTTP/1.1 500 Internal Server Error\r\n\r\n{}")
          (goto-char (point-min))
          (flywrite--handle-response status buf 1 15 hash (current-time)))
        ;; Hash stays checked — user can flywrite-clear to force recheck
        (should (gethash hash flywrite--checked-sentences)))
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
        (puthash hash t flywrite--checked-sentences)
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
        (puthash hash t flywrite--checked-sentences)
        (setq flywrite--in-flight 1)
        (with-temp-buffer
          (insert "HTTP/1.1 529 Overloaded\r\n\r\n{}")
          (goto-char (point-min))
          (flywrite--handle-response status buf 1 15 hash (current-time)))
        (should (gethash hash flywrite--checked-sentences)))
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
        (puthash hash t flywrite--checked-sentences)
        (setq flywrite--in-flight 1)
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (with-temp-buffer
            (insert "HTTP/1.1 529 Overloaded\r\n\r\n{}")
            (goto-char (point-min))
            (flywrite--handle-response status buf 1 15 hash (current-time))))
        (should (cl-some (lambda (m) (string-match-p "overloaded" m)) messages)))
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
        (puthash hash t flywrite--checked-sentences)
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
      (should-error (flywrite-mode 1) :type 'error)
      (should-not flywrite-mode))))


(ert-deftest flywrite-test-validate-config-no-api-key-anthropic ()
  "Config validation signals error when Anthropic API key is missing."
  (let ((flywrite-api-url "https://api.anthropic.com/v1/messages")
        (flywrite-api-key nil)
        (flywrite-api-key-file nil)
        (process-environment (cons "FLYWRITE_API_KEY=" process-environment)))
    (setenv "FLYWRITE_API_KEY" nil)
    (with-temp-buffer
      (text-mode)
      (should-error (flywrite-mode 1) :type 'error)
      (should-not flywrite-mode))))


(ert-deftest flywrite-test-validate-config-no-api-key-openai ()
  "Config validation signals error when OpenAI API key is missing."
  (let ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
        (flywrite-api-key nil)
        (flywrite-api-key-file nil)
        (process-environment (cons "FLYWRITE_API_KEY=" process-environment)))
    (setenv "FLYWRITE_API_KEY" nil)
    (with-temp-buffer
      (text-mode)
      (should-error (flywrite-mode 1) :type 'error)
      (should-not flywrite-mode))))


(ert-deftest flywrite-test-validate-config-no-api-key-gemini ()
  "Config validation signals error when Gemini API key is missing."
  (let ((flywrite-api-url "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        (flywrite-api-key nil)
        (flywrite-api-key-file nil)
        (process-environment (cons "FLYWRITE_API_KEY=" process-environment)))
    (setenv "FLYWRITE_API_KEY" nil)
    (with-temp-buffer
      (text-mode)
      (should-error (flywrite-mode 1) :type 'error)
      (should-not flywrite-mode))))


;;;; ---- End-to-end: mock API ----


(defun flywrite-test--make-response-buffer (json-body)
  "Create a buffer mimicking an HTTP 200 response with JSON-BODY string."
  (let ((buf (generate-new-buffer " *test-http-response*")))
    (with-current-buffer buf
      (insert "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
              json-body))
    buf))


(ert-deftest flywrite-test-e2e-mock-api ()
  "End-to-end: insert error, check, verify diagnostic, fix, re-check, verify clear."
  (let* ((flywrite-api-url "https://api.openai.com/v1/chat/completions")
         (flywrite-api-key "sk-fake-test-key")
         (flywrite-granularity 'sentence)
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
                 (lambda (url callback &optional _cbargs _silent _inhibit)
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
        (setq mock-response-json
              (json-encode
               `((choices . [((message . ((content .
                  ,(json-encode
                    '((suggestions . [((quote . "Him")
                                       (reason . "Use \"He\" (subject pronoun)"))])))
                  ))))]))))

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
        (setq mock-response-json
              (json-encode
               `((choices . [((message . ((content .
                  ,(json-encode '((suggestions . [])))
                  ))))]))))

        ;; Fire idle timer to dispatch re-check of edited sentence
        (flywrite--idle-timer-fn (current-buffer))

        ;; --- Step 6: Verify diagnostic was removed and API was called again ---
        (should (= api-call-count 2))
        (should (= (length flywrite--diagnostics) 0)))

      (flywrite-mode -1))))


;;;; ---- System prompt resolution ----


(ert-deftest flywrite-test-prompt-prose-symbol ()
  "Symbol `prose' resolves to the prose prompt string."
  (let ((flywrite-system-prompt 'prose))
    (should (string= (flywrite--get-system-prompt) flywrite--prose-prompt))))


(ert-deftest flywrite-test-prompt-academic-symbol ()
  "Symbol `academic' resolves to a string with academic-specific rules."
  (let ((flywrite-system-prompt 'academic))
    (let ((prompt (flywrite--get-system-prompt)))
      (should (stringp prompt))
      (should (string-match-p "informal language" prompt))
      (should (string-match-p "nominalizations" prompt))
      (should (string-match-p "weasel words" prompt)))))


(ert-deftest flywrite-test-prompt-custom-string ()
  "A custom string passes through unchanged."
  (let ((flywrite-system-prompt "my custom prompt"))
    (should (string= (flywrite--get-system-prompt) "my custom prompt"))))


(ert-deftest flywrite-test-prompt-unknown-symbol-errors ()
  "An unknown symbol signals an error."
  (let ((flywrite-system-prompt 'nonexistent))
    (should-error (flywrite--get-system-prompt) :type 'error)))

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
        (flywrite-api-url "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"))
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
