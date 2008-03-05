;;; yasnippet.el --- Yet another snippet extension for Emacs.

;; Author: pluskid <pluskid@gmail.com>
;; Version: 0.1

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Nothing.

(require 'cl)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; User customizable variables
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defvar yas/key-syntax "w"
  "Syntax of a key. This is used to determine the current key being 
expanded.")

(defvar yas/indent-line t
  "Each (except the 1st) line of the snippet template is indented to
current column if this variable is non-`nil'.")
(make-variable-buffer-local 'yas/indent-line)

(defvar yas/keymap (make-sparse-keymap)
  "The keymap of snippet.")
(define-key yas/keymap (kbd "TAB") 'yas/next-field-group)
(define-key yas/keymap (kbd "S-TAB") 'yas/prev-field-group)
(define-key yas/keymap (kbd "<S-iso-lefttab>") 'yas/prev-field-group)
(define-key yas/keymap (kbd "<S-tab>") 'yas/prev-field-group)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal variables
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defvar yas/snippet-tables (make-hash-table)
  "A hash table of snippet tables corresponding to each major-mode.")

(defconst yas/escape-backslash
  (concat "YASESCAPE" "BACKSLASH" "PROTECTGUARD"))
(defconst yas/escape-dollar
  (concat "YASESCAPE" "DOLLAR" "PROTECTGUARD"))
(defconst yas/escape-backquote
  (concat "YASESCAPE" "BACKQUOTE" "PROTECTGUARD"))

(defconst yas/field-regexp
  (concat "$\\(?1:[0-9]+\\)" "\\|"
	  "${\\(?:\\(?1:[0-9]+\\):\\)?\\(?2:[^}]*\\)}"))

(defvar yas/snippet-id-seed 0
  "Contains the next id for a snippet")
(defun yas/snippet-next-id ()
  (let ((id yas/snippet-id-seed))
    (incf yas/snippet-id-seed)
    id))

(defvar yas/overlay-modification-hooks
  (list 'yas/overlay-modification-hook)
  "The list of hooks to the overlay modification event.")
(defvar yas/overlay-insert-in-front-hooks
  (list 'yas/overlay-insert-in-front-hook)
  "The list of hooks of the overlay inserted in front event.")
(defvar yas/overlay-insert-behind-hooks
  (list 'yas/overlay-insert-behind-hook)
  "The list of hooks of the overlay inserted behind event.")


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal Structs
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defstruct (yas/snippet (:constructor yas/make-snippet ()))
  "A snippet."
  (groups nil)
  (exit-marker nil)
  (id (yas/snippet-next-id) :read-only t))
(defstruct (yas/group (:constructor yas/make-group (primary-field snippet)))
  "A group contains a list of field with the same number."
  primary-field
  (fields (list primary-field))
  (next nil)
  (prev nil)
  (keymap-overlay nil)
  snippet)
(defstruct (yas/field (:constructor yas/make-field (overlay number value)))
  "A field in a snippet."
  overlay
  number
  value)

(defun yas/snippet-add-field (snippet field)
  "Add FIELD to SNIPPET."
  (let ((group (find field
		     (yas/snippet-groups snippet)
		     :test
		     '(lambda (field group)
			(= (yas/field-number field)
			   (yas/group-number group))))))
    (if group
	(yas/group-add-field group field)
      (push (yas/make-group field snippet)
	    (yas/snippet-groups snippet)))))

(defun yas/group-value (group)
  "Get the default value of the field group."
  (or (yas/field-value
       (yas/group-primary-field group))
      "(no default value)"))
(defun yas/group-number (group)
  "Get the number of the field group."
  (yas/field-number
   (yas/group-primary-field group)))
(defun yas/group-add-field (group field)
  "Add a field to the field group. If the value of the primary 
field is nil and that of the field is not nil, the field is set
as the primary field of the group."
  (push field (yas/group-fields group))
  (when (and (null (yas/field-value (yas/group-primary-field group)))
	     (yas/field-value field))
    (setf (yas/group-primary-field group) field)))

(defun yas/snippet-field-compare (field1 field2)
  "Compare two fields. The field with a number is sorted first.
If they both have a number, compare through the number. If neither
have, compare through the start point of the overlay."
  (let ((n1 (yas/field-number field1))
	(n2 (yas/field-number field2)))
    (if n1
	(if n2
	    (< n1 n2)
	  t)
      (if n2
	  nil
	(< (overlay-start (yas/field-overlay field1))
	   (overlay-start (yas/field-overlay field2)))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internal functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun yas/eval-string (string)
  "Evaluate STRING and convert the result to string."
  (condition-case err
      (format "%s" (eval (read string)))
    (error (format "(error in elisp evaluation: %s)" 
		   (error-message-string err)))))
(defsubst yas/replace-all (from to)
  "Replace all occurance from FROM to TO."
  (goto-char (point-min))
  (while (search-forward from nil t)
    (replace-match to t t)))
(defun yas/snippet-table (mode)
  "Get the snippet table corresponding to MODE."
  (let ((table (gethash mode yas/snippet-tables)))
    (unless table
      (setq table (make-hash-table :test 'equal))
      (puthash mode table yas/snippet-tables))
    table))
(defsubst yas/current-snippet-table ()
  "Get the snippet table for current major-mode."
  (yas/snippet-table major-mode))

(defsubst yas/template (key snippet-table)
  "Get template for KEY in SNIPPET-TABLE."
  (gethash key snippet-table))

(defun yas/current-key ()
  "Get the key under current position. A key is used to find
the template of a snippet in the current snippet-table."
  (let ((start (point))
	(end (point)))
    (save-excursion
      (skip-syntax-backward yas/key-syntax)
      (setq start (point))
      (list (buffer-substring-no-properties start end)
	    start
	    end))))

(defun yas/synchronize-fields (field-group)
  "Update all fields' text according to the primary field."
  (save-excursion
    (let* ((inhibit-modification-hooks t)
	   (primary (yas/group-primary-field field-group))
	   (primary-overlay (yas/field-overlay primary))
	   (text (buffer-substring-no-properties (overlay-start primary-overlay)
						 (overlay-end primary-overlay))))
      (dolist (field (yas/group-fields field-group))
	(let* ((field-overlay (yas/field-overlay field))
	       (original-length (- (overlay-end field-overlay)
				   (overlay-start field-overlay))))
	  (unless (eq field-overlay primary-overlay)
	    (goto-char (overlay-start field-overlay))
	    (insert text)
	    (delete-char original-length)))))))
  
(defun yas/overlay-modification-hook (overlay after? beg end &optional length)
  "Modification hook for snippet field overlay."
  (when (and after? (not undo-in-progress))
    (yas/synchronize-fields (overlay-get overlay 'yas/group))))
(defun yas/overlay-insert-in-front-hook (overlay after? beg end &optional length)
  "Hook for snippet overlay when text is inserted in front of a snippet field."
  (when after?
    (let ((field-group (overlay-get overlay 'yas/group))
	  (inhibit-modification-hooks t))
      (when (not (overlay-get overlay 'yas/modified?))
	(overlay-put overlay 'yas/modified? t)
	(save-excursion
	  (goto-char end)
	  (delete-char (- (overlay-end overlay) end))))
     (yas/synchronize-fields field-group))))
(defun yas/overlay-insert-behind-hook (overlay after? beg end &optional length)
  "Hook for snippet overlay when text is inserted just behind a snippet field."
  (when (and after?
	     (null (yas/current-snippet-overlay beg))) ; not inside another field
    (move-overlay overlay
		  (overlay-start overlay)
		  end)
    (yas/synchronize-fields (overlay-get overlay 'yas/group))))

(defun yas/undo-expand-snippet (start end key snippet)
  "Undo a snippet expansion. Delete the overlays. This undo can't be
redo-ed."
  (let ((undo (car buffer-undo-list)))
    (while (null undo)
      (setq buffer-undo-list (cdr buffer-undo-list))
      (setq undo (car buffer-undo-list)))
    ;; Remove this undo operation record
    (setq buffer-undo-list (cdr buffer-undo-list))
  (let ((inhibit-modification-hooks t)
	(buffer-undo-list t))
    (yas/exit-snippet snippet)
    (goto-char start)
    (delete-char (- end start))
    (insert key))))

(defun yas/expand-snippet (start end template)
  "Expand snippet at current point. Text between START and END
will be deleted before inserting template."
  (goto-char start)

  (let ((key (buffer-substring-no-properties start end))
	(original-undo-list buffer-undo-list)
	(length (- end start))
	(column (current-column)))
    (save-restriction
      (narrow-to-region start start)

      (setq buffer-undo-list t)
      (insert template)

      ;; Step 1: do necessary indent
      (when yas/indent-line
	(let* ((indent (if indent-tabs-mode
			   (concat (make-string (/ column tab-width) ?\t)
				   (make-string (% column tab-width) ?\ ))
			 (make-string column ?\ ))))
	  (goto-char (point-min))
	  (while (and (zerop (forward-line))
		      (= (current-column) 0))
	    (insert indent))))

      ;; Step 2: protect backslash and backquote
      (yas/replace-all "\\\\" yas/escape-backslash)
      (yas/replace-all "\\`" yas/escape-backquote)

      ;; Step 3: evaluate all backquotes
      (goto-char (point-min))
      (while (re-search-forward "`\\([^`]*\\)`" nil t)
	(replace-match (yas/eval-string (match-string-no-properties 1))
		       t t))

      ;; Step 4: protect all escapes, including backslash and backquot
      ;; which may be produced in Step 3
      (yas/replace-all "\\\\" yas/escape-backslash)
      (yas/replace-all "\\`" yas/escape-backquote)
      (yas/replace-all "\\$" yas/escape-dollar)

      (let ((snippet (yas/make-snippet)))
	;; Step 5: Create fields
	(goto-char (point-min))
	(while (re-search-forward yas/field-regexp nil t)
	  (let ((number (match-string-no-properties 1)))
	    (if (and number
		     (string= "0" number))
		(progn
		  (replace-match "")
		  (setf (yas/snippet-exit-marker snippet)
			(copy-marker (point) t)))
	      (yas/snippet-add-field
	       snippet
	       (yas/make-field
		(make-overlay (match-beginning 0) (match-end 0))
		(and number (string-to-number number))
		(match-string-no-properties 2))))))

	;; Step 6: Sort and link each field group
	(setf (yas/snippet-groups snippet)
	      (sort (yas/snippet-groups snippet)
		    '(lambda (group1 group2)
		       (yas/snippet-field-compare
			(yas/group-primary-field group1)
			(yas/group-primary-field group2)))))
	(let ((prev nil))
	  (dolist (group (yas/snippet-groups snippet))
	    (setf (yas/group-prev group) prev)
	    (when prev
	      (setf (yas/group-next prev) group))
	    (setq prev group)))

	;; Step 7: Create keymap overlay for each group
	(dolist (group (yas/snippet-groups snippet))
	  (let* ((overlay (yas/field-overlay (yas/group-primary-field group)))
		 (keymap-overlay (make-overlay (overlay-start overlay)
					       (overlay-end overlay)
					       nil
					       nil
					       t)))
	    (overlay-put keymap-overlay 'keymap yas/keymap)
	    (setf (yas/group-keymap-overlay group) keymap-overlay)))
	
	;; Step 8: Replace fields with default values
	(dolist (group (yas/snippet-groups snippet))
	  (let ((value (yas/group-value group)))
	    (dolist (field (yas/group-fields group))
	      (let* ((overlay (yas/field-overlay field))
		     (start (overlay-start overlay))
		     (end (overlay-end overlay))
		     (length (- end start)))
		(goto-char start)
		(insert value)
		(delete-char length)))))

	;; Step 9: restore all escape characters
	(yas/replace-all yas/escape-dollar "$")
	(yas/replace-all yas/escape-backquote "`")
	(yas/replace-all yas/escape-backslash "\\")

	;; Step 10: Set up properties of overlays
	(dolist (group (yas/snippet-groups snippet))
	  (let ((overlay (yas/field-overlay
			  (yas/group-primary-field group))))
	    (overlay-put overlay 'yas/snippet snippet)
	    (overlay-put overlay 'yas/group group)
	    (overlay-put overlay 'yas/modified? nil)
	    (overlay-put overlay 'modification-hooks yas/overlay-modification-hooks)
	    (overlay-put overlay 'insert-in-front-hooks yas/overlay-insert-in-front-hooks)
	    (overlay-put overlay 'insert-behind-hooks yas/overlay-insert-behind-hooks)
	    (dolist (field (yas/group-fields group))
	      (overlay-put (yas/field-overlay field)
			   'face 
			   'highlight))))

	;; Step 11: move to end and make sure exit-marker exist
	(goto-char (point-max))
	(unless (yas/snippet-exit-marker snippet)
	  (setf (yas/snippet-exit-marker snippet) (copy-marker (point) t)))

	;; Step 12: Construct undo information
	(unless (eq original-undo-list t)
	  (add-to-list 'original-undo-list
		       `(apply yas/undo-expand-snippet
			       ,(point-min)
			       ,(point-max)
			       ,key
			       ,snippet)))

	;; Step 13: remove the trigger key
	(widen)
	(delete-char length)

	;; Step 14: place the cursor at a proper place
	(let ((groups (yas/snippet-groups snippet))
	      (exit-marker (yas/snippet-exit-marker snippet)))
	  (if groups
	      (goto-char (overlay-start 
			  (yas/field-overlay
			   (yas/group-primary-field
			    (car groups)))))
	    ;; no need to call exit-snippet, since no overlay created.
	    (goto-char exit-marker)))

	(setq buffer-undo-list original-undo-list)))))

(defun yas/current-snippet-overlay (&optional point)
  "Get the most proper overlay which is belongs to a snippet."
  (let ((point (or point (point)))
	(snippet-overlay nil))
    (dolist (overlay (overlays-at point))
      (when(overlay-get overlay 'yas/snippet)
	(if (null snippet-overlay)
	    (setq snippet-overlay overlay)
	  (when (> (yas/snippet-id (overlay-get overlay 'yas/snippet))
		   (yas/snippet-id (overlay-get snippet-overlay 'yas/snippet)))
	    (setq snippet-overlay overlay)))))
    snippet-overlay))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; User level functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun yas/define (mode key template)
  "Define a snippet. Expanding KEY into TEMPLATE."
  (puthash key template (yas/snippet-table mode)))

(defun yas/expand ()
  "Expand a snippet. When a snippet is expanded, t is returned,
otherwise, nil returned."
  (interactive)
  (multiple-value-bind (key start end) (yas/current-key)
    (let ((template (yas/template key (yas/current-snippet-table))))
      (if template
	  (progn
	    (yas/expand-snippet start end template)
	    t)
	nil))))

(defun yas/next-field-group ()
  "Navigate to next field group. If there's none, exit the snippet."
  (interactive)
  (let ((overlay (or (yas/current-snippet-overlay)
		     (yas/current-snippet-overlay (- (point) 1)))))
    (if overlay
	(let ((next (yas/group-next
		     (overlay-get overlay 'yas/group))))
	  (if next
	      (goto-char (overlay-start
			  (yas/field-overlay
			   (yas/group-primary-field next))))
	    (yas/exit-snippet (overlay-get overlay 'yas/snippet))))
      (message "Not in a snippet field."))))

(defun yas/prev-field-group ()
  "Navigate to prev field group. If there's none, exit the snippet."
  (interactive)
  (let ((overlay (or (yas/current-snippet-overlay)
		     (yas/current-snippet-overlay (- (point) 1)))))
    (if overlay
	(let ((prev (yas/group-prev
		     (overlay-get overlay 'yas/group))))
	  (if prev
	      (goto-char (overlay-start
			  (yas/field-overlay
			   (yas/group-primary-field prev))))
	    (yas/exit-snippet (overlay-get overlay 'yas/snippet))))
      (message "Not in a snippet field."))))

(defun yas/exit-snippet (snippet)
  "Goto exit-marker of SNIPPET and delete the snippet."
  (interactive)
  (goto-char (yas/snippet-exit-marker snippet))
  (dolist (group (yas/snippet-groups snippet))
    (delete-overlay (yas/group-keymap-overlay group))
    (dolist (field (yas/group-fields group))
      (delete-overlay (yas/field-overlay field)))))

(provide 'yasnippet)
