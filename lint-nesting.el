;;; lint-nesting.el --- Check control-flow nesting depth -*- lexical-binding: t; indent-tabs-mode: nil; fill-column: 80; -*-

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

(defun lint-nesting--read-forms ()
  "Read all top-level forms from current buffer.
Return list of (START . FORM) pairs."
  (goto-char (point-min))
  (let ((forms nil))
    (condition-case nil
        (while t
          (let ((start (point)))
            (push (cons start (read (current-buffer))) forms)))
      (end-of-file nil))
    (nreverse forms)))

(defun lint-nesting--check-form (form start)
  "Return a violation string if FORM at START exceeds max depth."
  (when (and (listp form)
             (memq (car form)
                   '(defun defmacro cl-defun defsubst)))
    (let* ((name (nth 1 form))
           (max-d (lint-nesting--walk form 0)))
      (when (> max-d lint-nesting-max-depth)
        (save-excursion
          (goto-char start)
          (format "%s:%d: %s has control-flow depth %d (max %d)"
                  lint-nesting-file
                  (line-number-at-pos)
                  name max-d lint-nesting-max-depth))))))

(defun lint-nesting-check ()
  "Check `lint-nesting-file' and return list of violation strings."
  (with-temp-buffer
    (insert-file-contents lint-nesting-file)
    (let ((violations nil))
      (dolist (pair (lint-nesting--read-forms))
        (let ((v (lint-nesting--check-form
                  (cdr pair) (car pair))))
          (when v (push v violations))))
      (nreverse violations))))

;; Parse command-line arguments and check each file
(unless command-line-args-left
  (error "Usage: emacs -Q --batch -l lint-nesting.el FILE..."))
(let ((had-violations nil))
  (dolist (file command-line-args-left)
    (setq lint-nesting-file file)
    (dolist (v (lint-nesting-check))
      (message "%s" v)
      (setq had-violations t)))
  (setq command-line-args-left nil)
  (when had-violations
    (kill-emacs 1)))

;;; lint-nesting.el ends here
