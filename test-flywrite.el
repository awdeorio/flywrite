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
  (with-temp-buffer
    (text-mode)
    (flywrite-mode 1)
    (insert "Hello world.")
    ;; Simulate a change
    (flywrite--after-change 1 (point-max) 0)
    (should flywrite--dirty-registry)
    (flywrite-mode -1)))

(ert-deftest flywrite-test-after-change-dedup ()
  "Same content hash is not re-dirtied after being checked."
  (with-temp-buffer
    (text-mode)
    (flywrite-mode 1)
    (insert "Hello world.")
    (let ((hash (flywrite--content-hash 1 (point-max))))
      (puthash hash t flywrite--checked-sentences)
      (setq flywrite--dirty-registry nil)
      (flywrite--after-change 1 (point-max) 0)
      (should-not flywrite--dirty-registry))
    (flywrite-mode -1)))

;;;; ---- Clear ----

(ert-deftest flywrite-test-clear-resets-state ()
  "flywrite-clear resets all buffer-local state."
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
    (flywrite-mode -1)))

;;;; ---- Collect units in region ----

(ert-deftest flywrite-test-collect-units-basic ()
  "Collecting units finds sentences in a region."
  (let ((flywrite-granularity 'sentence))
    (with-temp-buffer
      (text-mode)
      (flywrite-mode 1)
      (insert "First sentence.  Second sentence.  Third sentence.")
      (let ((units (flywrite--collect-units-in-region 1 (point-max))))
        (should (>= (length units) 2)))
      (flywrite-mode -1))))

(ert-deftest flywrite-test-collect-units-skips-checked ()
  "Already-checked sentences are not collected."
  (let ((flywrite-granularity 'sentence))
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
  (with-temp-buffer
    (text-mode)
    (flywrite-mode 1)
    (should flywrite-mode)
    (should flywrite--idle-timer)
    (should (memq #'flywrite-flymake flymake-diagnostic-functions))
    (flywrite-mode -1)
    (should-not flywrite-mode)
    (should-not flywrite--idle-timer)))

;;; test-flywrite.el ends here
