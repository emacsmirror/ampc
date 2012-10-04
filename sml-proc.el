;;; sml-proc.el --- Comint based interaction mode for Standard ML.  -*- lexical-binding: t; coding: utf-8 -*-

;; Copyright (C) 1999,2000,2003,2004,2005,2007,2012  Stefan Monnier
;; Copyright (C) 1994-1997  Matthew J. Morley
;; Copyright (C) 1989       Lars Bo Nielsen

;; ====================================================================

;; This file is not part of GNU Emacs, but it is distributed under the
;; same conditions.

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3, or (at
;; your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING. If not, write to the
;; Free Software Foundation, 675 Mass Ave, Cambridge, MA 0139, USA.
;; (See sml-mode.el for HISTORY.) 

;; ====================================================================

;;; Commentary:

;; FIXME-copyright.

;; Inferior-sml-mode is for interacting with an ML process run under
;; emacs. This uses the comint package so you get history, expansion,
;; backup and all the other benefits of comint. Interaction is
;; achieved by M-x run-sml which starts a sub-process under emacs. You may
;; need to set this up for autoloading in your .emacs:

;; (autoload 'run-sml "sml-proc" "Run an inferior ML process." t)

;; Exactly what process is governed by the variable sml-program-name
;; -- just "sml" by default. If you give a prefix argument (C-u M-x
;; run-sml) you will be prompted for a different program to execute from
;; the default -- if you just hit RETURN you get the default anyway --
;; along with the option to specify any command line arguments. Once
;; you select the ML program name in this manner, it remains the
;; default (unless you set in a hook, or otherwise).

;; NOTE: inferior-sml-mode-hook is run AFTER the ML program has been
;; launched. inferior-sml-load-hook is run only when sml-proc.el is
;; loaded into Emacs.

;; When running an ML process some further key-bindings are effective
;; in sml-mode buffer(s). C-c C-s (switch-to-sml) will split the
;; screen into two windows if necessary and place you in the ML
;; process buffer. In the interaction buffer, C-c C-s is bound to the
;; `sml' command by default (in case you need to restart).

;; C-c C-l (sml-load-file) will load an SML source file into the
;; inferior process, C-c C-r (sml-send-region) will send the current
;; region of text to the ML process, etc. Given a prefix argument to
;; these commands will switch you from the SML buffer to the ML
;; process buffer as well as sending the text. If you get errors
;; reported by the compiler, C-x ` (next-error) will step through
;; the errors with you.

;; NOTE. There is only limited support for this as it obviously
;; depends on the compiler's error messages being recognised by the
;; mode. Error reporting is currently only geared up for SML/NJ,
;; Moscow ML, and Poly/ML.  For other compilers, add the relevant
;; regexp to sml-error-regexp-alist and send it to me.

;; To send pieces of code to the underlying compiler, we never send the text
;; directly but use a temporary file instead.  This breaks if the compiler
;; does not understand `use', but has the benefit of allowing better error
;; reporting.

;; Bugs:

;; Todo:

;; - Keep improving `sml-compile'.

;;; Code:

(eval-when-compile (require 'cl))
(require 'sml-mode)
(require 'comint)
(require 'compile)

(defgroup sml-proc ()
  "Interacting with an SML process."
  :group 'sml)

(defcustom sml-program-name "sml"
  "Program to run as ML."
  :type '(string))

(defcustom sml-default-arg ""
  "Default command line option to pass, if any."
  :type '(string))

(defcustom sml-host-name ""
  "Host on which to run ML."
  :type '(string))

(defcustom sml-config-file "~/.smlproc.sml"
  "File that should be fed to the ML process when started."
  :type '(string))

(defcustom sml-compile-command "CM.make()"
  "The command used by default by `sml-compile'.
See also `sml-compile-commands-alist'.")

(defcustom sml-compile-commands-alist
  '(("CMB.make()" . "all-files.cm")
    ("CMB.make()" . "pathconfig")
    ("CM.make()" . "sources.cm")
    ("use \"load-all\"" . "load-all"))
  "Commands used by default by `sml-compile'.
Each command is associated with its \"main\" file.
It is perfectly OK to associate several files with a command or several
commands with the same file.")

(defvar inferior-sml-mode-hook nil
  "Hook is run when the inferior ML process is started.
All buffer local customisations for the interaction buffers go here.")

(defvar sml-buffer nil
  "The current ML process buffer.

MULTIPLE PROCESS SUPPORT (Whoever wants multi-process support anyway?)
=====================================================================
`sml-mode' supports, in a fairly simple fashion, running multiple ML
processes.  To run multiple ML processes, you start the first up with
\\[sml].  It will be in a buffer named *sml*.  Rename this buffer with
\\[rename-buffer].  You may now start up a new process with another
\\[sml].  It will be in a new buffer, named *sml*.  You can switch
between the different process buffers with \\[switch-to-buffer].

NB *sml* is just the default name for the buffer.  It actually gets
it's name from the value of `sml-program-name' -- *poly*, *smld*,...

If you have more than one ML process around, commands that send text
from source buffers to ML processes -- like `sml-send-function' or
`sml-send-region' -- have to choose a process to send it to.  This is
determined by the global variable `sml-buffer'.  Suppose you have three
inferior ML's running:
    Buffer      Process
    sml         #<process sml>
    mosml       #<process mosml>
    *sml*       #<process sml<2>>
If you do a \\[sml-send-function] command on some ML source code, 
what process do you send it to?

- If you're in a process buffer (sml, mosml, or *sml*), you send it to
  that process (usually makes sense only to `sml-load-file').
- If you're in some other buffer (e.g., a source file), you send it to
  the process attached to buffer `sml-buffer'.

This process selection is performed by function `sml-proc' which looks
at the value of `sml-buffer' -- which must be a Lisp buffer object, or
a string \(or nil\).

Whenever \\[sml] fires up a new process, it resets `sml-buffer' to be
the new process's buffer.  If you only run one process, this will do
the right thing.  If you run multiple processes, you can change
`sml-buffer' to another process buffer with \\[set-variable], or
use the command \\[sml-buffer] in the interaction buffer of choice.")


;;; ALL STUFF THAT DEFAULTS TO THE SML/NJ COMPILER (0.93)

(defvar sml-use-command "use \"%s\""
  "Template for loading a file into the inferior ML process.
Set to \"use \\\"%s\\\"\" for SML/NJ or Edinburgh ML; 
set to \"PolyML.use \\\"%s\\\"\" for Poly/ML, etc.")

(defvar sml-cd-command "OS.FileSys.chDir \"%s\""
  "Command template for changing working directories under ML.
Set this to nil if your compiler can't change directories.

The format specifier \"%s\" will be converted into the directory name
specified when running the command \\[sml-cd].")

(defcustom sml-prompt-regexp "^[-=>#] *"
  "Regexp used to recognise prompts in the inferior ML process."
  :type '(regexp))

(defvar sml-error-regexp-alist
  `( ;; Poly/ML messages
    ("^\\(Error\\|Warning:\\) in '\\(.+\\)', line \\([0-9]+\\)" 2 3)
    ;; Moscow ML
    ("^File \"\\([^\"]+\\)\", line \\([0-9]+\\)\\(-\\([0-9]+\\)\\)?, characters \\([0-9]+\\)-\\([0-9]+\\):" 1 2 5)
    ;; SML/NJ:  the file-pattern is anchored to avoid
    ;; pathological behavior with very long lines.
    ("^[-= ]*\\(.*[^\n)]\\)\\( (.*)\\)?:\\([0-9]+\\)\\.\\([0-9]+\\)\\(-\\([0-9]+\\)\\.\\([0-9]+\\)\\)? \\(Error\\|Warnin\\(g\\)\\): .*" 1
     (3 . 6) (4 . 7) (9))
    ;; SML/NJ's exceptions:  see above.
    ("^ +\\(raised at: \\)?\\(.+\\):\\([0-9]+\\)\\.\\([0-9]+\\)\\(-\\([0-9]+\\)\\.\\([0-9]+\\)\\)" 2
     (3 . 6) (4 . 7)))
  "Alist that specifies how to match errors in compiler output.
See `compilation-error-regexp-alist' for a description of the format.")

;; font-lock support
(defconst inferior-sml-font-lock-keywords
  `(;; prompt and following interactive command
    ;; FIXME: Actually, this should already be taken care of by comint.
    (,(concat "\\(" sml-prompt-regexp "\\)\\(.*\\)")
     (1 font-lock-prompt-face)
     (2 font-lock-command-face keep))
    ;; CM's messages
    ("^\\[\\(.*GC #.*\n\\)*.*\\]" . font-lock-comment-face)
    ;; SML/NJ's irritating GC messages
    ("^GC #.*" . font-lock-comment-face))
  "Font-locking specification for inferior SML mode.")

(defface font-lock-prompt-face
  '((t (:bold t)))
  "Font Lock mode face used to highlight prompts."
  :group 'font-lock-highlighting-faces)
(defvar font-lock-prompt-face 'font-lock-prompt-face
  "Face name to use for prompts.")

(defface font-lock-command-face
  '((t (:bold t)))
  "Font Lock mode face used to highlight interactive commands."
  :group 'font-lock-highlighting-faces)
(defvar font-lock-command-face 'font-lock-command-face
  "Face name to use for interactive commands.")

(defconst inferior-sml-font-lock-defaults
  '(inferior-sml-font-lock-keywords nil nil nil nil))


;;; CODE

(defvar inferior-sml-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map "\C-c\C-s" 'run-sml)
    (define-key map "\C-c\C-l" 'sml-load-file)
    (define-key map "\t" 'completion-at-point)
    map)
  "Keymap for inferior-sml mode")

;; buffer-local

(defvar sml-temp-file nil)

(defun sml-proc-buffer ()
  "Return the current ML process buffer.
or the current buffer if it is in `inferior-sml-mode'.  Raises an error
if the variable `sml-buffer' does not appear to point to an existing
buffer."
  (or (and (eq major-mode 'inferior-sml-mode) (current-buffer))
      (and sml-buffer
	   (let ((buf (get-buffer sml-buffer)))
	     ;; buffer-name returns nil if the buffer has been killed
	     (and buf (buffer-name buf) buf)))
      ;; no buffer found, make a new one
      (save-excursion (call-interactively 'run-sml))))

(defun sml-buffer (echo)
  "Make the current buffer the current `sml-buffer' if that is sensible.
Lookup variable `sml-buffer' to see why this might be useful.
If prefix argument ECHO is set, then it only reports on the current state."
  (interactive "P")
  (when (not echo)
    (setq sml-buffer
	  (if (eq major-mode 'inferior-sml-mode) (current-buffer)
	    (read-buffer "Set ML process buffer to: " nil t))))
  (message "ML process buffer is now %s."
	   (or (ignore-errors (buffer-name (get-buffer sml-buffer)))
	       "undefined")))

(defun sml-proc ()
  "Return the current ML process.  See variable `sml-buffer'."
  (assert (eq major-mode 'inferior-sml-mode))
  (or (get-buffer-process (current-buffer))
      (progn (call-interactively 'run-sml)
	     (get-buffer-process (current-buffer)))))

(defun sml-proc-comint-input-filter-function (str)
  ;; `compile.el' in Emacs-22 fails to notice that file location info from
  ;; errors should be recomputed afresh (without using stale info from
  ;; earlier compilations).  We used to cause a refresh in sml-send-string,
  ;; but this doesn't catch the case when the user types commands directly
  ;; at the prompt.
  (compilation-forget-errors)       ;Has to run before compilation-fake-loc.
  (if sml-temp-file
      (compilation-fake-loc (cdr sml-temp-file) (car sml-temp-file)))
  str)

(declare-function smerge-refine-subst "smerge-mode"
                  (beg1 end1 beg2 end2 props-c))

(defun inferior-sml-next-error-hook ()
  ;; Try to recognize SML/NJ type error message and to highlight finely the
  ;; difference between the two types (in case they're large, it's not
  ;; always obvious to spot it).
  ;;
  ;; Sample messages:
  ;; 
  ;; Data.sml:31.9-33.33 Error: right-hand-side of clause doesn't agree with function result type [tycon mismatch]
  ;;   expression:  Hstring
  ;;   result type:  Hstring * int
  ;;   in declaration:
  ;;     des2hs = (fn SYM_ID hs => hs
  ;;                | SYM_OP hs => hs
  ;;                | SYM_CHR hs => hs)
  ;; Data.sml:35.44-35.63 Error: operator and operand don't agree [tycon mismatch]
  ;;   operator domain: Hstring * Hstring
  ;;   operand:         (Hstring * int) * (Hstring * int)
  ;;   in expression:
  ;;     HSTRING.ieq (h1,h2)
  ;; vparse.sml:1861.6-1922.14 Error: case object and rules don't agree [tycon mismatch]
  ;;   rule domain: STConstraints list list option
  ;;   object: STConstraints list option
  ;;   in expression:
  (save-current-buffer
    (when (and (derived-mode-p 'sml-mode 'inferior-sml-mode)
               (boundp 'next-error-last-buffer)
               (bufferp next-error-last-buffer)
               (set-buffer next-error-last-buffer)
               (derived-mode-p 'inferior-sml-mode)
               ;; The position of `point' is not guaranteed :-(
               (looking-at (concat ".*\\[tycon mismatch\\]\n"
                                   "  \\(operator domain\\|expression\\|rule domain\\): +")))
      (require 'smerge-mode)
      (save-excursion
        (let ((b1 (match-end 0))
              e1 b2 e2)
          (when (re-search-forward "\n  in \\(expression\\|declaration\\):\n"
                                   nil t)
            (setq e2 (match-beginning 0))
            (when (re-search-backward
                   "\n  \\(operand\\|result type\\|object\\): +"
                   b1 t)
              (setq e1 (match-beginning 0))
              (setq b2 (match-end 0))
              (smerge-refine-subst b1 e1 b2 e2
                                   '((face . smerge-refined-change))))))))))

(define-derived-mode inferior-sml-mode comint-mode "Inferior-SML"
  "Major mode for interacting with an inferior ML process.

The following commands are available:
\\{inferior-sml-mode-map}

An ML process can be fired up (again) with \\[sml].

Customisation: Entry to this mode runs the hooks on `comint-mode-hook'
and `inferior-sml-mode-hook' (in that order).

Variables controlling behaviour of this mode are

`sml-program-name' (default \"sml\")
    Program to run as ML.

`sml-use-command' (default \"use \\\"%s\\\"\")
    Template for loading a file into the inferior ML process.

`sml-cd-command' (default \"System.Directory.cd \\\"%s\\\"\")
    ML command for changing directories in ML process (if possible).

`sml-prompt-regexp' (default \"^[\\-=] *\")
    Regexp used to recognise prompts in the inferior ML process.

You can send text to the inferior ML process from other buffers containing
ML source.
    `switch-to-sml' switches the current buffer to the ML process buffer.
    `sml-send-function' sends the current *paragraph* to the ML process.
    `sml-send-region' sends the current region to the ML process.

    Prefixing the sml-send-<whatever> commands with \\[universal-argument]
    causes a switch to the ML process buffer after sending the text.

For information on running multiple processes in multiple buffers, see
documentation for variable `sml-buffer'.

Commands:
RET after the end of the process' output sends the text from the
    end of process to point.
RET before the end of the process' output copies the current line
    to the end of the process' output, and sends it.
DEL converts tabs to spaces as it moves back.
TAB file name completion, as in shell-mode, etc.."
  (setq comint-prompt-regexp sml-prompt-regexp)
  (sml-mode-variables)

  ;; We have to install it globally, 'cause it's run in the *source* buffer :-(
  (add-hook 'next-error-hook 'inferior-sml-next-error-hook)

  ;; Make TAB add a " rather than a space at the end of a file name.
  (set (make-local-variable 'comint-completion-addsuffix) '(?/ . ?\"))
  (add-hook 'comint-input-filter-functions
            'sml-proc-comint-input-filter-function nil t)

  (set (make-local-variable 'font-lock-defaults)
       inferior-sml-font-lock-defaults)

  ;; Compilation support (used for `next-error').
  ;; The keymap of compilation-minor-mode is too unbearable, so we
  ;; just can't use the minor-mode if we can't override the map.
  (set (make-local-variable 'compilation-error-regexp-alist)
       sml-error-regexp-alist)
  (compilation-minor-mode 1)
  ;; Eliminate compilation-minor-mode's map.
  (let ((map (make-sparse-keymap)))
    (dolist (keys '([menu-bar] [follow-link]))
      ;; Preserve some of the bindings.
      (define-key map keys (lookup-key compilation-minor-mode-map keys)))
    (add-to-list 'minor-mode-overriding-map-alist
                 (cons 'compilation-minor-mode map)))
  ;; I'm sure people might kill me for that. ;FIXME: move it to sml-mode?
  (set (make-local-variable 'compilation-error-screen-columns) nil)

  (setq mode-line-process '(": %s")))

;;; FOR RUNNING ML FROM EMACS

;;;###autoload (autoload 'run-sml "sml-proc" nil t)
(defalias 'run-sml 'sml-run)
(defun sml-run (cmd arg &optional host)
  "Run the program CMD with given arguments ARG.
The command is run in buffer *CMD* using mode `inferior-sml-mode'.
If the buffer already exists and has a running process, then
just go to this buffer.

If a prefix argument is used, the user is also prompted for a HOST
on which to run CMD using `remote-shell-program'.

\(Type \\[describe-mode] in the process's buffer for a list of commands.)"
  (interactive
   (list
    (read-string "ML command: " sml-program-name)
    (if (or current-prefix-arg (> (length sml-default-arg) 0))
	(read-string "Any args: " sml-default-arg)
      sml-default-arg)
    (if (or current-prefix-arg (> (length sml-host-name) 0))
	(read-string "On host: " sml-host-name)
      sml-host-name)))
  (let* ((pname (file-name-nondirectory cmd))
         (args (split-string arg))
	 (file (when (and sml-config-file (file-exists-p sml-config-file))
		 sml-config-file)))
    ;; and this -- to keep these as defaults even if
    ;; they're set in the mode hooks.
    (setq sml-program-name cmd)
    (setq sml-default-arg arg)
    (setq sml-host-name host)
    ;; For remote execution, use `remote-shell-program'
    (when (> (length host) 0)
      (setq args (list* host "cd" default-directory ";" cmd args))
      (setq cmd remote-shell-program))
    ;; go for it
    (let ((exec-path (if (and (file-name-directory cmd)
                              (not (file-name-absolute-p cmd)))
			 ;; If the command has slashes, make sure we
			 ;; first look relative to the current directory.
			 ;; Emacs-21 does it for us, but not Emacs-20.
			 (cons default-directory exec-path) exec-path)))
      (setq sml-buffer (apply 'make-comint pname cmd file args)))

    (pop-to-buffer sml-buffer)
    (inferior-sml-mode)
    (goto-char (point-max))
    sml-buffer))

(defun switch-to-sml (eobp)
  "Switch to the ML process buffer.
Move point to the end of buffer unless prefix argument EOBP is set."
  (interactive "P")
  (pop-to-buffer (sml-proc-buffer))
  (unless eobp
    (push-mark (point) t)
    (goto-char (point-max))))

(defun sml-send-region (start end &optional and-go)
  "Send current region START..END to the inferior ML process.
Prefix AND-GO argument means `switch-to-sml' afterwards.

The region is written out to a temporary file and a \"use <temp-file>\" command
is sent to the compiler.
See variables `sml-use-command'."
  (interactive "r\nP")
  (if (= start end)
      (message "The region is zero (ignored)")
    (let* ((buf (sml-proc-buffer))
	   (marker (copy-marker start))
	   (tmp (make-temp-file "sml")))
      (write-region start end tmp nil 'silently)
      (with-current-buffer buf
	(when sml-temp-file
	  (ignore-errors (delete-file (car sml-temp-file)))
	  (set-marker (cdr sml-temp-file) nil))
	(setq sml-temp-file (cons tmp marker))
	(sml-send-string (format sml-use-command tmp) nil and-go)))))

;; This is quite bogus, so it isn't bound to a key by default.
;; Anyone coming up with an algorithm to recognise fun & local
;; declarations surrounding point will do everyone a favour!

(defun sml-send-function (&optional and-go)
  "Send current paragraph to the inferior ML process. 
With a prefix argument AND-GO switch to the sml buffer as well 
\(cf. `sml-send-region'\)."
  (interactive "P")
  (save-excursion
    (sml-mark-function)
    (sml-send-region (point) (mark)))
  (if and-go (switch-to-sml nil)))

(defvar sml-source-modes '(sml-mode)
  "Used to determine if a buffer contains ML source code.
If it's loaded into a buffer that is in one of these major modes, it's
considered an ML source file by `sml-load-file'.  Used by these commands
to determine defaults.")

(defun sml-send-buffer (&optional and-go)
  "Send buffer to inferior shell running ML process. 
With a prefix argument AND-GO switch to the sml buffer as well
\(cf. `sml-send-region'\)."
  (interactive "P")
  (sml-send-region (point-min) (point-max) and-go))

;; Since sml-send-function/region take an optional prefix arg, these
;; commands are redundant. But they are kept around for the user to
;; bind if she wishes, since its easier to type C-c r than C-u C-c C-r.

(defun sml-send-region-and-go (start end)
  "Send current region START..END to the inferior ML process, and go there."
  (interactive "r")
  (sml-send-region start end t))

(defun sml-send-function-and-go ()
  "Send current paragraph to the inferior ML process, and go there."
  (interactive)
  (sml-send-function t))

;;; LOADING AND IMPORTING SOURCE FILES:

(defvar sml-prev-dir/file nil
  "Cache for (DIRECTORY . FILE) pair last.
Set in `sml-load-file' and `sml-cd' commands.
Used to determine the default in the next `sml-load-file'.")

(defun sml-load-file (&optional and-go)
  "Load an ML file into the current inferior ML process. 
With a prefix argument AND-GO switch to sml buffer as well.

This command uses the ML command template `sml-use-command' to construct
the command to send to the ML process\; a trailing \"\;\\n\" will be added
automatically."
  (interactive "P")
  (let ((file (car (comint-get-source
		    "Load ML file: " sml-prev-dir/file sml-source-modes t))))
    (with-current-buffer (sml-proc-buffer)
      ;; Check if buffer needs saving.  Should (save-some-buffers) instead?
      (comint-check-source file)
      (setq sml-prev-dir/file
	    (cons (file-name-directory file) (file-name-nondirectory file)))
      (sml-send-string (format sml-use-command file) nil and-go))))

(defun sml-cd (dir)
  "Change the working directory of the inferior ML process.
The default directory of the process buffer is changed to DIR.  If the
variable `sml-cd-command' is non-nil it should be an ML command that will
be executed to change the compiler's working directory\; a trailing
\"\;\\n\" will be added automatically."
  (interactive "DSML Directory: ")
  (let ((dir (expand-file-name dir)))
    (with-current-buffer (sml-proc-buffer)
      (sml-send-string (format sml-cd-command dir) t)
      (setq default-directory (file-name-as-directory dir)))
    (setq sml-prev-dir/file (cons dir nil))))

(defun sml-send-string (str &optional print and-go)
  (let ((proc (sml-proc))
	(str (concat str ";\n"))
	(win (get-buffer-window (current-buffer) 'visible)))
    (when win (select-window win))
    (goto-char (point-max))
    (when print (insert str))
    (set-marker (process-mark proc) (point-max))
    (setq compilation-last-buffer (current-buffer))
    (comint-send-string proc str)
    (when and-go (switch-to-sml nil))))

(defun sml-compile (command &optional and-go)
  "Pass a COMMAND to the SML process to compile the current program.

You can then use the command \\[next-error] to find the next error message
and move to the source code that caused it.

Interactively, prompts for the command if `compilation-read-command' is
non-nil.  With prefix arg, always prompts.

Prefix arg AND-GO also means to `switch-to-sml' afterwards."
  (interactive
   (let* ((dir default-directory)
	  (cmd "cd \"."))
     ;; Look for files to determine the default command.
     (while (and (stringp dir)
		 (dolist (cf sml-compile-commands-alist 1)
		   (when (file-exists-p (expand-file-name (cdr cf) dir))
		     (setq cmd (concat cmd "\"; " (car cf))) (return nil))))
       (let ((newdir (file-name-directory (directory-file-name dir))))
	 (setq dir (unless (equal newdir dir) newdir))
	 (setq cmd (concat cmd "/.."))))
     (setq cmd
	   (cond
	    ((local-variable-p 'sml-compile-command) sml-compile-command)
	    ((string-match "^\\s-*cd\\s-+\"\\.\"\\s-*;\\s-*" cmd)
	     (substring cmd (match-end 0)))
	    ((string-match "^\\s-*cd\\s-+\"\\(\\./\\)" cmd)
	     (replace-match "" t t cmd 1))
	    ((string-match ";" cmd) cmd)
	    (t sml-compile-command)))
     ;; code taken from compile.el
     (if (or compilation-read-command current-prefix-arg)
	 (list (read-from-minibuffer "Compile command: "
				     cmd nil nil '(compile-history . 1)))
       (list cmd))))
     ;; ;; now look for command's file to determine the directory
     ;; (setq dir default-directory)
     ;; (while (and (stringp dir)
     ;; 	    (dolist (cf sml-compile-commands-alist t)
     ;; 	      (when (and (equal cmd (car cf))
     ;; 			 (file-exists-p (expand-file-name (cdr cf) dir)))
     ;; 		(return nil))))
     ;;   (let ((newdir (file-name-directory (directory-file-name dir))))
     ;;     (setq dir (unless (equal newdir dir) newdir))))
     ;; (setq dir (or dir default-directory))
     ;; (list cmd dir)))
  (set (make-local-variable 'sml-compile-command) command)
  (save-some-buffers (not compilation-ask-about-save) nil)
  (let ((dir default-directory))
    (when (string-match "^\\s-*cd\\s-+\"\\([^\"]+\\)\"\\s-*;" command)
      (setq dir (match-string 1 command))
      (setq command (replace-match "" t t command)))
    (setq dir (expand-file-name dir))
    (with-current-buffer (sml-proc-buffer)
      (setq default-directory dir)
      (sml-send-string (concat (format sml-cd-command dir) "; " command)
                       t and-go))))


(provide 'sml-proc)

;;; Prog-Proc: Interacting with an inferior process from a source buffer.

;; Prog-Proc is a package designed to complement Comint: while Comint was
;; designed originally to handle the needs of inferior process buffers, such
;; as a buffer running a Scheme repl, Comint does not actually provide any
;; functionality that links this process buffer with some source code.
;;
;; That's where Prog-Proc comes into play: it provides the usual commands and
;; key-bindings that lets the user send his code to the underlying repl.

(defvar sml-prog-proc-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [?\C-c ?\C-l] 'sml-prog-proc-load-file)
    (define-key map [?\C-c ?\C-c] 'sml-prog-proc-compile)
    (define-key map [?\C-c ?\C-z] 'sml-prog-proc-switch-to)
    (define-key map [?\C-c ?\C-r] 'sml-prog-proc-send-region)
    (define-key map [?\C-c ?\C-b] 'sml-prog-proc-send-buffer)
    map)
  "Keymap for `sml-prog-proc-mode'.")

(defvar sml-prog-proc--buffer nil
  "The inferior-process buffer to which to send code.")
(make-variable-buffer-local 'sml-prog-proc--buffer)

(defstruct (sml-prog-proc-functions
            (:constructor sml-prog-proc-make)
            (:predicate nil)
            (:copier nil))
  (run :read-only t)
  (load-cmd :read-only t))

(defvar sml-prog-proc-functions nil
  "Struct containing the various functions to create a new process, ...")

(defmacro sml-prog-proc--call (method &rest args)
  `(sml-prog-proc--funcall
    #',(intern (format "sml-prog-proc-functions-%s" method))
    ,@args))
(defun sml-prog-proc--funcall (selector &rest args)
  (if (not sml-prog-proc-functions)
      ;; FIXME: Look for available ones and pick one.
      (error "Not an `sml-prog-proc' buffer")
    (apply (funcall selector sml-prog-proc-functions) args)))

(defun sml-prog-proc-proc ()
  "Return the inferior process for the code in current buffer."
  (or (and (buffer-live-p sml-prog-proc--buffer)
           (get-buffer-process sml-prog-proc--buffer))
      (sml-prog-proc--call run)))

(defun sml-prog-proc-switch-to ()
  "Switch to the buffer running the read-eval-print process."
  (let ((proc (sml-prog-proc-proc)))
    (pop-to-buffer (process-buffer proc))))

(defun sml-prog-proc-send-string (proc str)
  (with-current-buffer (process-buffer proc)
    (comint-send-string proc str)))
    
(defun sml-prog-proc-load-file (file &optional and-go)
  "Load FILE into the read-eval-print process.
FILE is the file visited by the current buffer.
If prefix argument AND-GO is used, then we additionally switch
to the buffer where the process is running."
  (interactive
   (list (or buffer-file-name
             (read-file-name "File to load: " nil nil t))
         current-prefix-arg))
  (comint-check-source file)
  (let ((proc (sml-prog-proc-proc)))
    (sml-prog-proc-send-string proc (sml-prog-proc--call load-cmd file))
    (when and-go (pop-to-buffer (process-buffer proc)))))

(defvar sml-prog-proc--tmp-file nil)

(defun sml-prog-proc-send-region (start end &optional and-go)
  "Send the content of the region to the read-eval-print process.
START..END delimit the region; AND-GO if non-nil indicate to additionally
switch to the process's buffer."
  (interactive "r\nP")
  (if (> start end) (let ((tmp end)) (setq end start) (setq start tmp))
    (if (= start end) (error "Nothing to send: the region is empty")))
  (let ((proc (sml-prog-proc-proc))
        (tmp (make-temp-file "emacs-region")))
    (write-region start end tmp nil 'silently)
    (when sml-prog-proc--tmp-file
      (ignore-errors (delete-file (car sml-prog-proc--tmp-file)))
      (set-marker (cdr sml-prog-proc--tmp-file) nil))
    (setq sml-prog-proc--tmp-file (cons tmp (copy-marker start)))
    (sml-prog-proc-send-string proc (sml-prog-proc--call load-cmd tmp))
    (when and-go (pop-to-buffer (process-buffer proc)))))

(defun sml-prog-proc-send-buffer (&optional and-go)
  "Send the content of the current buffer to the read-eval-print process.
AND-GO if non-nil indicate to additionally switch to the process's buffer."
  (interactive "P")
  (sml-prog-proc-send-region (point-min) (point-max) and-go))

;; FIXME: How 'bout a menu?  Now, that's trickier because keymap inheritance
;; doesn't play nicely with menus!

(define-derived-mode sml-prog-proc-mode prog-mode "Prog-Proc"
  "Major mode for editing source code and interact with an interactive loop."
  )

;;; sml-proc.el ends here
