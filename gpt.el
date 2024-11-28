;;; gpt.el --- Run instruction-following language models -*- lexical-binding: t; -*-

;; Copyright (C) 2022-2024 Andreas Stuhlmueller, 2024- Anselm Coogan

;; Author: Andreas Stuhlmueller <andreas@ought.org>
;; Maintainer: Anselm Coogan <anselm.coogan@gmail.com>
;; Version: 1.0
;; Keywords: openai, anthropic, claude, language, copilot, convenience, tools
;; URL: https://github.com/AnselmC/gpt.el
;; License: MIT
;; SPDX-License-Identifier: MIT
;; Package-Requires: ((emacs "24.4"))

;;; Commentary:

;; This package is a fork of https://github.com/stuhlmueller/gpt.el
;; It aims to provide a more comprehensive integration of GPT support in emacs.
;; Features include: multiple chats with different models, completion at point,
;; and transformations of regions.

(require 'savehist)
(require 'project)

(savehist-mode 1)

(defvar gpt-command-history nil
  "A list of GPT commands that have been entered by the user.")

(defvar gpt-script-path (expand-file-name "gpt.py" (file-name-directory (or load-file-name buffer-file-name)))
  "The path to the Python script used by gpt.el.")

(defvar gpt-model "gpt-4o"
  "The model to use (e.g., 'gpt-4', 'claude-3-5-sonnet-20240620').")

(defvar gpt-max-tokens "2000"
  "The max_tokens value used with the chosen model.")

(defvar gpt-temperature "0"
  "The temperature value used with the chosen model.")

(defvar gpt-openai-key "NOT SET"
  "The OpenAI API key to use.")

(defvar gpt-anthropic-key "NOT SET"
  "The Anthropic API key to use.")

(defvar gpt-api-type 'openai
  "The type of API to use. Either 'openai or 'anthropic.")

(defvar gpt-python-path "python"
  "The path to your python executable.")

(defvar gpt-use-named-buffers t
  "If non-nil, use named buffers for GPT output. Otherwise, use temporary buffers.")

(defvar gpt-project-file-context nil
  "List of project files whose content should be included as context.")

(defvar gpt-project-context-format
  "Project Context Files:\n%s\n\nFile Contents:\n%s\n\n"
  "Format string for including project context in prompts.
First %s is replaced with the list of files, second with their contents.")

(add-to-list 'savehist-additional-variables 'gpt-command-history)

(defun gpt-display-command-history ()
  "Display the `gpt-command-history' in a buffer."
  (interactive)
  (with-current-buffer (get-buffer-create "*GPT Command History*")
    (erase-buffer)
    (insert (mapconcat #'identity gpt-command-history "\n"))
    (switch-to-buffer (current-buffer))))

(defun gpt-clear-command-history ()
  "Clear the `gpt-command-history' list."
  (interactive)
  (setq gpt-command-history nil)
  (message "GPT command history cleared."))

(defun gpt-export-history (file)
  "Export the `gpt-command-history' to FILE."
  (interactive "Export gpt-command-history to file: ")
  (with-temp-file file
    (dolist (cmd gpt-command-history)
      (insert (format "%s\n" cmd)))))

(defun gpt-completing-read-space (prompt collection &optional predicate require-match initial-input hist def inherit-input-method)
  "Read string in minibuffer with completion, treating space literally.

The arguments are the same as for `completing-read', except that
space does not trigger completion or cycling, but inserts a space
character.  PROMPT is the prompt to display, COLLECTION is the
list of possible completions, and the optional arguments PREDICATE
REQUIRE-MATCH INITIAL-INPUT HIST DEF and INHERIT-INPUT-METHOD
have the same meaning as for `completing-read'."
  (let ((minibuffer-local-completion-map
         (let ((map (copy-keymap minibuffer-local-completion-map)))
           (define-key map " " 'self-insert-command)
           map)))
    (completing-read prompt collection predicate require-match initial-input hist def inherit-input-method)))

(defun gpt-read-command ()
  "Read a GPT command from the user with history and completion."
  (let ((cmd (gpt-completing-read-space "Command: " gpt-command-history nil nil nil 'gpt-command-history)))
    (if (string-equal cmd "n/a")
        ""
      (string-trim cmd))))

(defun gpt-run-buffer (buffer)
  "Run GPT command with BUFFER text as input and append output stream to output-buffer."
  (with-current-buffer buffer
    (goto-char (point-max))
    (font-lock-fontify-buffer)
    (gpt-make-process (gpt-create-prompt-file buffer) buffer)
    (message "GPT: Running command...")
    (font-lock-fontify-buffer)))

(defun gpt-insert-command (command)
  "Insert COMMAND to GPT in chat format into the current buffer."
  (let ((template "User: %s\n\nAssistant: "))
    (insert (format template command))))

(defun gpt-get-visible-buffers-content ()
  "Get the content, buffer name, and file name (if available) of all currently visible buffers."
  (let ((visible-buffers (mapcar 'window-buffer (window-list)))
        contents)
    (dolist (buffer visible-buffers contents)
      (with-current-buffer buffer
        (push (format "Buffer Name: %s\nFile Name: %s\nContent:\n%s"
                      (buffer-name)
                      (or (buffer-file-name) "N/A")
                      (buffer-substring-no-properties (point-min) (point-max)))
              contents)))
    (mapconcat 'identity (nreverse contents) "\n\n")))

(defun gpt-get-project-files ()
  "Get list of files in current project using project.el or projectile.el."
  (cond
   ((and (fboundp 'project-current)
         (project-current))
    (project-files (project-current)))
   ((and (fboundp 'projectile-project-root)
         (projectile-project-root))
    (projectile-project-files))
   (t
    (error "No project found. Please use project.el or projectile.el"))))

(defun gpt-read-multiple-files (files)
  "Let user select multiple FILES using completion.
Return list of selected files."
  (let ((choices files)
        (selection nil)
        (done nil)
        (selected-files '()))
    (while (not done)
      (setq selection
            (completing-read
             (format "Select file [%d selected, RET when done]: "
                     (length selected-files))
             choices nil nil))
      selection (type-of selection) (length selection))
    (if (string-empty-p selection)
        (setq done t)
      (push selection selected-files)
      (setq choices (delete selection choices))))
  (nreverse selected-files)))

(defun gpt-select-project-files ()
  "Prompt user to select files from project to use as context."
  (interactive)
  (let* ((all-files (gpt-get-project-files))
         (relative-files (mapcar (lambda (f)
                                   (file-relative-name f (project-root (project-current))))
                                 all-files)))
    (setq gpt-project-file-context
          (gpt-read-multiple-files relative-files))
    (message "Selected %d files for context" (length gpt-project-file-context))))

(defun gpt-get-file-contents (files)
  "Get contents of FILES as a formatted string."
  (let ((file-contents "")
        (project-root (project-root (project-current))))
    (dolist (file files)
      (condition-case err
          (setq file-contents
                (concat file-contents
                        (format "\nFile: %s\n```\n%s\n```\n"
                                file
                                (with-temp-buffer
                                  (insert-file-contents
                                   (expand-file-name file project-root))
                                  (let ((content (buffer-string)))
                                    content)))))
        (error
         (message "Error reading file %s: %s" file (error-message-string err)))))
    file-contents))

(defun gpt-chat (&optional all-buffers)
  "Run user-provided GPT command on region or all visible buffers and print output stream.
If called with a prefix argument (i.e., ALL-BUFFERS is non-nil), use all visible buffers as input.
Otherwise, use the current region."
  (interactive "P")
  (let* ((initial-buffer (current-buffer))
         (command (gpt-read-command))
         (output-buffer (gpt-create-output-buffer command))
         (input (if all-buffers
                    (gpt-get-visible-buffers-content)
                  (when (use-region-p)
                    (buffer-substring-no-properties (region-beginning) (region-end)))))
         (project-context (when gpt-project-file-context
                            (let ((ctx (format gpt-project-context-format
                                               (mapconcat #'identity gpt-project-file-context "\n")
                                               (gpt-get-file-contents gpt-project-file-context))))
                              ctx))))
    (switch-to-buffer-other-window output-buffer)
    (when project-context
      (insert (format "User:\n\n%s" project-context)))
    (when input
      (insert (format "User:\n\n```\n%s\n```\n\n" input)))
    (gpt-insert-command command)
    (gpt-run-buffer output-buffer)))

(defun gpt-chat-all-buffers ()
  "Run user-provided GPT command on all visible buffers and print output stream."
  (interactive)
  (gpt-chat t))

(defun gpt-chat-follow-up ()
  "Run a follow-up GPT command on the output buffer and append the output stream."
  (interactive)
  (unless (eq major-mode 'gpt-mode)
    (user-error "Not in a gpt output buffer"))
  (let ((command (gpt-read-command)))
    (goto-char (point-max))
    (insert "\n\n")
    (gpt-insert-command command)
    (gpt-run-buffer (current-buffer))))

(defvar gpt-transform-region-instructions
  "You should transform what is inside <region>. Only change what was requested without anything else, e.g., no explanatory comments, no triple backticks. Your response will replace what is inside region as is."
  "The instruction to give gpt so that it performs the transformation as intended.")


(defun gpt-transform-region ()
  "Transform the selected region.
Ask the user for the transformation and then replace the selected region by the response."
  (interactive)
  (let* ((start (region-beginning))
         (end (region-end))
         (region-content (buffer-substring-no-properties start end))
         (buffer-before (buffer-substring-no-properties (point-min) start))
         (buffer-after (buffer-substring-no-properties end (point-max)))
         (command (gpt-read-command))
         (project-context (when gpt-project-file-context
                            (format gpt-project-context-format
                                    (mapconcat #'identity gpt-project-file-context "\n")
                                    (gpt-get-file-contents gpt-project-file-context))))
         (prompt (concat (when project-context (concat "User:\n\n" project-context))
                         "User: " command "\n"
                         "<region>" region-content "<region>" "\n"
                         gpt-transform-region-instructions "\n"
                         "GPTContext: " buffer-before "\n" buffer-after))
         (prompt-file (gpt-create-prompt-file prompt))
         (insertion-marker (make-marker))
         (process (gpt-make-process prompt-file nil)))
    (delete-region start end)
    (set-marker insertion-marker (point))
    (set-process-filter process (lambda (proc string)
                                  (save-excursion
                                    (goto-char insertion-marker)
                                    (insert string)
                                    (set-marker insertion-marker (point)))))))

(defface gpt-completion-preview-face
  '((t :inherit current :underline t :weight bold))
  "Face for previewing code completions.")

(defvar gpt-complete-at-point-instructions "Provide a short completion to be inserted at <cursor>. Only provide the completion, no commentary, no quotes. Your response will directly be inserted."
  "The instructions to give gpt so that it performs completion at point without any noise.")

(defun gpt-complete-at-point ()
  "Get completion from gpt based on buffer content up to point.
The generated completion is displayed directly in buffer and can be accepted with RET."
  (interactive)
  (let* ((start-point (point))
         (overlay (make-overlay start-point start-point))
         (buffer-content (buffer-substring-no-properties (point-min) start-point))
         (buffer-rest (buffer-substring-no-properties start-point (point-max)))
         (project-context (when gpt-project-file-context
                            (format gpt-project-context-format
                                    (mapconcat #'identity gpt-project-file-context "\n")
                                    (gpt-get-file-contents gpt-project-file-context))))
         (prompt (concat (when project-context (concat "User:\n\n" project-context))
                         "User: " buffer-content "<cursor>" buffer-rest "\n\nUser: " gpt-complete-at-point-instructions))
         (prompt-file (gpt-create-prompt-file prompt))
         (insertion-marker (make-marker))
         (process (gpt-make-process prompt-file nil)))
    (overlay-put overlay 'face 'gpt-completion-preview-face)
    (set-marker insertion-marker (point))
    (set-process-filter process (lambda (proc string)
                                  (save-excursion
                                    (goto-char insertion-marker)
                                    (insert string)
                                    ;; Update the overlay to cover the new text
                                    (move-overlay overlay start-point (point))
                                    (set-marker insertion-marker (point)))))
    ;; Wait for user confirmation
    (let ((response (read-key (format "Press RET to accept completion, any other key to cancel"))))
      (if (eq response ?\r)
          (delete-overlay overlay)  ; Remove overlay if accepted
        (delete-region start-point (point))  ; Remove text if canceled
        (delete-overlay overlay)
        (message "Completion canceled")))))

(defvar gpt-generate-buffer-name-instruction "Create a title with a maximum of 50 chars for the chat above. Return a single title, nothing else. No quotes."
  "The instruction given to GPT to generate a buffer name.")

(defun gpt-generate-buffer-name ()
  "Update the buffer name by asking GPT to create a title for it."
  (interactive)
  (unless (eq major-mode 'gpt-mode)
    (user-error "Not in a gpt output buffer"))
  (let* ((gpt-buffer (current-buffer))
         (buffer-string (gpt-buffer-string gpt-buffer))
         (prompt (concat buffer-string "\n\nUser: " gpt-generate-buffer-name-instruction))
         (prompt-file (gpt-create-prompt-file prompt)))
    (with-temp-buffer
      (let ((process (gpt-make-process prompt-file (current-buffer))))
        (message "Asking GPT to generate buffer name...")
        (while (process-live-p process)
          (accept-process-output process))
        (let ((generated-title (string-trim (buffer-string))))
          (with-current-buffer gpt-buffer
            (rename-buffer (gpt-get-output-buffer-name generated-title))))))))

(defun gpt-buffer-string (buffer)
  "Get BUFFER text as string."
  (with-current-buffer buffer
    (buffer-string)))

(defun gpt-create-prompt-file (input)
  "Create a temporary file containing the prompt string from INPUT, which can be a buffer or a string."
  (let ((temp-file (make-temp-file "gpt-prompt"))
        (content (if (bufferp input)
                     (gpt-buffer-string input)
                   input)))
    (with-temp-file temp-file
      (insert content))
    (message "GPT: Prompt written to %s" temp-file)
    temp-file))

(defun gpt-make-process (prompt-file output-buffer)
  "Create a GPT process with PROMPT-FILE, and OUTPUT-BUFFER.
Use `gpt-python-path' and `gpt-script-path' to execute the command with necessary arguments."
  (let* ((api-key (if (eq gpt-api-type 'openai) gpt-openai-key gpt-anthropic-key))
         (api-type-str (symbol-name gpt-api-type))
         (process (make-process
                   :name "gpt-process"
                   :buffer output-buffer
                   :command (list gpt-python-path gpt-script-path prompt-file api-key gpt-model gpt-max-tokens gpt-temperature api-type-str)
                   :connection-type 'pipe))
         (timer (gpt-start-timer process)))
    (gpt-set-process-sentinel process timer prompt-file)
    process))

(defvar gpt-buffer-counter 0
  "Counter to ensure unique buffer names for GPT output buffers.")

(defvar gpt-buffer-name-length 60
  "Maximum character length of the GPT buffer name title.")

(defun gpt-get-output-buffer-name (command)
  "Get the output buffer name for a given COMMAND."
  (let* ((truncated-command (substring command 0 (min gpt-buffer-name-length (length command))))
         (ellipsis (if (< (length truncated-command) (length command)) "..." "")))
    (concat "*gpt"
            "[" (number-to-string gpt-buffer-counter) "]: "
            truncated-command
            ellipsis
            "*")))

(defun gpt-create-output-buffer (command)
  "Create a buffer to capture the output of the GPT process.
If `gpt-use-named-buffers' is non-nil, create or get a named buffer.
Otherwise, create a temporary buffer. Use the `gpt-mode' for the output buffer."
  (let ((output-buffer
         (if gpt-use-named-buffers
             (let ((buffer (get-buffer-create (gpt-get-output-buffer-name command))))
               (setq gpt-buffer-counter (1+ gpt-buffer-counter))  ; Increment the counter
               buffer)
           (generate-new-buffer (gpt-get-output-buffer-name command)))))
    (with-current-buffer output-buffer
      (gpt-mode))
    output-buffer))

(defun gpt-start-timer (process)
  "Set timer to run every second and print message if PROCESS is still running."
  (run-with-timer 1 1
                  (lambda (timer-object)
                    (when (process-live-p timer-object)
                      (font-lock-fontify-buffer)
                      (message "GPT: Running...")))
                  process))

(defun gpt-set-process-sentinel (process timer prompt-file)
  "Set a function to run when the PROCESS finishes or fails.

Cancel the timer, delete the prompt file, and print a message with the status.

PROCESS is the GPT process object.
TIMER is the timer object that cancels the process after a timeout.
PROMPT-FILE is the temporary file containing the prompt."
  (set-process-sentinel process
                        (lambda (proc status)
                          (when (memq (process-status proc) '(exit signal))
                            (cancel-timer timer)
                            (if (zerop (process-exit-status proc))
                                (progn
                                  (delete-file prompt-file)
                                  (message "GPT: Finished successfully."))
                              (message "GPT: Failed: %s" status))))))

(defface gpt-input-face
  '((t :inherit comint-highlight-prompt))
  "Face for the input of the GPT commands.")

(defface gpt-output-face
  '((t :inherit default))
  "Face for the output of the GPT commands.")

(defvar gpt-font-lock-keywords
  '(("^\\(User:\\|Human:\\s-*\\)\\(.*\\)$"
     (1 '(face nil invisible gpt-prefix))
     (2 'gpt-input-face))
    ("^\\(Assistant:\\s-*\\)\\(.*\\)$"
     (1 '(face nil invisible gpt-prefix))
     (2 'gpt-output-face))
    ("```\\([\0-\377[:nonascii:]]*?\\)```"  ; match code snippets enclosed in backticks
     (1 'font-lock-constant-face))))

(defun gpt-dynamically-define-gpt-mode ()
  "Define `gpt-mode` based on whether markdown-mode is available or not."
  (let ((parent-mode (if (fboundp 'markdown-mode)
                         'markdown-mode
                       'text-mode)))
    (eval
     ;; the `define-derived-mode` macro expects a literal as its first argument
     ;; hence, we can not simply use the `parent-mode` variable
     ;; but need to use a backquoted list and eval it
     `(define-derived-mode gpt-mode ,parent-mode "GPT"
        "A mode for displaying the output of GPT commands."
        (message "GPT mode intialized with parent: %s" ',parent-mode)
        (setq-local word-wrap t)
        (setq-local font-lock-extra-managed-props '(invisible))
        (if (eq ',parent-mode 'markdown-mode)
            (progn
              (setq markdown-fontify-code-blocks-natively t)
              ;; Combine markdown-mode's keywords with custom keywords
              (setq font-lock-defaults
                    (list (append markdown-mode-font-lock-keywords gpt-font-lock-keywords))))
          (progn
            (setq-local font-lock-defaults '(gpt-font-lock-keywords))
            (font-lock-mode 1)
            (font-lock-fontify-buffer))
          )
        (add-to-invisibility-spec 'gpt-prefix)))))
(gpt-dynamically-define-gpt-mode)

(defun gpt-toggle-prefix ()
  "Toggle the visibility of the GPT prefixes."
  (interactive)
  (if (and (listp buffer-invisibility-spec)
           (memq 'gpt-prefix buffer-invisibility-spec))
      (remove-from-invisibility-spec 'gpt-prefix)
    (add-to-invisibility-spec 'gpt-prefix))
  (font-lock-fontify-buffer))

(defun gpt-copy-code-block ()
  "Copy the content of the code block at point to the clipboard."
  (interactive)
  (let* ((start (if (search-backward "\n```" nil t) (point) nil))
         (_ (goto-char (or (+ start 3) (point-min))))
         (end (if (search-forward "\n```" nil t) (point) nil)))
    (when (and start end)
      (let* ((content (buffer-substring-no-properties (+ start 3) (- end 3)))
             (lang-end (string-match "\n" content))
             (code (if lang-end
                       (substring content (+ lang-end 1))
                     content)))
        (kill-new code)
        (message "Code block copied to clipboard.")))))

(defun gpt-switch-model ()
  "Switch between OpenAI and Anthropic models."
  (interactive)
  (let* ((models '(("GPT-4o" . (openai . "gpt-4o"))
                   ("Claude 3.5 Sonnet" . (anthropic . "claude-3-5-sonnet-20240620"))))
         (choice (completing-read "Choose model: " (mapcar #'car models) nil t))
         (model-info (cdr (assoc choice models))))
    (setq gpt-api-type (car model-info)
          gpt-model (cdr model-info))
    (message "Switched to %s model: %s" (car model-info) (cdr model-info))))

(define-key gpt-mode-map (kbd "C-c C-c") 'gpt-chat-follow-up)
(define-key gpt-mode-map (kbd "C-c C-p") 'gpt-toggle-prefix)
(define-key gpt-mode-map (kbd "C-c C-b") 'gpt-copy-code-block)
(define-key gpt-mode-map (kbd "C-c C-m") 'gpt-switch-model)
(define-key gpt-mode-map (kbd "C-c C-t") 'gpt-generate-buffer-name)
(define-key gpt-mode-map (kbd "C-c C-f") 'gpt-select-project-files)

(provide 'gpt)

;;; gpt.el ends here
