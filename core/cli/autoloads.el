;;; core/cli/autoloads.el -*- lexical-binding: t; -*-

(defvar doom-autoload-excluded-packages '("gh")
  "What packages whose autoloads file we won't index.

These packages have silly or destructive autoload files that try to load
everyone in the universe and their dog, causing errors that make babies cry. No
one wants that.")

(defvar doom-autoload-cached-vars
  '(load-path
    auto-mode-alist
    Info-directory-list
    doom-disabled-packages)
  "A list of variables to be cached in `doom-package-autoload-file'.")

;; externs
(defvar autoload-timestamps)
(defvar generated-autoload-load-name)

(defun doom-cli-reload-autoloads (&optional type)
  "Reloads FILE (an autoload file), if it needs reloading.

FILE should be one of `doom-autoload-file' or `doom-package-autoload-file'. If
it is nil, it will try to reload both."
  (if type
      (cond ((eq type 'core)
             (doom-cli-reload-core-autoloads doom-autoload-file))
            ((eq type 'package)
             (doom-cli-reload-package-autoloads doom-package-autoload-file))
            ((error "Invalid autoloads file: %s" type)))
    (doom-cli-reload-autoloads 'core)
    (doom-cli-reload-autoloads 'package)))

(defun doom-cli-reload-core-autoloads (file)
  (cl-check-type file string)
  (print! (start "(Re)generating core autoloads..."))
  (print-group!
   (and (print! (start "Generating core autoloads..."))
        (doom-cli--write-autoloads
         file (doom-cli--generate-autoloads
               (cl-loop for dir in (append (list doom-core-dir)
                                           (cdr (doom-module-load-path 'all-p))
                                           (list doom-private-dir))
                        if (doom-glob dir "autoload.el") collect it
                        if (doom-glob dir "autoload/*.el") append it)
               'scan))
        (print! (start "Byte-compiling core autoloads file..."))
        (doom-cli--byte-compile-file file)
        (print! (success "Generated %s")
                (relpath (byte-compile-dest-file file)
                         doom-emacs-dir)))))

(defun doom-cli-reload-package-autoloads (file)
  (cl-check-type file string)
  (print! (start "(Re)generating package autoloads..."))
  (print-group!
   (doom-initialize-packages)
   (and (print! (start "Generating package autoloads..."))
        (doom-cli--write-autoloads
         file
         (doom-cli--generate-var-cache doom-autoload-cached-vars)
         (doom-cli--generate-autoloads
          (mapcar #'straight--autoloads-file
                  (cl-set-difference (hash-table-keys straight--build-cache)
                                     doom-autoload-excluded-packages
                                     :test #'string=))))
        (print! (start "Byte-compiling package autoloads file..."))
        (doom-cli--byte-compile-file file)
        (print! (success "Generated %s")
                (relpath (byte-compile-dest-file file)
                         doom-emacs-dir)))))


;;
;;; Helpers

(defun doom-cli--write-autoloads (file &rest forms)
  (make-directory (file-name-directory file) 'parents)
  (condition-case-unless-debug e
      (with-temp-file file
        (let ((standard-output (current-buffer))
              (print-quoted t)
              (print-level nil)
              (print-length nil))
          (insert ";; -*- lexical-binding: t; -*-\n"
                  ";; This file is autogenerated by Doom, DO NOT EDIT IT!!\n")
          (dolist (form (delq nil forms))
            (mapc #'print form))
          t))
    (error (delete-file file)
           (signal 'doom-autoload-error (list file e)))))

(defun doom-cli--byte-compile-file (file)
  (condition-case-unless-debug e
      (let ((byte-compile-warnings (if doom-debug-mode byte-compile-warnings))
            (byte-compile-dynamic t)
            (byte-compile-dynamic-docstrings t))
        (when (byte-compile-file file)
          (unless doom-interactive-mode
            (add-hook 'doom-cli-post-success-execute-hook #'doom-cli--warn-refresh-session-h))
          (load (byte-compile-dest-file file) nil t)))
    (error
     (delete-file (byte-compile-dest-file file))
     (signal 'doom-autoload-error (list file e)))))

(defun doom-cli--warn-refresh-session-h ()
  (print! "Restart or reload Doom Emacs for changes to take effect:")
  (print-group! (print! "M-x doom/restart-and-restore")
                (print! "M-x doom/restart")
                (print! "M-x doom/reload")))

(defun doom-cli--generate-var-cache (vars)
  `((setq ,@(cl-loop for var in vars
                     append `(,var ',(symbol-value var))))))

(defun doom-cli--filter-form (form &optional expand)
  (let ((func (car-safe form)))
    (cond ((memq func '(provide custom-autoload))
           nil)
          ((and (eq func 'add-to-list)
                (memq (doom-unquote (cadr form))
                      doom-autoload-cached-vars))
           nil)
          ((not (eq func 'autoload))
           form)
          ((and expand (not (file-name-absolute-p (nth 2 form))))
           (defvar doom--autoloads-path-cache nil)
           (setf (nth 2 form)
                 (let ((path (nth 2 form)))
                   (or (cdr (assoc path doom--autoloads-path-cache))
                       (when-let* ((libpath (locate-library path))
                                   (libpath (file-name-sans-extension libpath))
                                   (libpath (abbreviate-file-name libpath)))
                         (push (cons path libpath) doom--autoloads-path-cache)
                         libpath)
                       path)))
           form)
          (form))))

(defun doom-cli--generate-autoloads-autodefs (file buffer module &optional module-enabled-p)
  (with-current-buffer
      (or (get-file-buffer file)
          (autoload-find-file file))
    (goto-char (point-min))
    (while (re-search-forward "^;;;###autodef *\\([^\n]+\\)?\n" nil t)
      (let* ((standard-output buffer)
             (form    (read (current-buffer)))
             (altform (match-string 1))
             (definer (car-safe form))
             (symbol  (doom-unquote (cadr form))))
        (cond ((and (not module-enabled-p) altform)
               (print (read altform)))
              ((memq definer '(defun defmacro cl-defun cl-defmacro))
               (if module-enabled-p
                   (print (make-autoload form file))
                 (cl-destructuring-bind (_ _ arglist &rest body) form
                   (print
                    (if altform
                        (read altform)
                      (append
                       (list (pcase definer
                               (`defun 'defmacro)
                               (`cl-defun `cl-defmacro)
                               (_ type))
                             symbol arglist
                             (format "THIS FUNCTION DOES NOTHING BECAUSE %s IS DISABLED\n\n%s"
                                     module
                                     (if (stringp (car body))
                                         (pop body)
                                       "No documentation.")))
                       (cl-loop for arg in arglist
                                if (and (symbolp arg)
                                        (not (keywordp arg))
                                        (not (memq arg cl--lambda-list-keywords)))
                                collect arg into syms
                                else if (listp arg)
                                collect (car arg) into syms
                                finally return (if syms `((ignore ,@syms)))))))))
               (print `(put ',symbol 'doom-module ',module)))
              ((eq definer 'defalias)
               (cl-destructuring-bind (_ _ target &optional docstring) form
                 (unless module-enabled-p
                   (setq target #'ignore
                         docstring
                         (format "THIS FUNCTION DOES NOTHING BECAUSE %s IS DISABLED\n\n%s"
                                 module docstring)))
                 (print `(put ',symbol 'doom-module ',module))
                 (print `(defalias ',symbol #',(doom-unquote target) ,docstring))))
              (module-enabled-p (print form)))))))

(defun doom-cli--generate-autoloads-buffer (file)
  (when (doom-file-cookie-p file "if" t)
    (let* (;; Prevent `autoload-find-file' from firing file hooks, e.g. adding
           ;; to recentf.
           find-file-hook
           write-file-functions
           ;; Prevent a possible source of crashes when there's a syntax error
           ;; in the autoloads file
           debug-on-error
           ;; The following bindings are in `package-generate-autoloads'.
           ;; Presumably for a good reason, so I just copied them
           (backup-inhibited t)
           (version-control 'never)
           case-fold-search    ; reduce magic
           autoload-timestamps ; reduce noise in generated files
           ;; Needed for `autoload-generate-file-autoloads'
           (generated-autoload-load-name (file-name-sans-extension file))
           (target-buffer (current-buffer))
           (module (doom-module-from-path file))
           (module-enabled-p (or (memq (car module) '(:core :private))
                                 (doom-module-p (car module) (cdr module)))))
      (save-excursion
        (when module-enabled-p
          (quiet! (autoload-generate-file-autoloads file target-buffer)))
        (doom-cli--generate-autoloads-autodefs
         file target-buffer module module-enabled-p)))))

(defun doom-cli--generate-autoloads (files &optional scan)
  (require 'autoload)
  (let (autoloads)
    (dolist (file
             (cl-remove-if-not #'file-readable-p files)
             (nreverse (delq nil autoloads)))
      (with-temp-buffer
        (if scan
            (doom-cli--generate-autoloads-buffer file)
          (insert-file-contents-literally file))
        (save-excursion
          (let ((filestr (prin1-to-string file)))
            (while (re-search-forward "\\_<load-file-name\\_>" nil t)
              ;; `load-file-name' is meaningless in a concatenated
              ;; mega-autoloads file, so we replace references to it with the
              ;; file they came from.
              (unless (doom-point-in-string-or-comment-p)
                (replace-match filestr t t)))))
        (let ((load-file-name file)
              (load-path
               (append (list doom-private-dir)
                       doom-modules-dirs
                       load-path)))
          (condition-case _
              (while t
                (push (doom-cli--filter-form (read (current-buffer))
                                             scan)
                      autoloads))
            (end-of-file)))))))
