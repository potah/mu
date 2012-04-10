;;; mu4e-utils.el -- part of mu4e, the mu mail user agent
;;
;; Copyright (C) 2011-2012 Dirk-Jan C. Binnema

;; Author: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>
;; Maintainer: Dirk-Jan C. Binnema <djcb@djcbsoftware.nl>
 
;; This file is not part of GNU Emacs.
;;
;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Utility functions used in the mu4e

;;; Code:
(require 'cl)
(require 'html2text)

(defun mu4e-create-maildir-maybe (dir)
  "Offer to create DIR if it does not exist yet. Return t if the
dir already existed, or has been created, nil otherwise."
  (if (and (file-exists-p dir) (not (file-directory-p dir)))
    (error "%s exists, but is not a directory." dir))
  (cond
    ((file-directory-p dir) t)
    ((yes-or-no-p (format "%s does not exist yes. Create now?" dir))
      (mu4e-proc-mkdir dir))
    (t nil)))

(defun mu4e-check-requirements ()
  "Check for the settings required for running mu4e."
  (unless (and mu4e-mu-binary (file-executable-p mu4e-mu-binary))
    (error "Please set `mu4e-mu-binary' to the full path to the mu
    binary."))
  (unless mu4e-maildir
    (error "Please set `mu4e-maildir' to the full path to your
    Maildir directory."))
  ;; expand mu4e-maildir, mu4e-attachment-dir
  (setq
    mu4e-maildir (expand-file-name mu4e-maildir)
    mu4e-attachment-dir (expand-file-name mu4e-attachment-dir))
  (unless (mu4e-create-maildir-maybe mu4e-maildir)
    (error "%s is not a valid maildir directory" mu4e-maildir))
  (dolist (var '( mu4e-sent-folder
		  mu4e-drafts-folder
		  mu4e-trash-folder))
    (unless (and (boundp var) (symbol-value var))
      (error "Please set %S" var))
    (let* ((dir (symbol-value var)) (path (concat mu4e-maildir dir)))
      (unless (string= (substring dir 0 1) "/")
	(error "%S must start with a '/'" dir))
      (unless (mu4e-create-maildir-maybe path)
	(error "%s (%S) does not exist" path var)))))



(defun mu4e-get-maildirs (parentdir)
  "List the maildirs under PARENTDIR." ;; TODO: recursive?
  (let* ((files (directory-files parentdir))
	  (maildirs ;;
	    (remove-if
	      (lambda (file)
		(let ((path (concat parentdir "/" file)))
		  (cond
		    ((string-match "^\\.\\{1,2\\}$" file)  t) ;; remove '..' and '.'
		    ((not (file-directory-p path)) t)   ;; remove non-dirs
		    ((not ;; remove non-maildirs
		       (and (file-directory-p (concat path "/cur"))
			 (file-directory-p (concat path "/new"))
			 (file-directory-p (concat path "/tmp")))) t)
		    (t nil) ;; otherwise, it's probably maildir
		    )))
	      files)))
    (map 'list (lambda(dir) (concat "/" dir)) maildirs)))

(defun mu4e-ask-maildir (prompt)
  "Ask the user for a shortcut (using PROMPT) as defined in
`mu4e-maildir-shortcuts', then return the corresponding folder
name. If the special shortcut 'o' (for _o_ther) is used, or if
`mu4e-maildir-shortcuts is not defined, let user choose from all
maildirs under `mu4e-maildir."
  (unless mu4e-maildir (error "`mu4e-maildir' is not defined"))
  (if (not mu4e-maildir-shortcuts)
    (ido-completing-read prompt (mu4e-get-maildirs mu4e-maildir))
    (let* ((mlist (append mu4e-maildir-shortcuts '(("ther" . ?o))))
	    (fnames
	      (mapconcat
		(lambda (item)
		  (concat
		    "["
		    (propertize (make-string 1 (cdr item))
		      'face 'mu4e-view-link-face)
		    "]"
		    (car item)))
		mlist ", "))
	    (kar (read-char (concat prompt fnames))))
      (if (= kar ?o) ;; user chose 'other'?
	(ido-completing-read prompt (mu4e-get-maildirs mu4e-maildir))
	(or
	  (car-safe (find-if
		      (lambda (item)
			(= kar (cdr item)))
		      mu4e-maildir-shortcuts))
	  (error "Invalid shortcut '%c'" kar))))))


(defun mu4e-ask-bookmark (prompt &optional kar)
  "Ask the user for a bookmark (using PROMPT) as defined in
`mu4e-bookmarks', then return the corresponding query."
  (unless mu4e-bookmarks (error "`mu4e-bookmarks' is not defined"))
  (let* ((bmarks
	   (mapconcat
	     (lambda (bm)
	       (let ((query (nth 0 bm)) (title (nth 1 bm)) (key (nth 2 bm)))
		 (concat
		   "[" (propertize (make-string 1 key)
			 'face 'mu4e-view-link-face)
		   "]"
		   title))) mu4e-bookmarks ", "))
	  (kar (read-char (concat prompt bmarks))))
    (mu4e-get-bookmark-query kar)))

(defun mu4e-get-bookmark-query (kar)
  "Get the corresponding bookmarked query for shortcut character
KAR, or raise an error if none is found."
 (let ((chosen-bm
	 (find-if
	   (lambda (bm)
	     (= kar (nth 2 bm)))
	   mu4e-bookmarks)))
   (if chosen-bm
     (nth 0 chosen-bm)
     (error "Invalid shortcut '%c'" kar))))

(defun mu4e-new-buffer (bufname)
  "Return a new buffer BUFNAME; if such already exists, kill the
old one first."
  (when (get-buffer bufname)
    (progn
      (message (format "Killing %s" bufname))
      (kill-buffer bufname)))
  (get-buffer-create bufname))



;;; converting flags->string and vice-versa ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun mu4e-flags-to-string (flags)
  "Remove duplicates and sort the output of `mu4e-flags-to-string-raw'."
  (concat
    (sort (remove-duplicates
	    (append (mu4e-flags-to-string-raw flags) nil)) '>)))

(defun mu4e-flags-to-string-raw (flags)
  "Convert a list of flags into a string as seen in Maildir
message files; flags are symbols draft, flagged, new, passed,
replied, seen, trashed and the string is the concatenation of the
uppercased first letters of these flags, as per [1]. Other flags
than the ones listed here are ignored.
Also see `mu4e-flags-to-string'.
\[1\]: http://cr.yp.to/proto/maildir.html"
  (when flags
    (let ((kar (case (car flags)
		 ('draft     ?D)
		 ('flagged   ?F)
		 ('new       ?N)
		 ('passed    ?P)
		 ('replied   ?R)
		 ('seen      ?S)
		 ('trashed   ?T)
		 ('attach    ?a)
		 ('encrypted ?x)
		 ('signed    ?s)
		 ('unread    ?u))))
      (concat (and kar (string kar))
	(mu4e-flags-to-string-raw (cdr flags))))))


(defun mu4e-string-to-flags (str)
  "Remove duplicates from the output of `mu4e-string-to-flags-1'"
  (remove-duplicates (mu4e-string-to-flags-1 str)))

(defun mu4e-string-to-flags-1 (str)
  "Convert a string with message flags as seen in Maildir
messages into a list of flags in; flags are symbols draft,
flagged, new, passed, replied, seen, trashed and the string is
the concatenation of the uppercased first letters of these flags,
as per [1]. Other letters than the ones listed here are ignored.
Also see `mu/flags-to-string'.
\[1\]: http://cr.yp.to/proto/maildir.html"
  (when (/= 0 (length str))
    (let ((flag
	    (case (string-to-char str)
	      (?D   'draft)
	      (?F   'flagged)
	      (?P   'passed)
	      (?R   'replied)
	      (?S   'seen)
	      (?T   'trashed))))
      (append (when flag (list flag))
	(mu4e-string-to-flags-1 (substring str 1))))))


(defun mu4e-display-size (size)
  "Get a string representation of SIZE (in bytes)."
  (cond
    ((>= size 1000000) (format "%2.1fM" (/ size 1000000.0)))
    ((and (>= size 1000) (< size 1000000))
      (format "%2.1fK" (/ size 1000.0)))
    ((< size 1000) (format "%d" size))
    (t (propertize "?" 'face 'mu4e-system-face))))


(defun mu4e-body-text (msg)
  "Get the body in text form for this message, which is either :body-txt,
or if not available, :body-html converted to text. By default, it
uses the emacs built-in `html2text'. Alternatively, if
`mu4e-html2text-command' is non-nil, it will use that. Normally,
function prefers the text part, but this can be changed by setting
`mu4e-view-prefer-html'."
  (let* ((txt (plist-get msg :body-txt))
	 (html (plist-get msg :body-html))
	  (body))
    ;; is there an appropriate text body?
    (when (and txt
	    (not (and mu4e-view-prefer-html html))
	    (> (* 10 (length txt))
	      (if html (length html) 0))) ;; real text part?
      (setq body txt))
    ;; no body yet? try html
    (unless body
      (when html
	(setq body
	  (with-temp-buffer
	    (insert html)
	    ;; if defined, use the external tool
	    (if mu4e-html2text-command
	      (shell-command-on-region (point-min) (point-max)
		mu4e-html2text-command nil t)
	      ;; otherwise...
	      (html2text))
	    (buffer-string)))))
    ;; still no body?
    (unless body
      (setq body ""))
    ;; and finally, remove some crap from the remaining string.
    (replace-regexp-in-string "[

(defconst mu4e-update-mail-name "*mu4e-update-mail*"
  "*internal* Name of the process to update mail")

(defun mu4e-update-mail (&optional buf)
  "Update mail (retrieve using `mu4e-get-mail-command' and update
the database afterwards), with output going to BUF if not nil, or
discarded if nil. After retrieving mail, update the database. Note,
function is asynchronous, returns (almost) immediately, and all the
processing takes part in the background, unless buf is non-nil."
  (unless mu4e-get-mail-command
    (error "`mu4e-get-mail-command' is not defined"))
  (let* ((process-connection-type t)
	  (proc (start-process-shell-command
		 mu4e-update-mail-name buf mu4e-get-mail-command)))
    (message "Retrieving mail...")
    (set-process-sentinel proc
      (lambda (proc msg)
	(message nil)
	(mu4e-proc-index mu4e-maildir)
	(let ((buf (process-buffer proc)))
	  (when (buffer-live-p buf)
	    (kill-buffer buf)))))
    (set-process-query-on-exit-flag proc t)))


(defun mu4e-display-manual ()
  "Display the mu4e manual page for the current mode, or go to the
top level if there is none."
  (interactive)
  (info (case major-mode
	  ('mu4e-main-mode    "(mu4e)Main view")
	  ('mu4e-hdrs-mode    "(mu4e)Headers view")
	  ('mu4e-view-mode    "(mu4e)Message view")
	  (t                 "mu4e"))))


(defun mu4e-field-at-point (field)
  "Get FIELD (a symbol, see `mu4e-header-names') for the message at
point in eiter the headers buffer or the view buffer."
  (let ((msg 
	 (cond
	   ((eq major-mode 'mu4e-hdrs-mode)
	     (get-text-property (point) 'msg))
	   ((eq major-mode 'mu4e-view-mode)
	     mu4e-current-msg))))
    (unless msg (error "No message at point"))
    (plist-get msg field))) 

(defun mu4e-kill-buffer-and-window (buf)
  "Kill buffer BUF and any of its windows. Like
`kill-buffer-and-window', but can be called from any buffer, and
simply does not attempt to delete the window if there is none,
instead of erroring out."
  (when (buffer-live-p buf) 
    ((bury-buffer buf)
      (delete-windows-on buf) ;; destroy all windows for this buffer
      (kill-buffer buf)))) 

(defun mu4e-select-other-view ()
  "When the headers view is selected, select the message view (if
that has a live window), and vice versa."
  (interactive)
  (let* ((other-buf
	   (cond
	     ((eq major-mode 'mu4e-hdrs-mode)
	       mu4e-view-buffer)
	     ((eq major-mode 'mu4e-view-mode)
	       mu4e-hdrs-buffer)))
	  (other-win (and other-buf (get-buffer-window other-buf))))
    (if (window-live-p other-win)
      (select-window other-win)
      (message "No window to switch to"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defvar mu4e-update-timer nil
  "*internal* The mu4e update timer.")

(defun mu4e ()
  "Start mu4e. We do this by sending a 'ping' to the mu server
process, and start the main view if the 'pong' we receive from the
server has the expected values."
  (interactive)
  (if (buffer-live-p (get-buffer mu4e-main-buffer-name))
    (switch-to-buffer mu4e-main-buffer-name)
    (mu4e-check-requirements)
    ;; explicit version checks are a bit questionable,
    ;; better to check for specific features
    (if (< emacs-major-version 23)
	(error "Emacs >= 23.x is required for mu4e")
	(progn
	  (setq mu4e-proc-pong-func
	    (lambda (version doccount)
	      (unless (string= version mu4e-mu-version)
		(error "mu server has version %s, but we need %s"
		  version mu4e-mu-version))
	      (mu4e-main-view)
	      (when (and mu4e-update-interval (null mu4e-update-timer))
		(setq mu4e-update-timer
		  (run-at-time
		    0 mu4e-update-interval
		    'mu4e-update-mail)))
	      (message "Started mu4e with %d message%s in store"
		doccount (if (= doccount 1) "" "s"))))
	  (mu4e-proc-ping)))))

(defun mu4e-quit()
  "Quit the mu4e session."
  (interactive)
  (when (y-or-n-p "Are you sure you want to quit? ")
    (message nil)
    (when mu4e-update-timer
      (cancel-timer mu4e-update-timer)
      (setq mu4e-update-timer nil))
    (mu4e-kill-proc)
    (kill-buffer)))

(provide 'mu4e-utils)
;;; End of mu4e-utils.el