;;; package-build.el --- Tools for curating the package archive

;; Copyright (C) 2011 Donald Ephraim Curtis <dcurtis@milkbox.net>
;; Copyright (C) 2009 Phil Hagelberg <technomancy@gmail.com>

;; Author: Donald Ephraim Curtis <dcurtis@milkbox.net>
;; Created: 2011-09-30
;; Version: 0.1
;; Keywords: tools

;; This file is not (yet) part of GNU Emacs.
;; However, it is distributed under the same license.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This file allows a curator to publish an archive of Emacs packages.

;; The archive is generated from an index, which contains a list of
;; projects and repositories from which to get them. The term
;; "package" here is used to mean a specific version of a project that
;; is prepared for download and installation.

;; Currently only supports single-file projects stored in git.

;;; Code:

;; Since this library is not meant to be loaded by users
;; at runtime, use of cl functions should not be a problem.
(require 'cl)

(require 'package)

(defvar package-build-working-dir (expand-file-name "working/")
  "Directory in which to keep checkouts.")

(defvar package-build-archive-dir (expand-file-name "archives/")
  "Directory in which to keep compiled archives.")


(defun package-build-checkout-darcs (repo dir)
  "checkout an svn package"
  (with-current-buffer (get-buffer-create "*package-build-checkout*")
    (cond
     ((file-exists-p dir)
      (message "checkout directory exists, updating...")
      (let ((default-directory dir))
        (process-file
         "darcs" nil
         (current-buffer) nil "pull")))
     (t
      (message "cloning repository")
      (process-file
       "darcs" nil
       (current-buffer)
       nil "get" repo dir)))
    (let ((default-directory dir))
      (process-file
       "darcs" nil
       (current-buffer)
       t "changes" "--last" "1"))
    (message 
     (format-time-string
      "%Y%m%d"
      (date-to-time
       (message (progn
                  (re-search-backward
                   "\\([a-zA-Z]\\{3\\} [a-zA-Z]\\{3\\} \\( \\|[0-9]\\)[0-9] [0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\} [A-Za-z]\\{3\\} [0-9]\\{4\\}\\)")
                  (match-string-no-properties 1))))))))

(defun package-build-checkout-svn (repo dir)
  "checkout an svn repo"
  (with-current-buffer (get-buffer-create "*package-build-checkout*")
    (goto-char (point-max))
    (cond
     ((file-exists-p dir)
      (message "checkout directory exists, updating...")
      (let ((default-directory dir))
        (process-file
         "svn" nil
         (current-buffer) nil "up")))
     (t
      (message "cloning repository")
      (process-file
       "svn" nil
       (current-buffer)
       nil "checkout" (concat repo "/trunk") dir)))
    (let ((default-directory dir))
      (process-file
       "svn" nil
       (current-buffer)
       t "info"))
    (message 
     (format-time-string
      "%Y%m%d"
      (date-to-time
       (message (progn
                  (re-search-backward
                   "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\)")
                  (match-string-no-properties 1))))))))

(defun package-build-checkout-git (repo dir)
  "checkout an git repo"
  (with-current-buffer (get-buffer-create "*package-build-checkout*")
    (goto-char (point-max))
    (cond
     ((file-exists-p dir)
      (message "checkout directory exists, updating...")
      (let ((default-directory dir))
        (process-file
         "git" nil
         (current-buffer) nil "pull"))
      )
     (t
      (message "cloning repository")
      (process-file
       "git" nil
       (current-buffer)
       nil "clone" repo dir)))
    (let ((default-directory dir))
      (process-file
       "git" nil
       (current-buffer)
       t "show" "-s" "--format='\%ci'" "HEAD"))
    (message 
     (format-time-string
      "%Y%m%d"
      (date-to-time
       (message (progn
                  (re-search-backward
                   "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\)")
                  (match-string-no-properties 1))))))))


(defun package-build-pkg-file (pkg-file file-name version homepage)
  "build the pkg file"
  (let ((print-level nil)
        (print-length nil)
        (requires nil))
    (write-region
     (concat
      (prin1-to-string
       (list 'define-package
             file-name
             version
             homepage
             (list 'quote
                   ;; Turn version lists into string form.
                   (mapcar
                    (lambda (elt)
                      (list (car elt)
                            (package-version-join (cadr elt))))
                    requires))
             ))
      "\n")
     nil
     pkg-file
     nil nil nil 'excl)))

(defun package-build-get-config (file-name)
  "get the configuration information for the given file-name"
  (let ((config-file (format "epkgs/%s/master" file-name)))
    (cond
     ((file-exists-p config-file)
      (with-temp-buffer
        (insert-file-contents-literally config-file)
        (goto-char (point-min))
        (car
         (read-from-string
          (buffer-substring-no-properties (point-min) (point-max))))))
     (t nil))))

(defvar package-build-alist '())

(defun package-build-read-archive-contents ()
  (let ((archive-file
         (expand-file-name "archive-contents" package-build-archive-dir)))
    (when (file-exists-p archive-file)
      (with-temp-buffer
        (insert-file-contents-literally archive-file)
        (goto-char (point-min))
        (let ((contents (read (current-buffer))))
          (setq package-build-alist (cdr contents)))))))

(defun package-build-create-tar (dir file)
  "create a tar for the file-name with version"
  (let* ((default-directory package-build-working-dir)
        )
    (process-file
     "tar" nil
     (get-buffer-create "*package-build-checkout*")
     nil "-cvf"
     file
     "--exclude=.svn"
     "--exclude=.git*"
     "--exclude=_darcs"
     dir)
    ))


(defun package-build-archive (file-name)
  "build a git package archive"
  (interactive)
  (let* ((desc (package-build-get-config file-name))
         (name (intern file-name))
         (local-dir (file-name-as-directory (expand-file-name file-name package-build-working-dir))))
    (when desc
      (let* ((repo (plist-get desc :repository))
             (repo-type (car repo))
             (repo-url (cdr repo))
             (summary (plist-get desc :summary)))
        (package-build-read-archive-contents)
        
        (let* ((version
                (cond
                 ((eq repo-type 'svn)
                  (message "Subversion")
                  (package-build-checkout-svn repo-url local-dir))
                 ((eq repo-type 'git)
                  (message "Git")
                  (package-build-checkout-git repo-url local-dir))
                 ((eq repo-type 'darcs)
                  (message "Darcs")
                  (package-build-checkout-darcs repo-url local-dir))))
               (pkg-base-dir (concat file-name "-" version))
               (pkg-file (expand-file-name
                          (concat file-name "-pkg.el")
                          (concat (file-name-as-directory package-build-working-dir)
                                  (file-name-as-directory pkg-base-dir))))
               (default-directory package-build-working-dir))
          (when (file-exists-p local-dir)
            (copy-directory file-name pkg-base-dir)
            (unless (file-exists-p pkg-file)
              (package-build-pkg-file pkg-file file-name version summary))
            (package-build-create-tar
             pkg-base-dir
             (expand-file-name
              (concat file-name "-" version ".tar") package-build-archive-dir))
            (delete-directory pkg-base-dir t nil)
            (package-build-add-to-archive-contents name version summary 'tar)
            (package-build-dump-archive-contents)
            )
          )
        ))))

(defun package-build-dump-archive-contents ()
  "dump the archive contents back to the file"
  (write-region
   (concat
    (pp-to-string
     (cons 1 package-build-alist))
    "\n")
   nil
   (expand-file-name "archive-contents" package-build-archive-dir)
   nil nil nil nil))

(defun package-build-add-to-archive-contents (name version homepage type)
  "add an archive to the package-build-alist"
  (let ((existing (assq name package-build-alist)))
    (when existing
      (setq package-build-alist (delq existing package-build-alist)))
    (add-to-list 'package-build-alist
                 (cons name
                       (vector
                        (version-to-list version)
                        nil
                        homepage
                        type)))))
