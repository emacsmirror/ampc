;;; test-simple.el --- Simple Unit Test Framework for Emacs Lisp 
;; Totally rewritten from Phil Hagelberg's behave.el by rocky
;; See also Christian Ohler's ert http://github.com/ohler/ert

;; Copyright (C) 2010, 2012 Rocky Bernstein

;; Author: Rocky Bernstein
;; URL: http://github.com/rocky/emacs-test-simple
;; Keywords: unit-test 

;; This file is NOT part of GNU Emacs.

;; This is free software; you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free
;; Software Foundation; either version 3, or (at your option) any later
;; version.

;; This file is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with Emacs; see the file COPYING, or type `C-h C-c'. If not,
;; write to the Free Software Foundation at this address:

;;   Free Software Foundation
;;   51 Franklin Street, Fifth Floor
;;   Boston, MA 02110-1301
;;   USA

;;; Commentary:

;; test-simple.el allows you to write tests for your Emacs Lisp
;; code. Executable specifications allow you to check that your code
;; is working correctly in an automated fashion that you can use to
;; drive the focus of your development. (It's related to Test-Driven
;; Development.) You can read up on it at http://behaviour-driven.org.

;; Assertions may have docstrings so that when the specifications
;; aren't met it is easy to see what caused the failure.  

;; When "note" is used subsequent tests are grouped assumed to be
;; related to that not.

;; When you want to run the specs, evaluate the buffer. Or evaluate
;; individual assertions. Results are save in the
;; *test-simple* buffer. 

;;; Implementation

;; Contexts are stored in the *test-simple-contexts* list as structs. Each
;; context has a "specs" slot that contains a list of its specs, which
;; are stored as closures. The expect form ensures that expectations
;; are met and signals test-simple-spec-failed if they are not.

;; Warning: the variable CONTEXT is used within macros
;; in such a way that they could shadow variables of the same name in
;; the code being tested. Future versions will use gensyms to solve
;; this issue, but in the mean time avoid relying upon variables with
;; those names.

;;; To do:

;; Main issues: more expect predicates

;;; Usage:

(eval-when-compile 
  (byte-compile-disable-warning 'cl-functions)
  ;; Somehow disabling cl-functions causes the erroneous message:
  ;;   Warning: the function `reduce' might not be defined at runtime.
  ;; FIXME: isolate, fix and/or report back to Emacs developers a bug
  ;; (byte-compile-disable-warning 'unresolved)
  (require 'cl)
  )
(require 'cl)

(defvar test-simple-debug-on-error nil
  "If non-nil raise an error on the first failure")

(defstruct test-info
  description    ;; description of last group of tests
  assert-count   ;; total number of assertions run 
  failure-count  ;; total number of failures seen
  start-time     ;; Time run started
  )

(defvar test-simple-info (make-test-info)
  "Variable to store testing information for a buffer")

(defun note (description &optional test-info)
  "Adds a name to a group of tests."
  (unless noninteractive
    (test-simple-msg description))
  (unless test-info 
    (setq test-info test-simple-info))
  (setf (test-info-description test-info) description)
)

(defun test-simple-clear (&optional test-info)
  "Initializes and resets everything to run tests. You should run
this before running any assertions. Running more than once clears
out information from the previous run."

  (interactive)
  
  (unless test-info 
    (unless test-simple-info 
      (make-variable-buffer-loal (defvar test-simple-info (make-test-info))))
    (setq test-info test-simple-info))

  (setf (test-info-description test-info) "none set")
  (setf (test-info-start-time test-info) (cadr (current-time)))
  (setf (test-info-assert-count test-info) 0)
  (setf (test-info-failure-count test-info) 0)

  (with-current-buffer (get-buffer-create "*test-simple*")
    (let ((old-read-only inhibit-read-only))
      (setq inhibit-read-only 't)
      (delete-region (point-min) (point-max))
      (setq inhibit-read-only old-read-only)))
  (unless noninteractive
    (message "Test-Simple: test information cleared")))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Assertion tests
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defmacro assert-raises (error-condition body &optional opt-fail-message test-info)
  (let ((fail-message (or opt-fail-message
			  (format "assert-raises did not get expected %s" 
				  error-condition))))
    (list 'condition-case nil
	  (list 'progn body
		(list 'assert-t nil fail-message test-info))
	  (list error-condition '(assert-t t)))))

(defun assert-equal (expected actual &optional opt-fail-message test-info)
  "expectation is that ACTUAL should be equal to EXPECTED."
  (unless test-info (setq test-info test-simple-info))
  (incf (test-info-assert-count test-info))
  (if (not (equal actual expected))
      (let* ((fail-message 
	      (if opt-fail-message
		  (format "\n\tMessage: %s" opt-fail-message)
		""))
	     (expect-message 
	      (format "\tExpected: %s\n\tGot:      %s" expected actual))
	     (test-info-mess 
	      (if (boundp 'test-info)
		  (test-info-description test-info)
		"unset")))
	(add-failure "assert-equal" test-info-mess
		     (concat expect-message fail-message)))
    t))

(defun assert-matches (expected-regexp actual &optional opt-fail-message test-info)
  "expectation is that ACTUAL should match EXPECTED-REGEXP."
  (unless test-info (setq test-info test-simple-info))
  (incf (test-info-assert-count test-info))
  (if (not (string-match expected-regexp actual))
      (let* ((fail-message 
	      (if opt-fail-message
		  (format "\n\tMessage: %s" opt-fail-message)
		""))
	     (expect-message 
	      (format "\tExpected Regexp: %s\n\tGot:      %s" 
		      expected-regexp actual))
	     (test-info-mess 
	      (if (boundp 'test-info)
		  (test-info-description test-info)
		"unset")))
	(add-failure "assert-equal" test-info-mess
		     (concat expect-message fail-message)))
    t))

(defun assert-t (actual &optional opt-fail-message test-info)
  "expectation is that ACTUAL is not nil."
  (assert-nil (not actual) opt-fail-message test-info))

(defun assert-nil (actual &optional opt-fail-message test-info)
  "expectation is that ACTUAL is nil."
  (unless test-info (setq test-info test-simple-info))
  (incf (test-info-assert-count test-info))
  (if actual
      (let* ((fail-message 
	      (if opt-fail-message
		  (format "\n\tMessage: %s" opt-fail-message)
		""))
	     (test-info-mess 
	      (if (boundp 'test-simple-info)
		  (test-info-description test-simple-info)
		"unset")))
	(add-failure "assert-nil" test-info-mess fail-message test-info))
    t))

(defun add-failure(type test-info-msg fail-msg &optional test-info)
  (unless test-info (setq test-info test-simple-info))
  (incf (test-info-failure-count test-info))
  (let ((failure-msg
	 (format "Description: %s, type %s\n%s" test-info-msg type fail-msg))
	(old-read-only inhibit-read-only)
	)
    (save-excursion
      (princ "F")
      (test-simple-msg failure-msg)
      (unless noninteractive
	(if test-simple-debug-on-error
	    (signal 'test-simple-assert-failed failure-msg)
	  (message failure-msg)
	  )))))

(defun end-tests (&optional test-info)
  "Give a tally of the tests run"
  (interactive)
  (unless test-info (setq test-info test-simple-info))
  (test-simple-describe-failures test-info)
  (if noninteractive 
      (progn 
	(switch-to-buffer "*test-simple*")
	(message "%s" (buffer-substring (point-min) (point-max)))))
  (test-info-failure-count test-info))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Reporting
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun test-simple-msg(msg)
  (switch-to-buffer "*test-simple*")
  (let ((old-read-only inhibit-read-only))
    (setq inhibit-read-only 't)
    (insert (concat msg "\n"))
    (setq inhibit-read-only old-read-only)
  ))

(defun test-simple-summary-line(info)
  (let*
      ((failures (test-info-failure-count info))
       (asserts (test-info-assert-count info))
       (problems (concat (number-to-string failures) " failure" 
			 (unless (= 1 failures) "s")))
       (tests (concat (number-to-string asserts) " assertion" 
		      (unless (= 1 asserts) "s")))
       (seconds (- (cadr (current-time)) (test-info-start-time info)))
       )
    (format "\n\n%s over %s (%d seconds)" problems tests seconds)
  ))

(defun test-simple-describe-failures(&optional test-info)
  (unless test-info (setq test-info test-simple-info))
  (goto-char (point-max))
  (test-simple-msg (test-simple-summary-line test-info)))

(provide 'test-simple)
;;; test-simple.el ends here
