;;; lint-nesting.el --- Check control-flow nesting depth -*- lexical-binding: t; -*-

;; Usage: emacs -Q --batch -l lint-nesting.el

;;; Code:

(defvar lint-nesting-max-depth 6
  "Maximum allowed control-flow nesting depth.")

(defvar lint-nesting-file nil
  "File to check.  Set via command-line argument.")

(defvar lint-nesting--control-forms
  '(if when unless cond cl-case pcase pcase-let
    let let*
    while dolist dotimes
    condition-case unwind-protect
    save-excursion save-restriction save-match-data
    with-current-buffer with-temp-buffer
    lambda)
  "Forms that count as control-flow nesting.")

(defun lint-nesting--walk (form depth)
  "Return max control-flow depth in FORM starting from DEPTH."
  (cond
   ((atom form) depth)
   ;; Skip quoted/backquoted data — not executed code
   ((memq (car form) '(quote function backquote \`)) depth)
   (t
    (let ((new-depth (if (and (symbolp (car form))
                              (memq (car form) lint-nesting--control-forms))
                         (1+ depth)
                       depth))
          (max-d 0))
      (setq max-d new-depth)
      (dolist (sub (cdr form))
        (let ((sub-d (lint-nesting--walk sub new-depth)))
          (when (> sub-d max-d)
            (setq max-d sub-d))))
      max-d))))

(defun lint-nesting-check ()
  "Check `lint-nesting-file' and print violations."
  (with-temp-buffer
    (insert-file-contents lint-nesting-file)
    (goto-char (point-min))
    (let ((violations nil))
      (condition-case nil
          (while t
            (let* ((start (point))
                   (form (read (current-buffer))))
              (when (and (listp form)
                         (memq (car form) '(defun defmacro cl-defun defsubst)))
                (let* ((name (nth 1 form))
                       (max-d (lint-nesting--walk form 0)))
                  (when (> max-d lint-nesting-max-depth)
                    (save-excursion
                      (goto-char start)
                      (push (format "%s:%d: %s has control-flow depth %d (max %d)"
                                    lint-nesting-file
                                    (line-number-at-pos)
                                    name max-d lint-nesting-max-depth)
                            violations)))))))
        (end-of-file nil))
      (dolist (v (nreverse violations))
        (princ (concat v "\n"))))))

;; Parse command-line argument
(setq lint-nesting-file (car command-line-args-left))
(setq command-line-args-left (cdr command-line-args-left))
(unless lint-nesting-file
  (error "Usage: emacs -Q --batch -l lint-nesting.el FILE"))
(lint-nesting-check)

;;; lint-nesting.el ends here
