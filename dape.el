;;; dape.el --- Debug Adapter Protocol for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2023  Free Software Foundation, Inc.

;; Author: Daniel Pettersson
;; Maintainer: Daniel Pettersson <daniel@dpettersson.net>
;; Created: 2023
;; License: GPL-3.0-or-later
;; Version: 0.7.0
;; Homepage: https://github.com/svaante/dape
;; Package-Requires: ((emacs "29.1") (jsonrpc "1.0.24"))

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package is an debug adapter client for Emacs.
;; Use `dape-configs' to set up your debug adapter configurations.

;; To initiate debugging sessions, use the command `dape'.

;; Note:
;; For complete functionality, it's essential to activate `eldoc-mode'
;; in your source buffers and enable `repeat-mode' for ergonomics

;; Package looks is heavily inspired by gdb-mi.el

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'font-lock)
(require 'pulse)
(require 'comint)
(require 'repeat)
(require 'compile)
(require 'tree-widget)
(require 'project)
(require 'gdb-mi)
(require 'hexl)
(require 'tramp)
(require 'jsonrpc)
(require 'eglot) ;; jdtls config


;;; Custom
(defgroup dape nil
  "Debug Adapter Protocol for Emacs."
  :prefix "dape-"
  :group 'applications)

(defcustom dape-adapter-dir
  (file-name-as-directory (concat user-emacs-directory "debug-adapters"))
  "Directory to store downloaded adapters in."
  :type 'string)

(defcustom dape-configs
  `((attach
     modes nil
     ensure (lambda (config)
              (unless (plist-get config 'port)
                (user-error "Missing `port' property")))
     host "localhost"
     :request "attach")
    (launch
     modes nil
     command-cwd dape-command-cwd
     ensure (lambda (config)
              (unless (plist-get config 'command)
                (user-error "Missing `command' property")))
     :request "launch")
    ,@(let ((codelldb
             `(ensure dape-ensure-command
               command-cwd dape-command-cwd
               command ,(file-name-concat dape-adapter-dir
                                          "codelldb"
                                          "extension"
                                          "adapter"
                                          "codelldb")
               port :autoport
               fn dape-config-autoport
               :type "lldb"
               :request "launch"
               :cwd "."))
            (common `(:args [] :stopOnEntry nil)))
        `((codelldb-cc
           modes (c-mode c-ts-mode c++-mode c++-ts-mode)
           command-args ("--port" :autoport)
           ,@codelldb
           :program "a.out"
           ,@common)
          (codelldb-rust
           modes (rust-mode rust-ts-mode)
           command-args ("--port" :autoport
                         "--settings" "{\"sourceLanguages\":[\"rust\"]}")
           ,@codelldb
           :program ,(defun dape--rust-program ()
                       (file-name-concat "target" "debug"
                                         (thread-first (dape-cwd)
                                                       (directory-file-name)
                                                       (file-name-split)
                                                       (last)
                                                       (car))))
           ,@common)))
    (cpptools
     modes (c-mode c-ts-mode c++-mode c++-ts-mode)
     ensure dape-ensure-command
     command-cwd dape-command-cwd
     command ,(file-name-concat dape-adapter-dir
                                "cpptools"
                                "extension"
                                "debugAdapters"
                                "bin"
                                "OpenDebugAD7")
     :type "cppdbg"
     :request "launch"
     :cwd "."
     :program "a.out"
     :MIMode ,(seq-find 'executable-find '("lldb" "gdb")))
    (debugpy
     modes (python-mode python-ts-mode)
     ensure (lambda (config)
              (dape-ensure-command config)
              (let ((python
                     (dape--config-eval-value (plist-get config 'command))))
                (unless (zerop
                         (call-process-shell-command
                          (format "%s -c \"import debugpy.adapter\"" python)))
                  (user-error "%s module debugpy is not installed" python))))
     fn (dape-config-autoport dape-config-tramp)
     command "python"
     command-args ("-m" "debugpy.adapter" "--host" "0.0.0.0" "--port" :autoport)
     port :autoport
     :request "launch"
     :type "executable"
     :cwd dape-cwd
     :program dape-buffer-default
     :args []
     :justMyCode nil
     :console "integratedTerminal"
     :showReturnValue t
     :stopAtEntry t)
    (dlv
     modes (go-mode go-ts-mode)
     ensure dape-ensure-command
     fn (dape-config-autoport dape-config-tramp)
     command "dlv"
     command-args ("dap" "--listen" "127.0.0.1::autoport")
     command-cwd dape-command-cwd
     port :autoport
     :request "launch"
     :type "debug"
     :cwd "."
     :program ".")
    (flutter
     ensure dape-ensure-command
     modes (dart-mode)
     command "flutter"
     command-args ("debug_adapter")
     command-cwd dape-command-cwd
     :type "dart"
     :cwd "."
     :program "lib/main.dart"
     :toolArgs ["-d" "all"])
    (gdb
     modes (c-mode c-ts-mode c++-mode c++-ts-mode)
     command-cwd dape-command-cwd
     command "gdb"
     command-args ("--interpreter=dap")
     fn (dape-config-tramp)
     :request "launch"
     :program "a.out"
     :args []
     :stopAtBeginningOfMainSubprogram nil)
    (godot
     modes (gdscript-mode)
     port 6006
     :request "launch"
     :type "server"
     :cwd dape-cwd)
    ,@(let ((js-debug
             `(modes (js-mode js-ts-mode typescript-mode typescript-ts-mode)
               ensure ,(lambda (config)
                         (dape-ensure-command config)
                         (let ((js-debug-file
                                (file-name-concat
                                 (dape--config-eval-value (car (plist-get config 'command-args))))))
                           (unless (file-exists-p js-debug-file)
                             (user-error "File %S does not exist" js-debug-file))))
               command "node"
               command-args (,(expand-file-name
                               (file-name-concat dape-adapter-dir
                                                 "js-debug"
                                                 "src"
                                                 "dapDebugServer.js"))
                             :autoport)
               port :autoport
               fn dape-config-autoport)))
        `((js-debug-node
           ,@js-debug
           :type "pwa-node"
           :cwd dape-cwd
           :program dape-buffer-default
           :outputCapture "console"
           :sourceMapRenames t
           :pauseForSourceMap nil
           :autoAttachChildProcesses t
           :console "internalConsole"
           :killBehavior "forceful")
          (js-debug-chrome
           ,@js-debug
           :type "pwa-chrome"
           :url "http://localhost:3000"
           :webRoot dape-cwd
           :outputCapture "console")))
    (lldb-vscode
     modes (c-mode c-ts-mode c++-mode c++-ts-mode rust-mode rust-ts-mode)
     ensure dape-ensure-command
     command-cwd dape-command-cwd
     command "lldb-vscode"
     :type "lldb-vscode"
     :cwd "."
     :program "a.out")
    (netcoredbg
     modes (csharp-mode csharp-ts-mode)
     ensure dape-ensure-command
     command "netcoredbg"
     command-args ["--interpreter=vscode"]
     :request "launch"
     :cwd dape-cwd
     :program ,(defun dape--netcoredbg-program ()
                 (let ((dlls
                        (file-expand-wildcards
                         (file-name-concat "bin" "Debug" "*" "*.dll"))))
                   (if dlls
                       (file-relative-name
                        (file-relative-name (car dlls)))
                     ".dll"
                     (dape-cwd))))
     :stopAtEntry nil)
    (rdbg
     modes (ruby-mode ruby-ts-mode)
     ensure dape-ensure-command
     command "rdbg"
     command-args ("-O" "--host" "0.0.0.0" "--port" :autoport "-c" "--" :-c)
     fn ((lambda (config)
           (plist-put config 'command-args
                      (mapcar (lambda (arg)
                                (if (eq arg :-c)
                                    (plist-get config '-c)
                                  arg))
                              (plist-get config 'command-args))))
         dape-config-autoport
         dape-config-tramp)
     port :autoport
     command-cwd dape-command-cwd
     :type "Ruby"
     ;; -- examples:
     ;; rails server
     ;; bundle exec ruby foo.rb
     ;; bundle exec rake test
     -c ,(defun dape--rdbg-c ()
           (format "ruby %s"
                   (or (dape-buffer-default) ""))))
    (jdtls
     modes (java-mode java-ts-mode)
     ensure (lambda (config)
              (let ((file (thread-first (plist-get config :filePath)
                                        (dape--config-eval-value))))
                (unless (and (stringp file) (file-exists-p file))
                  (thread-first (plist-get config :filePath)
                                (dape--config-eval-value))
                  (user-error "Unable to find locate :filePath `%s'" file))
                (with-current-buffer (find-file-noselect file)
                  (unless (eglot-current-server)
                    (user-error "No eglot instance active in buffer %s" (current-buffer)))
                  (unless (seq-contains-p (eglot--server-capable :executeCommandProvider :commands)
        			          "vscode.java.resolveClasspath")
        	    (user-error "jdtls instance does not bundle java-debug-server, please install")))))
     fn (lambda (config)
          (with-current-buffer (thread-first (plist-get config :filePath)
                                             (dape--config-eval-value)
                                             (find-file-noselect))
            (if-let ((server (eglot-current-server)))
	        (pcase-let ((`[,module-paths ,class-paths]
			     (eglot-execute-command server
                                                    "vscode.java.resolveClasspath"
					            (vector (plist-get config :mainClass)
                                                            (plist-get config :projectName))))
                            (port (eglot-execute-command server
		                                         "vscode.java.startDebugSession" nil)))
	          (thread-first config
                                (plist-put 'port port)
			        (plist-put :modulePaths module-paths)
			        (plist-put :classPaths class-paths)))
              server)))
     ,@(cl-flet ((resolve-main-class (key)
                   (ignore-errors
                     (pcase-let ((`[,main-class]
                                  (eglot-execute-command
                                   (eglot-current-server)
				   "vscode.java.resolveMainClass"
				   (file-name-nondirectory (directory-file-name (dape-cwd))))))
                       (plist-get main-class key)))))
         `(:filePath
           ,(defun dape--jdtls-file-path ()
              (or (resolve-main-class :filePath)
                  (expand-file-name (dape-buffer-default) (dape-cwd))))
           :mainClass
           ,(defun dape--jdtls-main-class ()
              (or (resolve-main-class :mainClass) ""))
           :projectName
           ,(defun dape--jdtls-project-name ()
              (or (resolve-main-class :projectName) ""))))
     :args ""
     :stopOnEntry nil
     :type "java"
     :request "launch"
     :vmArgs " -XX:+ShowCodeDetailsInExceptionMessages"
     :console "integratedConsole"
     :internalConsoleOptions "neverOpen"))
   "This variable holds the dape configurations as an alist.
In this alist, the car element serves as a symbol identifying each
configuration.  Each configuration, in turn, is a property list (plist)
where keys can be symbols or keywords.

Symbol Keys (Used by dape):
- fn: Function or list of functions, takes config and returns config.
  If list functions are applied in order.  Used for hiding unnecessary
  configuration details from config history.
- ensure: Function to ensure that adapter is available.
- command: Shell command to initiate the debug adapter.
- command-args: List of string arguments for the command.
- command-cwd: Working directory for the command, if not supplied
  `default-directory' will be used.
- prefix-local: Path prefix for Emacs file access.
- prefix-remote: Path prefix for debugger file access.
- host: Host of the debug adapter.
- port: Port of the debug adapter.
- modes: List of modes where the configuration is active in `dape'
  completions.
- compile: Executes a shell command with `dape-compile-fn'.

Debug adapter conn in configuration:
- If only command is specified (without host and port), Dape
  will communicate with the debug adapter through stdin/stdout.
- If both host and port are specified, Dape will connect to the
  debug adapter.  If `command is specified, Dape will wait until the
  command is initiated before it connects with host and port.

Keywords in configuration:
  Keywords are transmitted to the adapter during the initialize and
  launch/attach requests.  Refer to `json-serialize' for detailed
  information on how Dape serializes these keyword elements.  Dape
  uses nil as false.

Functions and symbols in configuration:
 If a value in a key is a function, the function's return value will
 replace the key's value before execution.
 If a value in a key is a symbol, the symbol will recursively resolve
 at runtime."
   :type '(alist :key-type (symbol :tag "Name")
                 :value-type
                 (plist :options
                        (((const :tag "List of modes where config is active in `dape' completions" modes) (repeat function))
                         ((const :tag "Ensures adapter availability" ensure) function)
                         ((const :tag "Transforms configuration at runtime" fn) (choice function (repeat function)))
                         ((const :tag "Shell command to initiate the debug adapter" command) (choice string symbol))
                         ((const :tag "List of string arguments for command" command-args) (repeat string))
                         ((const :tag "Working directory for command" command-cwd) (choice string symbol))
                         ((const :tag "Path prefix for Emacs file access" prefix-local) string)
                         ((const :tag "Path prefix for debugger file access" prefix-remote) string)
                         ((const :tag "Host of debug adapter" host) string)
                         ((const :tag "Port of debug adapter" port) natnum)
                         ((const :tag "Compile cmd" compile) string)
                         ((const :tag "Adapter type" :type) string)
                         ((const :tag "Request type launch/attach" :request) string)))))

(defcustom dape-command nil
  "Initial contents for `dape' completion.
Sometimes it is useful for files or directories to supply local values
for this variable.

Example value:
\(codelldb-cc :program \"/home/user/project/a.out\")"
  :type 'sexp)

;; TODO Add more defaults, don't know which adapters support
;;      sourceReference
(defcustom dape-mime-mode-alist '(("text/x-lldb.disassembly" . asm-mode)
                                  ("text/javascript" . js-mode))
  "Alist of MIME types vs corresponding major mode functions.
Each element should look like (MIME-TYPE . MODE) where
    MIME-TYPE is a string and MODE is the major mode function to
    use for buffers of this MIME type."
  :type '(alist :key-type string :value-type function))

(defcustom dape-key-prefix "\C-x\C-a"
  "Prefix of all dape commands."
  :type 'key-sequence)

(defcustom dape-display-source-buffer-action
  '(display-buffer-same-window)
  "`display-buffer' action used when displaying source buffer."
  :type 'sexp)

(define-obsolete-variable-alias
  'dape-buffer-window-arrangment
  'dape-buffer-window-arrangement "0.3.0")

(defcustom dape-buffer-window-arrangement 'left
  "Rules for display dape buffers."
  :type '(choice (const :tag "GUD gdb like" gud)
                 (const :tag "Left side" left)
                 (const :tag "Right side" right)))

(defcustom dape-info-buffer-window-groups
  '((dape-info-scope-mode dape-info-watch-mode)
    (dape-info-stack-mode dape-info-modules-mode dape-info-sources-mode)
    (dape-info-breakpoints-mode dape-info-threads-mode))
  "Window display rules for `dape-info-parent-mode' derived modes.
Each list of modes is displayed in the same window.  The first item of
each group is displayed by `dape-info'.  All modes doesn't need to be
present in an group."
  :type '(repeat (repeat function)))

(defcustom dape-stepping-granularity 'line
  "The granularity of one step in the stepping requests."
  :type '(choice (const :tag "Step statement" statement)
                 (const :tag "Step line" line)
                 (const :tag "Step instruction" instruction)))

(defcustom dape-stack-trace-levels 20
  "The number of stack frames fetched."
  :type 'natnum)

(defcustom dape-on-start-hooks '(dape-repl dape-info)
  "Hook to run on session start."
  :type 'hook)

(defcustom dape-on-stopped-hooks '(dape--emacs-grab-focus dape-memory-revert)
  "Hook to run on session stopped."
  :type 'hook)

(defcustom dape-update-ui-hooks '(dape-info-update)
  "Hook to run on ui update."
  :type 'hook)

(define-obsolete-variable-alias
  'dape-read-memory-default-count
  'dape-read-memory-bytes "0.8.0")

(defcustom dape-read-memory-bytes 1024
  "The bytes read with `dape-read-memory'."
  :type 'natnum)

(defcustom dape-info-hide-mode-line
  (and (memql dape-buffer-window-arrangement '(left right)) t)
  "Hide mode line in dape info buffers."
  :type 'boolean)

(defcustom dape-info-variable-table-aligned nil
  "Align columns in variable tables."
  :type 'boolean)

(defcustom dape-info-variable-table-row-config `((name . 20)
                                                 (value . 50)
                                                 (type . 20))
  "Configuration for table rows of variables.

An alist that controls the display of the name, type and value of
variables.  The key controls which column to change whereas the
value determines the maximum number of characters to display in each
column.  A value of 0 means there is no limit.

Additionally, the order the element in the alist determines the
left-to-right display order of the properties."
  :type '(alist :key-type symbol :value-type integer))

(defcustom dape-info-thread-buffer-verbose-names t
  "Show long thread names in threads buffer."
  :type 'boolean)

(defcustom dape-info-thread-buffer-locations t
  "Show file information or library names in threads buffer."
  :type 'boolean)

(defcustom dape-info-thread-buffer-addresses t
  "Show addresses for thread frames in threads buffer."
  :type 'boolean)

(defcustom dape-info-stack-buffer-locations t
  "Show file information or library names in stack buffer."
  :type 'boolean)

(defcustom dape-info-stack-buffer-modules nil
  "Show module information in stack buffer if adapter supports it."
  :type 'boolean)

(defcustom dape-info-stack-buffer-addresses t
  "Show frame addresses in stack buffer."
  :type 'boolean)

(defcustom dape-info-buffer-variable-format 'line
  "How variables are formatted in *dape-info* buffer."
  :type '(choice (const :tag "Truncate string at new line" line)
                 (const :tag "No formatting" nil)))

(defcustom dape-info-header-scope-max-name 15
  "Max length of scope name in `header-line-format'."
  :type 'integer)

(defcustom dape-info-file-name-max 30
  "Max length of file name in dape info buffers."
  :type 'integer)

(defcustom dape-breakpoint-margin-string "B"
  "String to display breakpoint in margin."
  :type 'string)

(defcustom dape-repl-use-shorthand t
  "Dape `dape-repl-commands' can be invokend with first char of command."
  :type 'boolean)

(defcustom dape-repl-commands
  '(("debug" . dape)
    ("next" . dape-next)
    ("continue" . dape-continue)
    ("pause" . dape-pause)
    ("step" . dape-step-in)
    ("out" . dape-step-out)
    ("restart" . dape-restart)
    ("kill" . dape-kill)
    ("disconnect" . dape-disconnect-quit)
    ("quit" . dape-quit))
  "Dape commands available in REPL buffer."
  :type '(alist :key-type string
                :value-type function))

(defcustom dape-compile-fn #'compile
  "Function to run compile with."
  :type 'function)

(defcustom dape-use-savehist nil
  "Use `savehist-mode' to store breakpoints exceptions.
Make sure to set `dape-use-savehist' before loading `dape'."
  :type 'boolean)

(defcustom dape-cwd-fn #'dape--default-cwd
  "Function to get current working directory.
The function should take one optional argument and return a string
representing the absolute file path of the current working directory.
If the optional argument is non nil return path with tramp prefix
otherwise the path should be without prefix.
See `dape--default-cwd'."
  :type 'function)

(defcustom dape-compile-compile-hooks nil
  "Hook run after dape compilation succeded.
The hook is run with one argument, the compilation buffer."
  :type 'hook)

(defcustom dape-minibuffer-hint-ignore-properties
  '(ensure fn modes command command-args :type :request)
  "Properties to be hidden in `dape--minibuffer-hint'."
  :type '(repeat symbol))

(defcustom dape-minibuffer-hint t
  "Show hints in mini buffer."
  :type 'boolean)

(defcustom dape-debug nil
  "Print debug info in *dape-repl* and *dape-connection events*."
  :type 'boolean)

(defcustom dape-request-timeout jsonrpc-default-request-timeout
  "Number of seconds until a request is deemed to be timed out."
  :type 'natnum)


;;; Face
(defface dape-breakpoint-face
  '((t :inherit (font-lock-keyword-face)))
  "Face used to display breakpoint overlays.")

(defface dape-log-face
  '((t :inherit (font-lock-string-face)
       :height 0.85 :box (:line-width -1)))
  "Face used to display log breakpoints.")

(defface dape-expression-face
  '((t :inherit (dape-breakpoint-face)
       :height 0.85 :box (:line-width -1)))
  "Face used to display conditional breakpoints.")

(defface dape-exception-description-face
  '((t :inherit (error tooltip)))
  "Face used to display exception descriptions inline.")

(defface dape-stack-trace-face
  '((t :extend t))
  "Face used to display stack trace overlays.")

(defface dape-repl-success-face
  '((t :inherit compilation-mode-line-exit :extend t))
  "Face used in repl for exit code 0.")

(defface dape-repl-error-face
  '((t :inherit compilation-mode-line-fail :extend t))
  "Face used in repl for non 0 exit codes.")


;;; Vars

(defvar dape-history nil
  "History variable for `dape'.")

(defvar dape--source-buffers nil
  "Plist of sources reference to buffer.")
(defvar dape--breakpoints nil
  "List of session breakpoint overlays.")
(defvar dape--exceptions nil
  "List of available exceptions as plists.")
(defvar dape--watched nil
  "List of watched expressions.")
(defvar dape--connection nil
  "Debug adapter connection.")

(defvar-local dape--source nil
  "Store source plist in fetched source buffer.")

(defvar dape--repl-insert-text-guard nil
  "Guard var for *dape-repl* buffer text updates.")

(define-minor-mode dape-active-mode
  "On when dape debuggin session is active.
Non interactive global minor mode."
  :global t
  :interactive nil)


;;; Utils

(defmacro dape--with-request-bind (vars fn-args &rest body)
  "Call FN with ARGS and execute BODY on callback with VARS bound.
VARS are bound from the args that the callback was invoked with.
FN-ARGS is be an cons pair as FN . ARGS, where FN is exected to
take an function as an argument at ARGS + 1.
BODY is guaranteed to be evaluated with the current buffer.
See `cl-destructuring-bind'."
  (declare (indent 2))
  (let ((old-buffer (make-symbol "old-buffer")))
    `(let ((,old-buffer (current-buffer)))
       (,(car fn-args) ,@(cdr fn-args)
        (cl-function (lambda ,vars
                       (with-current-buffer (if (buffer-live-p ,old-buffer)
                                                ,old-buffer
                                              (current-buffer))
                         ,@body)))))))

(defmacro dape--with-request (fn-args &rest body)
  "Call `dape-request' like FN with ARGS and execute BODY on callback.
FN-ARGS is be an cons pair as FN . ARGS.
BODY is guaranteed to be evaluated with the current buffer.
See `dape--with-request-bind'."
  (declare (indent 1))
  `(dape--with-request-bind (&rest _) ,fn-args ,@body))

(defun dape--request-return (cb &optional error)
  "Shorthand to call CB with ERROR in an `dape-request' like way."
  (when (functionp cb)
    (funcall cb nil error)))

(defun dape--next-like-command (conn command)
  "Helper for interactive step like commands.
Run step like COMMAND on CONN.  If ARG is set run COMMAND ARG times."
  (if (not (dape--stopped-threads conn))
      (user-error "No stopped threads")
    (dape--with-request-bind
        (_body error)
        (dape-request conn
                      command
                      `(,@(dape--thread-id-object conn)
                        ,@(when (dape--capable-p conn :supportsSteppingGranularity)
                            (list :granularity
                                  (symbol-name dape-stepping-granularity)))))
      (unless error
        (dape--update-state conn 'running)
        (dape--remove-stack-pointers)
        (dolist (thread (dape--threads conn))
          (plist-put thread :status "running"))
        (run-hooks 'dape-update-ui-hooks)))))

(defun dape--thread-id-object (conn)
  "Construct a thread id object for CONN."
  (when-let ((thread-id (dape--thread-id conn)))
    (list :threadId thread-id)))

(defun dape--stopped-threads (conn)
  "List of stopped threads for CONN."
  (and conn
       (mapcan (lambda (thread)
                 (when (equal (plist-get thread :status) "stopped")
                   (list thread)))
               (dape--threads conn))))

(defun dape--current-thread (conn)
  "Current thread plist for CONN."
  (and conn
       (seq-find (lambda (thread)
                   (eq (plist-get thread :id) (dape--thread-id conn)))
                 (dape--threads conn))))

(defun dape--path (conn path format)
  "Return translate absolute PATH in FORMAT from CONN config.
Accepted FORMAT values are local and remote.
See `dape-configs' symbols prefix-local prefix-remote."
  (if-let* ((config (dape--config conn))
            (path (expand-file-name
                   path
                   (let ((command-cwd (plist-get config 'command-cwd)))
                     (pcase format
                       ('local (tramp-file-local-name command-cwd))
                       ('remote command-cwd)))))
            ((or (plist-member config 'prefix-local)
                 (plist-member config 'prefix-remote)))
            (prefix-local (or (plist-get config 'prefix-local) ""))
            (prefix-remote (or (plist-get config 'prefix-remote) ""))
            (mapping (pcase format
                       ('local (cons prefix-remote prefix-local))
                       ('remote (cons prefix-local prefix-remote))
                       (_ (error "Unknown format")))))
      (concat
       (cdr mapping)
       (string-remove-prefix (car mapping) path))
    path))

(defun dape--capable-p (conn of)
  "If CONN capable OF."
  (eq (plist-get (dape--capabilities conn) of) t))

(defun dape--current-stack-frame (conn)
  "Current stack frame plist for CONN."
  (let* ((stack-frames (thread-first
                         (dape--current-thread conn)
                         (plist-get :stackFrames)))
         (stack-frames-with-source
          (seq-filter (lambda (stack-frame)
                        (let* ((source (plist-get stack-frame :source))
                               (path (plist-get source :path))
                               (source-reference
                                (or (plist-get source :sourceReference) 0)))
                          (or path (not (zerop source-reference)))))
                      stack-frames)))
    (or (seq-find (lambda (stack-frame)
                    (eq (plist-get stack-frame :id)
                        (dape--stack-id conn)))
                  stack-frames-with-source)
        (car stack-frames-with-source)
        (car stack-frames))))

(defun dape--object-to-marker (conn plist)
  "Return marker created from PLIST and CONN config.
Marker is created from PLIST keys :source and :line.
Note requires `dape--source-ensure' if source is by reference."
  (when-let ((source (plist-get plist :source))
             (line (or (plist-get plist :line) 1))
             (buffer
              (or (when-let* ((source-reference
                               (plist-get source :sourceReference))
                              (buffer (plist-get dape--source-buffers
                                                 source-reference))
                              ((buffer-live-p buffer)))
                    buffer)
                  (when-let* ((path (plist-get source :path))
                              (path (dape--path conn path 'local))
                              ((file-exists-p path))
                              (buffer (find-file-noselect path t)))
                    buffer))))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- line))
        (when-let ((column (plist-get plist :column)))
          (when (> column 0)
            (forward-char (1- column))))
        (point-marker)))))

(defun dape--default-cwd ()
  "Try to guess current project absolute file path with `project'."
  (or (when-let ((project (project-current)))
        (expand-file-name (project-root project)))
      default-directory))

(defun dape-cwd ()
  "Use `dape-cwd-fn' to guess current working as local path."
  (tramp-file-local-name (funcall dape-cwd-fn)))

(defun dape-command-cwd ()
  "Use `dape-cwd-fn' to guess current working directory."
  (funcall dape-cwd-fn))

(defun dape-buffer-default ()
  "Return current buffers file name."
  (tramp-file-local-name
   (file-relative-name (buffer-file-name) (dape-command-cwd))))

(defun dape--guess-root (config)
  "Return best guess root path from CONFIG."
  (if-let* ((command-cwd (plist-get config 'command-cwd))
            ((stringp command-cwd)))
      command-cwd
    (dape-command-cwd)))

(defun dape-config-autoport (config)
  "Replace :autoport in CONFIG keys `command-args' and `port'.
If `port' is `:autoport' replaces with open port, if not replaces
with value of `port' instead.
Replaces symbol and string occurences of \"autoport\"."
  ;; Stolen from `Eglot'
  (let ((port (plist-get config 'port)))
    (when (eq port :autoport)
      (let ((port-probe (make-network-process :name "dape-port-probe-dummy"
                                              :server t
                                              :host "localhost"
                                              :service 0)))
        (setq port
              (unwind-protect
                  (process-contact port-probe :service)
                (delete-process port-probe)))))
    (let ((command-args (seq-map (lambda (item)
                                   (cond
                                    ((eq item :autoport)
                                     (number-to-string port))
                                    ((stringp item)
                                     (string-replace ":autoport"
                                                     (number-to-string port)
                                                     item))))
                                 (plist-get config 'command-args))))
      (thread-first config
                    (plist-put 'port port)
                    (plist-put 'command-args command-args)))))

(defun dape-config-tramp (config)
  "Infer `prefix-local' and `host' on CONFIG if in tramp context."
  ;; TODO maybe this should be moved out of configs and into
  ;;      `dape--config-eval'
  (when-let* ((default-directory
               (or (plist-get config 'command-cwd)
                   default-directory))
              ((tramp-tramp-file-p default-directory))
              (parts (tramp-dissect-file-name default-directory)))
    (when (and (not (plist-get config 'prefix-local))
               (not (plist-get config 'prefix-remote))
               (plist-get config 'command))
      (plist-put config 'prefix-local
                 (tramp-completion-make-tramp-file-name
                  (tramp-file-name-method parts)
                  (tramp-file-name-user parts)
                  (tramp-file-name-host parts)
                  "")))
    (when (and (plist-get config 'command)
               (plist-get config 'port)
               (not (plist-get config 'host))
               (equal (tramp-file-name-method parts) "ssh"))
      (plist-put config 'host (file-remote-p default-directory 'host))))
  config)

(defun dape-ensure-command (config)
  "Ensure that `command' from CONFIG exist system."
  (let ((command
         (dape--config-eval-value (plist-get config 'command))))
    (unless (or (file-executable-p command)
                (executable-find command t))
      (user-error "Unable to locate %S with default-directory %s"
                  command default-directory))))

(defun dape--overlay-region (&optional extended)
  "List of beg and end of current line.
If EXTENDED end of line is after newline."
  (list (line-beginning-position)
        (if extended
            (line-beginning-position 2)
          (1- (line-beginning-position 2)))))

(defun dape--variable-string (plist)
  "Formats dap variable PLIST to string."
  (let ((name (plist-get plist :name))
        (value (or (plist-get plist :value)
                   (plist-get plist :result)))
        (type (plist-get plist :type)))
    (concat
     (propertize name
                 'face 'font-lock-variable-name-face)
     (unless (or (null value)
                 (string-empty-p value))
       (format " = %s"
               (propertize value
                           'face 'font-lock-number-face)))
     (unless (or (null type)
                 (string-empty-p type))
       (format ": %s"
               (propertize type
                           'face 'font-lock-type-face))))))

(defun dape--format-file-line (file line)
  "Formats FILE and LINE to string."
  (let* ((conn dape--connection)
         (config
          (and conn
               ;; If child connection check parent
               (or (and-let* ((parent (dape--parent conn)))
                     (dape--config parent))
                   (dape--config conn))))
         (root-guess (dape--guess-root config))
         ;; Normalize paths for `file-relative-name'
         (file (tramp-file-local-name file))
         (root-guess (tramp-file-local-name root-guess)))
    (concat
     (string-truncate-left (file-relative-name file root-guess)
                           dape-info-file-name-max)
     (when line
       (format ":%d" line)))))

(defun dape--kill-buffers (&optional skip-process-buffers)
  "Kill all Dape related buffers.
On SKIP-PROCESS-BUFFERS skip deletion of buffers which has processes."
  (thread-last (buffer-list)
               (seq-filter (lambda (buffer)
                             (unless (and skip-process-buffers
                                          (get-buffer-process buffer))
                               (string-match-p "\\*dape-.+\\*"
                                               (buffer-name buffer)))))
               (seq-do (lambda (buffer)
                         (condition-case err
                             (let ((window (get-buffer-window buffer)))
                               (kill-buffer buffer)
                               (when (window-live-p window)
                                 (delete-window window)))
                           (error
                            (message (error-message-string err))))))))

(defun dape--display-buffer (buffer)
  "Display BUFFER according to `dape-buffer-window-arrangement'."
  (display-buffer
   buffer
   (let* ((mode (with-current-buffer buffer major-mode))
          (group (cl-position-if (lambda (group) (memq mode group))
                                 dape-info-buffer-window-groups)))
     (pcase dape-buffer-window-arrangement
       ((or 'left 'right)
        (cons '(display-buffer-in-side-window)
              (pcase (cons mode group)
                (`(dape-repl-mode . ,_) '((side . bottom) (slot . -1)))
                (`(shell-mode . ,_) '((side . bottom) (slot . 0)))
                (`(,_ . 0) `((side . ,dape-buffer-window-arrangement) (slot . -1)))
                (`(,_ . 1) `((side . ,dape-buffer-window-arrangement) (slot . 0)))
                (`(,_ . 2) `((side . ,dape-buffer-window-arrangement) (slot . 1)))
                (_ (error "Unable to display buffer of mode `%s'" mode)))))
       ('gud
        (pcase (cons mode group)
          (`(dape-repl-mode . ,_)
           '((display-buffer-in-side-window) (side . top) (slot . -1)))
          (`(shell-mode . ,_)
           '((display-buffer-reuse-window) (display-buffer-pop-up-window)
             (direction . right) (dedicated . t)))
          (`(,_ . 0)
           '((display-buffer-in-side-window) (side . top) (slot . 0)))
          (`(,_ . 1)
           '((display-buffer-in-side-window) (side . bottom) (slot . -1)))
          (`(,_ . 2)
           '((display-buffer-in-side-window) (side . bottom) (slot . 1)))
          (_ (error "Unable to display buffer of mode `%s'" mode))))
       (_ (user-error "Invalid value of `dape-buffer-window-arrangement'"))))))

(defmacro dape--mouse-command (name doc command)
  "Create mouse command with NAME, DOC which runs COMMANDS."
  (declare (indent 1))
  `(defun ,name (event)
     ,doc
     (interactive "e")
     (save-selected-window
       (let ((start (event-start event)))
         (select-window (posn-window start))
         (save-excursion
           (goto-char (posn-point start))
           (call-interactively ',command))))))

(defmacro dape--buffer-map (name fn &rest body)
  "Helper macro to create info buffer map with NAME.
FN is executed on mouse-2 and ?r, BODY is executed inside of let stmt."
  (declare (indent defun))
  `(defvar ,name
     (let ((map (make-sparse-keymap)))
       (suppress-keymap map)
       (define-key map "\r" ',fn)
       (define-key map [mouse-2] ',fn)
       (define-key map [follow-link] 'mouse-face)
       ,@body
       map)))

(defmacro dape--command-at-line (name properties doc &rest body)
  "Helper macro to create info command with NAME and DOC.
Gets PROPERTIES from string properties from current line and binds
them then executes BODY."
  (declare (indent defun))
  `(defun ,name (&optional event)
     ,doc
     (interactive (list last-input-event))
     (if event (posn-set-point (event-end event)))
     (let (,@properties)
       (save-excursion
         (beginning-of-line)
         ,@(mapcar (lambda (property)
                     `(setq ,property (get-text-property (point) ',property)))
                   properties))
       (if (and ,@properties)
           (progn
             ,@body)
         (error "Not recognized as %s line" 'name)))))

(defun dape--emacs-grab-focus ()
  "If `display-graphic-p' focus emacs."
  (select-frame-set-input-focus (selected-frame)))


;;; Connection

(defun dape--live-connection (type &optional nowarn)
  "Get live connection of TYPE.
TYPE is expected to be one of the following symbols:

parent   parent connection.
last     last created child connection or parent which has an active
         thread.
running  last created child connection or parent which has an active
         thread but no stopped threads.
stopped  last created child connection or parent which has stopped
         threads.

If NOWARN does not error on no active process."
  (let (conn)
    (when-let* (dape--connection
                (ordered-connections
                 (append (dape--children dape--connection)
                         (list dape--connection))))
      (setq conn
            (pcase type
              ('parent
               (when (jsonrpc-running-p dape--connection)
                 dape--connection))
              ('last
               (seq-find (lambda (conn)
                           (and (jsonrpc-running-p conn)
                                (dape--thread-id conn)))
                         ordered-connections))
              ('running
               (seq-find (lambda (conn)
                           (and (jsonrpc-running-p conn)
                                (dape--thread-id conn)
                                (not (dape--stopped-threads conn))))
                         ordered-connections))
              ('stopped
               (seq-find (lambda (conn)
                           (and (jsonrpc-running-p conn)
                                (dape--stopped-threads conn)))
                         ordered-connections)))))
    (unless nowarn
      (unless conn
        (user-error "No %s debug connection live" type)))
    conn))

(defun dape--live-connections ()
  "Get all live connections."
  (when (and dape--connection (jsonrpc-running-p dape--connection))
    (cons dape--connection
          (seq-filter 'jsonrpc-running-p
                      (dape--children dape--connection)))))

(defclass dape-connection (jsonrpc-process-connection)
  ((last-id
    :initform 0
    :documentation "Used for converting JSONRPC's `id' to DAP' `seq'.")
   (n-sent-notifs
    :initform 0
    :documentation "Used for converting JSONRPC's `id' to DAP' `seq'.")
   (children
    :accessor dape--children :initarg :children :initform (list)
    :documentation "Child connections.  Used by startDebugging adapters.")
   (parent
    :accessor dape--parent :initarg :parent :initform #'ignore
    :documentation "Parent connection.  Used by startDebugging adapters.")
   (config
    :accessor dape--config :initarg :config :initform #'ignore
    :documentation "Current session configuration plist.")
   (server-process
    :accessor dape--server-process :initarg :server-process :initform #'ignore
    :documentation "Debug adapter server process.")
   (threads
    :accessor dape--threads :initform nil
    :documentation "Session plist of thread data.")
   (capabilities
    :accessor dape--capabilities :initform nil
    :documentation "Session capabilities plist.")
   (thread-id
    :accessor dape--thread-id :initform nil
    :documentation "Selected thread id.")
   (stack-id
    :accessor dape--stack-id :initform nil
    :documentation "Selected stack id.")
   (modules
    :accessor dape--modules :initform nil
    :documentation "List of modules.")
   (sources
    :accessor dape--sources :initform nil
    :documentation "List of loaded sources.")
   (state
    :accessor dape--state :initform nil
    :documentation "Session state.")
   (exception-description
    :accessor dape--exception-description :initform nil
    :documentation "Exception description.")
   (initialized-p
    :accessor dape--initialized-p :initform nil
    :documentation "If connection has been initialized.")
   (restart-in-progress-p
    :accessor dape--restart-in-progress-p :initform nil
    :documentation "If restart request is in flight."))
  :documentation
  "Represents a DAP debugger. Wraps a process for DAP communication.")

(cl-defmethod jsonrpc-convert-to-endpoint ((conn dape-connection)
                                           message subtype)
  "Convert jsonrpc CONN MESSAGE with SUBTYPE to DAP format."
  (cl-destructuring-bind (&key method id error params
                               (result nil result-supplied-p))
      message
    (with-slots (last-id n-sent-notifs) conn
      (cond ((eq subtype 'notification)
             (cl-incf n-sent-notifs)
             `(:type "event"
                     :seq ,(+ last-id n-sent-notifs)
                     :event ,method
                     :body ,params))
            ((eq subtype 'request)
             `(:type "request"
                     :seq ,(+ (setq last-id id) n-sent-notifs)
                     :command ,method
                     ,@(when params `(:arguments ,params))))
            (error
             `(:type "response"
                     :seq ,(+ (setq last-id id) n-sent-notifs)
                     :request_seq ,last-id
                     :success :json-false
                     :message ,(plist-get error :message)
                     :body ,(plist-get error :data)))
            (t
             `(:type "response"
                     :seq ,(+ (setq last-id id) n-sent-notifs)
                     :request_seq ,last-id
                     :command ,method
                     :success t
                     ,@(and result `(:body ,result))))))))

(cl-defmethod jsonrpc-convert-from-endpoint ((_conn dape-connection) dap-message)
  "Convert JSONRPCesque DAP-MESSAGE to JSONRPC plist."
  (cl-destructuring-bind (&key type request_seq seq command arguments
                               event body &allow-other-keys)
      dap-message
    (when (stringp seq) ;; dirty dirty netcoredbg
      (setq seq (string-to-number seq)))
    (cond ((string= type "event")
           `(:method ,event :params ,body))
          ((string= type "response")
           `(:id ,request_seq :result ,dap-message))
          (command
           `(:id ,seq :method ,command :params ,arguments)))))


;;; Outgoing requests

(defconst dape--timeout-error "Request timeout"
  "Error string for request timeout.
Useful for `eq' comparison to derive request timeout error.")

(defun dape-request (conn command arguments &optional cb)
  "Send request with COMMAND and ARGUMENTS to adapter CONN.
If callback function CB is supplied, it's called on timeout
and success.

CB will be called with PLIST and ERROR.
On success, ERROR will be nil.
On failure, ERROR will be an string."
  (jsonrpc-async-request conn command arguments
                         :success-fn
                         (when (functionp cb)
                           (lambda (result)
                             (funcall cb (plist-get result :body)
                                      (unless (eq (plist-get result :success) t)
                                        (or (plist-get result :message) "")))))
                         :error-fn 'ignore ;; will never be called
                         :timeout-fn
                         (when (functionp cb)
                           (lambda ()
                             (dape--repl-message
                              (format
                               "* Command %s timed out after %d seconds, the \
timeout period is configurable with `dape-request-timeout' *"
                               command
                               dape-request-timeout)
                              'dape-repl-error-face)
                             (funcall cb nil dape--timeout-error)))
                         :timeout dape-request-timeout))

(defun dape--initialize (conn)
  "Initialize and launch/attach adapter CONN."
  (dape--with-request-bind
      (body error)
      (dape-request conn
                    "initialize"
                    (list :clientID "dape"
                          :adapterID (plist-get (dape--config conn)
                                                :type)
                          :pathFormat "path"
                          :linesStartAt1 t
                          :columnsStartAt1 t
                          ;;:locale "en-US"
                          ;;:supportsVariableType t
                          ;;:supportsVariablePaging t
                          :supportsRunInTerminalRequest t
                          ;;:supportsMemoryReferences t
                          ;;:supportsInvalidatedEvent t
                          ;;:supportsMemoryEvent t
                          ;;:supportsArgsCanBeInterpretedByShell t
                          :supportsProgressReporting t
                          :supportsStartDebuggingRequest t
                          ;;:supportsVariableType t
                          ))
    (if error
        (progn
          (dape--repl-message (format "Initialize failed due to: %s"
                                      error)
                              'dape-repl-error-face)
          (dape-kill conn))
      (setf (dape--capabilities conn) body)
      (dape--with-request-bind
          (_body error)
          (dape-request conn
                        (or (plist-get (dape--config conn) :request) "launch")
                        (cl-loop for (key value) on (dape--config conn) by 'cddr
                                 when (keywordp key)
                                 append (list key (or value :json-false))))
        (if error
            (progn (dape--repl-message error 'dape-repl-error-face)
                   (dape-kill conn))
          (setf (dape--initialized-p conn) t))))))

(defun dape--set-breakpoints-in-buffer (conn buffer &optional cb)
  "Set breakpoints in BUFFER for adapter CONN.
See `dape-request' for expected CB signature."
  (let* ((overlays
          (alist-get buffer
                     (seq-group-by 'overlay-buffer
                                   dape--breakpoints)))
         (lines
          (mapcan (lambda (overlay)
                    (when-let* ((buffer (overlay-buffer overlay))
                                ((buffer-live-p buffer)))
                      (with-current-buffer buffer
                        (list
                         (line-number-at-pos (overlay-start overlay))))))
                  overlays))
         (source
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (or dape--source
                  (list
                   :name (file-name-nondirectory (buffer-file-name buffer))
                   :path (dape--path conn (buffer-file-name buffer) 'remote)))))))
    (dape--with-request-bind
        ((&key breakpoints &allow-other-keys) error)
        (dape-request conn
                      "setBreakpoints"
                      (list
                       :source source
                       :breakpoints
                       (cl-map 'vector
                               (lambda (overlay line)
                                 (let (plist it)
                                   (setq plist (list :line line))
                                   (cond
                                    ((setq it (overlay-get overlay 'dape-log-message))
                                     (setq plist (plist-put plist :logMessage it)))
                                    ((setq it (overlay-get overlay 'dape-expr-message))
                                     (setq plist (plist-put plist :condition it))))
                                   plist))
                               overlays
                               lines)
                       :lines (apply 'vector lines)))
      (cl-loop for breakpoint across breakpoints
               for overlay in overlays
               do (dape--breakpoint-update conn overlay breakpoint))
      (dape--request-return cb error))))

(defun dape--set-exception-breakpoints (conn &optional cb)
  "Set the exception breakpoints for adapter CONN.
The exceptions are derived from `dape--exceptions'.
See `dape-request' for expected CB signature."
  (if (not dape--exceptions)
      (dape--request-return cb)
    (dape-request conn
                  "setExceptionBreakpoints"
                  (list
                   :filters
                   (cl-map 'vector
                           (lambda (exception)
                             (plist-get exception :filter))
                           (seq-filter (lambda (exception)
                                         (plist-get exception :enabled))
                                       dape--exceptions)))
                  cb)))

(defun dape--configure-exceptions (conn &optional cb)
  "Configure exception breakpoints for adapter CONN.
The exceptions are derived from `dape--exceptions'.
See `dape-request' for expected CB signature."
  (setq dape--exceptions
        (cl-map 'list
                (lambda (exception)
                  (let ((stored-exception
                         (seq-find (lambda (stored-exception)
                                     (equal (plist-get exception :filter)
                                            (plist-get stored-exception :filter)))
                                   dape--exceptions)))
                    (cond
                     (stored-exception
                      (plist-put exception :enabled
                                 (plist-get stored-exception :enabled)))
                     ;; new exception
                     (t
                      (plist-put exception :enabled
                                 (eq (plist-get exception :default) t))))))
                (plist-get (dape--capabilities conn)
                           :exceptionBreakpointFilters)))
  (dape--with-request (dape--set-exception-breakpoints conn)
    (run-hooks 'dape-update-ui-hooks)
    (dape--request-return cb)))

(defun dape--set-breakpoints (conn cb)
  "Set breakpoints for adapter CONN.
See `dape-request' for expected CB signature."
  (if-let ((buffers
            (thread-last dape--breakpoints
                         (seq-group-by 'overlay-buffer)
                         (mapcar 'car))))
      (let ((responses 0))
        (dolist (buffer buffers)
          (dape--with-request (dape--set-breakpoints-in-buffer conn buffer)
            (setf responses (1+ responses))
            (when (eq responses (length buffers))
              (dape--request-return cb)))))
    (dape--request-return cb)))

(defun dape--update-threads (conn stopped-id all-threads-stopped cb)
  "Helper for the stopped event to update `dape--threads'.
Update adapter CONN threads with STOPPED-ID and ALL-THREADS-STOPPED.
See `dape-request' for expected CB signature."
  (dape--with-request-bind
      ((&key threads &allow-other-keys) error)
      (dape-request conn "threads" nil)
    (setf (dape--threads conn)
          (cl-map
           'list
           (lambda (new-thread)
             (let ((thread
                    (or (seq-find
                         (lambda (old-thread)
                           (eq (plist-get new-thread :id)
                               (plist-get old-thread :id)))
                         (dape--threads conn))
                        new-thread)))
               (plist-put thread :name
                          (plist-get new-thread :name))
               (cond
                (all-threads-stopped
                 (plist-put thread :status "stopped"))
                ((eq (plist-get thread :id) stopped-id)
                 (plist-put thread :status "stopped"))
                (t thread))))
           threads))
    (dape--request-return cb error)))

(defun dape--stack-trace (conn thread nof cb)
  "Update stack trace in THREAD plist with NOF frames by adapter CONN.
See `dape-request' for expected CB signature."
  (let ((current-nof (length (plist-get thread :stackFrames)))
        (delayed-stack-trace-p
         (dape--capable-p conn :supportsDelayedStackTraceLoading)))
    (cond
     ((or (not (equal (plist-get thread :status) "stopped"))
          (not (integerp (plist-get thread :id)))
          (and delayed-stack-trace-p (<= nof current-nof))
          (and (not delayed-stack-trace-p) (> current-nof 0)))
      (dape--request-return cb))
     (t
      (dape--with-request-bind
          ((&key stackFrames &allow-other-keys) error)
          (dape-request conn
                        "stackTrace"
                        `(:threadId
                          ,(plist-get thread :id)
                          ,@(when delayed-stack-trace-p
                              (list
                               :startFrame current-nof
                               :levels (- nof current-nof)))
                          ,@(when (and dape-info-stack-buffer-modules
                                       (dape--capable-p conn :supportsValueFormattingOptions))
                              `(:format (:module t)))))
        (cond
         ((not delayed-stack-trace-p)
          (plist-put thread :stackFrames
                     (append stackFrames nil)))
         ;; Sanity check delayed stack trace
         ((length= (plist-get thread :stackFrames) current-nof)
          (plist-put thread :stackFrames
                     (append (plist-get thread :stackFrames)
                             stackFrames
                             nil))))
        (dape--request-return cb error))))))

(defun dape--variables (conn object cb)
  "Update OBJECTs variables by adapter CONN.
See `dape-request' for expected CB signature."
  (let ((variables-reference (plist-get object :variablesReference)))
    (if (or (not (numberp variables-reference))
            (zerop variables-reference)
            (plist-get object :variables)
            (not (jsonrpc-running-p conn)))
        (dape--request-return cb)
      (dape--with-request-bind
          ((&key variables &allow-other-keys) _error)
          (dape-request conn
                        "variables"
                        (list :variablesReference variables-reference))
        (plist-put object
                   :variables
                   (thread-last variables
                                (cl-map 'list 'identity)
                                (seq-filter 'identity)))
        (dape--request-return cb)))))


(defun dape--variables-recursive (conn object path pred cb)
  "Update variables recursivly.
Get variable data from CONN and put result on OBJECT until PRED is nil.
PRED is called with PATH and OBJECT.
See `dape-request' for expected CB signature."
  (let ((objects
         (seq-filter (apply-partially pred path)
                     (or (plist-get object :scopes)
                         (plist-get object :variables)))))
    (if (not objects)
        (dape--request-return cb)
      (let ((responses 0))
        (dolist (object objects)
          (dape--with-request (dape--variables conn object)
            (dape--with-request
                (dape--variables-recursive conn object
                                           (cons (plist-get object :name)
                                                 path)
                                           pred)
              (setf responses (1+ responses))
              (when (length= objects responses)
                (dape--request-return cb)))))))))

(defun dape--evaluate-expression (conn frame-id expression context cb)
  "Send evaluate request to adapter CONN.
FRAME-ID specifies which frame the EXPRESSION is evaluated in and
CONTEXT which the result is going to be displayed in.
See `dape-request' for expected CB signature."
  (dape-request conn "evaluate"
                (append (when (dape--stopped-threads conn)
                          (list :frameId frame-id))
                        (list :expression expression
                              :context context))
                cb))

(defun dape--set-variable (conn variable-reference variable value)
  "Set VARIABLE to VALUE with VARIABLE-REFERENCE in for CONN.
Calls setVariable endpoint if VARIABLE-REFERENCE is an number and
setExpression if it's not.
Runs the appropriate hooks on non error response."
  (cond
   ;; `variable' from an "variable" request
   ((and (dape--capable-p conn :supportsSetVariable)
         (numberp variable-reference))
    (dape--with-request-bind
        (body error)
        (dape-request conn
                      "setVariable"
                      (list
                       :variablesReference variable-reference
                       :name (plist-get variable :name)
                       :value value))
      (if error
          (message "%s" error)
        ;; Would make more sense to update all variables after
        ;; setVariable request but certain adapters cache "variable"
        ;; response so we just update the variable in question in
        ;; place.
        (plist-put variable :variables nil)
        (cl-loop for (key value) on body by 'cddr
                 do (plist-put variable key value))
        (run-hooks 'dape-update-ui-hooks))))
   ;; `variable' from an "evaluate" request
   ((and (dape--capable-p conn :supportsSetExpression)
         (or (plist-get variable :evaluateName)
             (plist-get variable :name)))
    (dape--with-request-bind
        (_body error)
        (dape-request conn
                      "setExpression"
                      (list :frameId (plist-get (dape--current-stack-frame conn) :id)
                            :expression (or (plist-get variable :evaluateName)
                                            (plist-get variable :name))
                            :value value))
      (if error
          (message "%s" error)
        ;; Update all variables
        (dape--update conn nil t t))))
   ((user-error "Unable to set variable"))))

(defun dape--scopes (conn stack-frame cb)
  "Send scopes request to CONN for STACK-FRAME plist.
See `dape-request' for expected CB signature."
  (if-let ((id (plist-get stack-frame :id))
           ((not (plist-get stack-frame :scopes))))
      (dape--with-request-bind
          ((&key scopes &allow-other-keys) error)
          (dape-request conn "scopes" (list :frameId id))
        (plist-put stack-frame :scopes (append scopes nil))
        (dape--request-return cb error))
    (dape--request-return cb)))

(defun dape--update (conn &optional skip-clear-stack-frames
                          skip-stack-pointer-flash skip-display)
  "Update adapter CONN data and ui.
If SKIP-CLEAR-STACK-FRAMES no stack frame data is cleared.  This
is usefully if only to load data for another thread.
If SKIP-STACK-POINTER-FLASH skip flashing after placing stack pointer.
If SKIP-DISPLAY is non nil refrain from displaying selected stack."
  (let ((current-thread (dape--current-thread conn)))
    (unless skip-clear-stack-frames
      (dolist (thread (dape--threads conn))
        (plist-put thread :stackFrames nil)))
    (dape--with-request (dape--stack-trace conn current-thread 1)
      (dape--update-stack-pointers conn skip-stack-pointer-flash skip-display)
      (dape--with-request (dape--scopes conn (dape--current-stack-frame conn))
        (run-hooks 'dape-update-ui-hooks)))))


;;; Incoming requests

(cl-defgeneric dape-handle-request (_conn _command _arguments)
  "Sink for all unsupported requests." nil)

(cl-defmethod dape-handle-request (conn (_command (eql runInTerminal)) arguments)
  "Handle runInTerminal requests.
Starts a new adapter CONNs from ARGUMENTS."
  (let ((default-directory
         (or (when-let ((cwd (plist-get arguments :cwd)))
               (dape--path conn cwd 'local))
             default-directory))
        (process-environment
         (or (cl-loop for (key value) on (plist-get arguments :env) by 'cddr
                      collect
                      (format "%s=%s"
                              (substring (format "%s" key) 1)
                              value))
             process-environment))
        (buffer (get-buffer-create "*dape-shell*")))
    (with-current-buffer buffer
      (shell-mode)
      (shell-command-save-pos-or-erase))
    (let ((process
           (make-process :name "dape shell"
                         :buffer buffer
                         :command (append (plist-get arguments :args) nil)
                         :filter 'comint-output-filter
                         :sentinel 'shell-command-sentinel
                         :file-handler t)))
      (dape--display-buffer buffer)
      (list :processId (process-id process)))))

(cl-defmethod dape-handle-request (conn (_command (eql startDebugging)) arguments)
  "Handle adapter CONNs startDebugging requests with ARGUMENTS.
Starts a new adapter connection as per request of the debug adapter."
  (let ((config (plist-get arguments :configuration))
        (request (plist-get arguments :request)))
    (cl-loop for (key value) on (dape--config conn) by 'cddr
             unless (or (keywordp key)
                        (eq key 'command))
             do (plist-put config key value))
    (when request
      (plist-put config :request request))
    (let ((new-connection
           (dape--create-connection config (or (dape--parent conn)
                                               conn))))
      (push new-connection (dape--children conn))
      (dape--start-debugging new-connection)))
  nil)


;;; Events

(cl-defgeneric dape-handle-event (_conn _event _body)
  "Sink for all unsupported events." nil)

(cl-defmethod dape-handle-event (conn (_event (eql initialized)) _body)
  "Handle adapter CONNs initialized events."
  (dape--update-state conn 'initialized)
  (dape--with-request (dape--configure-exceptions conn)
    (dape--with-request (dape--set-breakpoints conn)
      (dape-request conn "configurationDone" nil))))

(cl-defmethod dape-handle-event (conn (_event (eql capabilities)) body)
  "Handle adapter CONNs capabilities events.
BODY is an plist of adapter capabilities."
  (setf (dape--capabilities conn) (plist-get body :capabilities))
  (dape--configure-exceptions conn))

(cl-defmethod dape-handle-event (conn (_event (eql breakpoint)) body)
  "Handle breakpoint events.
Update `dape--breakpoints' according to BODY."
  (when-let* ((breakpoint (plist-get body :breakpoint))
              (id (plist-get breakpoint :id))
              (overlay (seq-find (lambda (ov)
                                   (equal (overlay-get ov 'dape-id) id))
                                 dape--breakpoints)))
    (dape--breakpoint-update conn overlay breakpoint)))

(cl-defmethod dape-handle-event (conn (_event (eql module)) body)
  "Handle adapter CONNs module events.
Stores `dape--modules' from BODY."
  (let ((reason (plist-get body :reason))
        (id (thread-first body (plist-get :module) (plist-get :id))))
    (pcase reason
      ("new"
       (push (plist-get body :module) (dape--modules conn)))
      ("changed"
       (cl-loop with plist = (cl-find id (dape--modules conn)
                                      :key (lambda (module)
                                             (plist-get module :id)))
                for (key value) on body by 'cddr
                do (plist-put plist key value)))
      ("removed"
       (cl-delete id (dape--modules conn)
                  :key (lambda (module) (plist-get module :id)))))))

(cl-defmethod dape-handle-event (conn (_event (eql loadedSource)) body)
  "Handle adapter CONNs loadedSource events.
Stores `dape--sources' from BODY."
  (let ((reason (plist-get body :reason))
        (id (thread-first body (plist-get :source) (plist-get :id))))
    (pcase reason
      ("new"
       (push (plist-get body :source) (dape--sources conn)))
      ("changed"
       (cl-loop with plist = (cl-find id (dape--sources conn)
                                      :key (lambda (source)
                                             (plist-get source :id)))
                for (key value) on body by 'cddr
                do (plist-put plist key value)))
      ("removed"
       (cl-delete id (dape--sources conn)
                  :key (lambda (source) (plist-get source :id)))))))

(cl-defmethod dape-handle-event (conn (_event (eql process)) body)
  "Handle adapter CONNs process events.
Logs and sets state based on BODY contents."
  (let ((start-method (format "%sed"
                              (or (plist-get body :startMethod)
                                  "start"))))
    (dape--update-state conn (intern start-method))
    (dape--repl-message (format "Process %s %s"
                                start-method
                                (plist-get body :name)))))

(cl-defmethod dape-handle-event (conn (_event (eql thread)) body)
  "Handle adapter CONNs thread events.
Stores `dape--thread-id' and updates/adds thread in
`dape--thread' from BODY."
  (if-let ((thread
            (seq-find (lambda (thread)
                        (eq (plist-get thread :id)
                            (plist-get body :threadId)))
                      (dape--threads conn))))
      (progn
        (plist-put thread :status (plist-get body :reason))
        (plist-put thread :name (or (plist-get thread :name)
                                    "unnamed")))
    ;; If new thread use thread state as global state
    (dape--update-state conn (intern (plist-get body :reason)))
    (push (list :status (plist-get body :reason)
                :id (plist-get body :threadId)
                :name "unnamed")
          (dape--threads conn)))
  ;; Select thread if we don't have any thread selected
  (unless (dape--thread-id conn)
    (setf (dape--thread-id conn) (plist-get body :threadId)))
  (run-hooks 'dape-update-ui-hooks))

(cl-defmethod dape-handle-event (conn (_event (eql stopped)) body)
  "Handle adapter CONNs stopped events.
Sets `dape--thread-id' from BODY and invokes ui refresh with
`dape--update'."
  (dape--update-state conn 'stopped)
  (setf (dape--thread-id conn) (plist-get body :threadId))
  (setf (dape--stack-id conn) nil)
  (dape--with-request
      (dape--update-threads conn
                            (plist-get body :threadId)
                            (plist-get body :allThreadsStopped))
    (dape--update conn))
  (if-let (((equal "exception" (plist-get body :reason)))
           (texts
            (seq-filter 'stringp
                        (list (plist-get body :text)
                              (plist-get body :description)))))
      (let ((str (mapconcat 'identity texts ":\n\t")))
        (setf (dape--exception-description conn) str)
        (dape--repl-message str 'dape-repl-error-face))
    (setf (dape--exception-description conn) nil))
  (run-hooks 'dape-on-stopped-hooks))

(cl-defmethod dape-handle-event (conn (_event (eql continued)) body)
  "Handle adapter CONN continued events.
Sets `dape--thread-id' from BODY if not set."
  (dape--update-state conn 'running)
  (dape--remove-stack-pointers)
  (unless (dape--thread-id conn)
    (setf (dape--thread-id conn) (plist-get body :threadId))))

(cl-defmethod dape-handle-event (_conn (_event (eql output)) body)
  "Handle output events by printing BODY with `dape--repl-message'."
  (pcase (plist-get body :category)
    ("stdout"
     (dape--repl-message (plist-get body :output)))
    ("stderr"
     (dape--repl-message (plist-get body :output) 'dape-repl-error-face))
    ((or "console" "output")
     (dape--repl-message (plist-get body :output)))))

(cl-defmethod dape-handle-event (conn (_event (eql exited)) body)
  "Handle adapter CONNs exited events.
Prints exit code from BODY."
  (dape--update-state conn 'exited)
  (dape--remove-stack-pointers)
  (dape--repl-message (format "* Exit code: %d *"
                              (plist-get body :exitCode))
                      (if (zerop (plist-get body :exitCode))
                          'dape-repl-success-face
                        'dape-repl-error-face)))

(cl-defmethod dape-handle-event (conn (_event (eql terminated)) _body)
  "Handle adapter CONNs terminated events.
Killing the adapter and it's CONN."
  (let ((child-conn-p (dape--parent conn)))
    (dape--with-request (dape-kill conn)
      (when (not child-conn-p)
        ;; HACK remove dubble terminated print for dlv
        (unless (eq (dape--state conn) 'terminated)
          (dape--repl-message "* Session terminated *"))
        (dape--update-state conn 'terminated)))))


;;; Startup/Setup

(defun dape--start-debugging (conn)
  "Preform some cleanup and start debugging with CONN."
  (unless (dape--parent conn)
    (dape--remove-stack-pointers)
    (cl-loop for (_ buffer) on dape--source-buffers by 'cddr
             when (buffer-live-p buffer)
             do (kill-buffer buffer))
    (setq dape--source-buffers nil
          dape--repl-insert-text-guard nil)
    (unless dape-active-mode
      (dape-active-mode +1))
    (dape--update-state conn 'starting)
    (run-hooks 'dape-update-ui-hooks))
  (dape--initialize conn))

(defun dape--create-connection (config &optional parent)
  "Create symbol `dape-connection' instance from CONFIG.
If started by an startDebugging request expects PARENT to
symbol `dape-connection'."
  (run-hooks 'dape-on-start-hooks)
  (dape--repl-message "\n")
  (unless (plist-get config 'command-cwd)
    (plist-put config 'command-cwd default-directory))
  (let ((default-directory (plist-get config 'command-cwd))
        (retries 30)
        process server-process)
    (cond
     ;; socket conn
     ((plist-get config 'port)
      ;; start server
      (when (plist-get config 'command)
        (let ((stderr-buffer
               (get-buffer-create "*dape-server stderr*"))
              (command
               (cons (plist-get config 'command)
                     (cl-map 'list 'identity
                             (plist-get config 'command-args)))))
          (setq server-process
                (make-process :name "dape adapter"
                              :command command
                              :filter (lambda (_process string)
                                        (dape--repl-message string))
                              :noquery t
                              :file-handler t
                              :stderr stderr-buffer))
          (process-put server-process 'stderr-buffer stderr-buffer)
          (when dape-debug
            (dape--repl-message (format "* Adapter server started with %S *"
                                        (mapconcat 'identity
                                                   command " ")))))
        ;; FIXME Why do I need this?
        (when (file-remote-p default-directory)
          (sleep-for 0 300)))
      ;; connect to server
      (let ((host (or (plist-get config 'host) "localhost")))
        (while (and (not process)
                    (> retries 0))
          (ignore-errors
            (setq process
                  (make-network-process :name
                                        (format "dape adapter%s connection"
                                                (if parent " child" ""))
                                        :host host
                                        :coding 'utf-8-emacs-unix
                                        :service (plist-get config 'port)
                                        :noquery t)))
          (sleep-for 0 100)
          (setq retries (1- retries)))
        (if (zerop retries)
            (progn
              (dape--repl-message (format "Unable to connect to server %s:%d"
                                          host (plist-get config 'port))
                                  'dape-repl-error-face)
              ;; barf server std-err
              (when-let ((buffer
                          (and server-process
                               (process-get server-process 'stderr-buffer))))
                (with-current-buffer buffer
                  (dape--repl-message (buffer-string) 'dape-repl-error-face)))
              (delete-process server-process)
              (user-error "Unable to connect to server"))
          (when dape-debug
            (dape--repl-message
             (format "* %s to adapter established at %s:%s *"
                     (if parent "Child connection" "Connection")
                     host (plist-get config 'port)))))))
     ;; stdio conn
     (t
      (let ((command
             (cons (plist-get config 'command)
                   (cl-map 'list 'identity
                           (plist-get config 'command-args)))))
        (setq process
              (make-process :name "dape adapter"
                            :command command
                            :connection-type 'pipe
                            :coding 'utf-8-emacs-unix
                            :noquery t
                            :file-handler t))
        (when dape-debug
          (dape--repl-message (format "* Adapter started with %S *"
                                      (mapconcat 'identity command " ")))))))
    (make-instance 'dape-connection
                   :name "dape-connection"
                   :config config
                   :parent parent
                   :server-process server-process
                   :events-buffer-config `(:size ,(if dape-debug nil 0)
                                                 :format full)
                   :on-shutdown
                   (lambda (conn)
                     ;; error prints
                     (unless (dape--initialized-p conn)
                       (dape--repl-message (concat "Adapter "
                                                   (when (dape--parent conn)
                                                     "child ")
                                                   "connection shutdown without successfully initializing")
                                           'dape-repl-error-face)
                       ;; barf config
                       (dape--repl-message
                        (format "Configuration:\n%s"
                                (cl-loop for (key value) on (dape--config conn) by 'cddr
                                         concat (format "  %s %S\n" key value)))
                        'dape-repl-error-face)
                       ;; barf connection stderr
                       (when-let* ((proc (jsonrpc--process conn))
                                   (buffer (process-get proc 'jsonrpc-stderr)))
                         (with-current-buffer buffer
                           (dape--repl-message (buffer-string) 'dape-repl-error-face)))
                       ;; barf server stderr
                       (when-let* ((server-proc (dape--server-process conn))
                                   (buffer (process-get server-proc 'stderr-buffer)))
                         (with-current-buffer buffer
                           (dape--repl-message (buffer-string) 'dape-repl-error-face))))
                     ;; cleanup server process
                     (unless (dape--parent conn)
                       (dape--remove-stack-pointers)
                       (when-let ((server-process
                                   (dape--server-process conn)))
                         (delete-process server-process)
                         (while (process-live-p server-process)
                           (accept-process-output nil nil 0.1))))
                     ;; ui
                     (run-with-timer 1 nil (lambda ()
                                             (when (eq dape--connection conn)
                                               (dape-active-mode -1)
                                               (force-mode-line-update t)))))
                   :request-dispatcher 'dape-handle-request
                   :notification-dispatcher 'dape-handle-event
                   :process process)))


;;; Commands

(defun dape-next (conn)
  "Step one line (skip functions)
CONN is inferred for interactive invocations."
  (interactive (list (dape--live-connection 'stopped)))
  (dape--next-like-command conn "next"))

(defun dape-step-in (conn)
  "Step into function/method.  If not possible behaves like `dape-next'.
CONN is inferred for interactive invocations."
  (interactive (list (dape--live-connection 'stopped)))
  (dape--next-like-command conn "stepIn"))

(defun dape-step-out (conn)
  "Step out of function/method.  If not possible behaves like `dape-next'.
CONN is inferred for interactive invocations."
  (interactive (list (dape--live-connection 'stopped)))
  (dape--next-like-command conn "stepOut"))

(defun dape-continue (conn)
  "Resumes execution.
CONN is inferred for interactive invocations."
  (interactive (list (dape--live-connection 'stopped)))
  (unless (dape--stopped-threads conn)
    (user-error "No stopped threads"))
  (dape--with-request-bind
      (_body error)
      (dape-request conn
                    "continue"
                    (dape--thread-id-object conn))
    (unless error
      (dape--update-state conn 'running)
      (dape--remove-stack-pointers)
      (dolist (thread (dape--threads conn))
        (plist-put thread :status "running"))
      (run-hooks 'dape-update-ui-hooks))))

(defun dape-pause (conn)
  "Pause execution.
CONN is inferred for interactive invocations."
  (interactive (list (dape--live-connection 'running)))
  (when (dape--stopped-threads conn)
    ;; cpptools crashes on pausing an paused thread
    (user-error "Thread already is stopped"))
  (dape-request conn "pause" (dape--thread-id-object conn)))

(defun dape-restart (&optional conn)
  "Restart debugging session.
CONN is inferred for interactive invocations."
  (interactive (list (dape--live-connection 'last t)))
  (dape--remove-stack-pointers)
  (cond
   ((and conn
         (dape--capable-p conn :supportsRestartRequest))
    (setf (dape--threads conn) nil)
    (setf (dape--thread-id conn) nil)
    (setf (dape--modules conn) nil)
    (setf (dape--sources conn) nil)
    (setf (dape--restart-in-progress-p conn) t)
    (dape--with-request (dape-request conn "restart" nil)
      (setf (dape--restart-in-progress-p conn) nil)))
   (dape-history
    (dape (apply 'dape--config-eval (dape--config-from-string (car dape-history)))))
   ((user-error "Unable to derive session to restart, run `dape'"))))

(defun dape-kill (conn &optional cb with-disconnect)
  "Kill debug session.
CB will be called after adapter termination.  With WITH-DISCONNECT use
disconnect instead of terminate used internally as a fallback to
terminate.  CONN is inferred for interactive invocations."
  (interactive (list (dape--live-connection 'parent)))
  (cond
   ((and conn (jsonrpc-running-p conn)
         (not with-disconnect)
         (dape--capable-p conn :supportsTerminateRequest))
    (dape--with-request-bind (_body error)
        (dape-request conn "terminate" nil)
      ;; We have to give up trying to kill the debuggee in an correct
      ;; way if the request timeout, otherwise we might force the
      ;; user to kill the process in some other way.
      (if (and error (not (eq error dape--timeout-error)))
          (dape-kill cb 'with-disconnect)
        (jsonrpc-shutdown conn)
        (dape--request-return cb))))
   ((and conn (jsonrpc-running-p conn))
    (dape--with-request
        (dape-request conn "disconnect"
                      `(:restart
                        :json-false
                        ,@(when (dape--capable-p conn :supportTerminateDebuggee)
                            (list :terminateDebuggee t))))
      (jsonrpc-shutdown conn)
      (dape--request-return cb)))
   (t
    (dape--request-return cb))))

(defun dape-disconnect-quit (conn)
  "Kill adapter but try to keep debuggee live.
This will leave a decoupled debugged process with no debugge
connection.  CONN is inferred for interactive invocations."
  (interactive (list (dape--live-connection 'parent)))
  (dape--kill-buffers 'skip-process-buffers)
  (dape--with-request
      (dape-request conn "disconnect"
                    (list :terminateDebuggee nil))
    (jsonrpc-shutdown conn)
    (dape--kill-buffers)))

(defun dape-quit (&optional conn)
  "Kill debug session and kill related dape buffers.
CONN is inferred for interactive invocations."
  (interactive (list (dape--live-connection 'parent t)))
  (dape--kill-buffers 'skip-process-buffers)
  (if (not conn)
      (dape--kill-buffers)
    (dape--with-request (dape-kill conn)
      (dape--kill-buffers))))

(defun dape-breakpoint-toggle ()
  "Add or remove breakpoint at current line."
  (interactive)
  (cond
   ((not (seq-filter (lambda (ov)
                       (overlay-get ov 'dape-breakpoint))
                     (dape--breakpoints-at-point)))
    (dape--breakpoint-place))
   (t
    (dape-breakpoint-remove-at-point))))

(defun dape-breakpoint-log (log-message)
  "Add log breakpoint at line.
Argument LOG-MESSAGE contains string to print to *dape-repl*.
Expressions within `{}` are interpolated."
  (interactive
   (list
    (read-string "Log (Expressions within `{}` are interpolated): "
                 (when-let ((prev-log-breakpoint
                             (seq-find (lambda (ov)
                                         (overlay-get ov 'dape-log-message))
                                       (dape--breakpoints-at-point))))
                   (overlay-get prev-log-breakpoint 'dape-log-message)))))
  (cond
   ((string-empty-p log-message)
    (dape-breakpoint-remove-at-point))
   (t
    (dape--breakpoint-place log-message))))

(defun dape-breakpoint-expression (expr-message)
  "Add expression breakpoint at current line.
When EXPR-MESSAGE is evaluated as true threads will pause at current line."
  (interactive
   (list
    (read-string "Condition: "
                 (when-let ((prev-expr-breakpoint
                             (seq-find (lambda (ov)
                                         (overlay-get ov 'dape-expr-message))
                                       (dape--breakpoints-at-point))))
                   (overlay-get prev-expr-breakpoint 'dape-expr-message)))))
  (cond
   ((string-empty-p expr-message)
    (dape-breakpoint-remove-at-point))
   (t
    (dape--breakpoint-place nil expr-message))))

(defun dape-breakpoint-remove-at-point (&optional skip-update)
  "Remove breakpoint, log breakpoint and expression at current line.
When SKIP-UPDATE is non nil, does not notify adapter about removal."
  (interactive)
  (dolist (breakpoint (dape--breakpoints-at-point))
    (dape--breakpoint-remove breakpoint skip-update)))

(defun dape-breakpoint-remove-all ()
  "Remove all breakpoints."
  (interactive)
  (let ((buffers-breakpoints
         (seq-group-by 'overlay-buffer dape--breakpoints)))
    (pcase-dolist (`(,buffer . ,breakpoints) buffers-breakpoints)
      (dolist (breakpoint breakpoints)
        (dape--breakpoint-remove breakpoint t))
      (dolist (conn (dape--live-connections))
        (dape--set-breakpoints-in-buffer conn buffer))))
  (when-let ((conn (dape--live-connection 'stopped t)))
    (dape--update-stack-pointers conn t t)))

(defun dape-select-thread (conn thread-id)
  "Select currrent thread for adapter CONN by THREAD-ID."
  (interactive
   (let* ((conn (dape--live-connection 'stopped))
          (collection
           (mapcar (lambda (thread) (cons (plist-get thread :name)
                                          (plist-get thread :id)))
                   (dape--threads conn)))
          (thread-name
           (completing-read
            (format "Select thread (current %s): "
                    (thread-first conn
                                  (dape--current-stack-frame)
                                  (plist-get :name)))
            collection
            nil t)))
     (list conn (alist-get thread-name collection nil nil 'equal))))
  (setf (dape--thread-id conn) thread-id)
  (dape--update conn t))

(defun dape-select-stack (conn stack-id)
  "Selected current stack for adapter CONN by STACK-ID."
  (interactive
   (let* ((conn (dape--live-connection 'stopped))
          (collection
           (mapcar (lambda (stack) (cons (plist-get stack :name)
                                         (plist-get stack :id)))
                   (thread-first conn
                                 (dape--current-thread)
                                 (plist-get :stackFrames))))
          (stack-name
           (completing-read (format "Select stack (current %s): "
                                    (thread-first conn
                                                  (dape--current-stack-frame)
                                                  (plist-get :name)))
                            collection
                            nil t)))
     (list conn (alist-get stack-name collection nil nil 'equal))))
  (setf (dape--stack-id conn) stack-id)
  (dape--update conn t))

(defun dape-stack-select-up (conn n)
  "Select N stacks above current selected stack for adapter CONN."
  (interactive (list (dape--live-connection 'stopped) 1))
  (if (dape--stopped-threads conn)
      (let* ((current-stack (dape--current-stack-frame conn))
             (stacks (plist-get (dape--current-thread conn) :stackFrames))
             (i (cl-loop for i upfrom 0
                         for stack in stacks
                         when (equal stack current-stack)
                         return (+ i n))))
        (if (not (and (<= 0 i) (< i (length stacks))))
            (message "Index %s out of range" i)
          (dape-select-stack conn (plist-get (nth i stacks) :id))))
    (message "No stopped threads")))

(defun dape-stack-select-down (conn n)
  "Select N stacks below current selected stack for adapter CONN."
  (interactive (list (dape--live-connection 'stopped) 1))
  (dape-stack-select-up conn (* n -1)))

(defun dape-watch-dwim (expression &optional skip-add skip-remove)
  "Add or remove watch for EXPRESSION.
Watched symbols are displayed in *`dape-info' Watch* buffer.
*`dape-info' Watch* buffer is displayed by executing the `dape-info'
command.
Optional argument SKIP-ADD limits usage to only removal of watched vars.
Optional argument SKIP-REMOVE limits usage to only adding watched vars."
  (interactive
   (list (string-trim
          (completing-read "Watch or unwatch symbol: "
                           (mapcar (lambda (plist) (plist-get plist :name))
                                   dape--watched)
                           nil
                           nil
                           (or (and (region-active-p)
                                    (buffer-substring (region-beginning)
                                                      (region-end)))
                               (thing-at-point 'symbol))))))
  (if-let ((plist
            (cl-find-if (lambda (plist)
                          (equal (plist-get plist :name)
                                 expression))
                        dape--watched)))
      (unless skip-remove
        (setq dape--watched
              (cl-remove plist dape--watched)))
    (unless skip-add
      (push (list :name expression)
            dape--watched)
      ;; FIXME don't want to have a depency on info ui in core commands
      (dape--display-buffer (dape--info-get-buffer-create 'dape-info-watch-mode))))
  (run-hooks 'dape-update-ui-hooks))

(defun dape-evaluate-expression (conn expression)
  "Evaluate EXPRESSION, if region is active evaluate region.
EXPRESSION can be an expression or adapter command, as it's evaluated in
repl context.  CONN is inferred for interactive invocations."
  (interactive
   (list
    (or (dape--live-connection 'stopped t)
        (dape--live-connection 'last))
    (if (region-active-p)
        (buffer-substring (region-beginning)
                          (region-end))
      (read-string "Evaluate: "
                   (thing-at-point 'symbol)))))
  (let ((interactive-p (called-interactively-p 'any)))
    (dape--with-request-bind
        ((&key result &allow-other-keys) _error)
        (dape--evaluate-expression conn
                                   (plist-get (dape--current-stack-frame conn) :id)
                                   (substring-no-properties expression)
                                   "repl")
      (when interactive-p
        ;; TODO Print error
        (message "%s" (or (and (stringp result)
                               (not (string-empty-p result))
                               result)
                          "Evaluation done"))))))

;;;###autoload
(defun dape (config &optional skip-compile)
  "Start debugging session.
Start a debugging session for CONFIG.
See `dape-configs' for more information on CONFIG.

When called as an interactive command, the first symbol like
is read as key in the `dape-configs' alist and rest as elements
which override value plist in `dape-configs'.

Interactive example:
  launch :program \"bin\"

Executes alist key `launch' in `dape-configs' with :program as \"bin\".

Use SKIP-COMPILE to skip compilation."
  (interactive (list (dape--read-config)))
  (dape--with-request (dape-kill (dape--live-connection 'parent t))
    (dape--config-ensure config t)
    (when-let ((fn (plist-get config 'fn))
               (fns (or (and (functionp fn) (list fn))
                        (and (listp fn) fn))))
      (setq config
            (seq-reduce (lambda (config fn) (funcall fn config))
                        fns (copy-tree config))))
    (if (and (not skip-compile) (plist-get config 'compile))
        (dape--compile config)
      (setq dape--connection
            (dape--create-connection config))
      (dape--start-debugging dape--connection))))


;;; Compile

(defvar dape--compile-config nil)

(defun dape--compile-compilation-finish (buffer str)
  "Hook for `dape--compile-compilation-finish'.
Using BUFFER and STR."
  (remove-hook 'compilation-finish-functions
               #'dape--compile-compilation-finish)
  (cond
   ((equal "finished\n" str)
    (run-hook-with-args 'dape-compile-compile-hooks buffer)
    (dape dape--compile-config 'skip-compile))
   (t
    (dape--repl-message (format "* Compilation failed %s *"
                                (string-trim-right str))))))

(defun dape--compile (config)
  "Start compilation for CONFIG."
  (let ((default-directory (dape--guess-root config))
        (command (plist-get config 'compile)))
    (setq dape--compile-config config)
    ;; FIXME: Kill current compilation before adding hook otherwise we
    ;;        we might call `dape' on old compilation.
    (add-hook 'compilation-finish-functions
              #'dape--compile-compilation-finish)
    (funcall dape-compile-fn command)))


;;; Memory viewer

(defvar-local dape--memory-offset nil
  "Buffer local var to keep track of current offset/address.")

(defun dape--memory-print-current-point-info (&rest _ignored)
  "Print address at point."
  (let ((addr (+ (hexl-current-address) (dape--memory-offset-number))))
    (format "Current address is %d/0x%08x" addr addr)))

(defun dape--memory-offset-number ()
  "Return `dape--memory-offset' as an number."
  (thread-first dape--memory-offset (substring 2) (string-to-number 16)))

(defun dape--memory-revert (&optional _ignore-auto _noconfirm _preserve-modes)
  "Revert buffer function for `dape-memory-mode'."
  (let* ((conn (dape--live-connection 'last))
         (write-capable-p (dape--capable-p conn :supportsWriteMemoryRequest)))
    (unless (dape--capable-p conn :supportsReadMemoryRequest)
      (user-error "Adapter not capable of reading memory."))
    (unless dape--memory-offset
      (user-error "`dape--memory-offset' not set."))
    (cl-labels ((button-fn (fn) (lambda (_) (call-interactively fn))))
      (setq header-line-format
            (mapconcat
             'identity
             `("Offset:"
               ,(buttonize dape--memory-offset
                           (button-fn #'dape-memory-set-offset))
               "Bytes:"
               ,(buttonize (format "%s" dape-read-memory-bytes)
                           (lambda (_)
                             (setopt dape-read-memory-bytes
                                     (read-number "Set bytes: " dape-read-memory-bytes))
                             (revert-buffer)))
               ,(buttonize "Backward" (button-fn #'dape-memory-backward))
               ,(buttonize "Forward" (button-fn #'dape-memory-forward))
               ,@(when write-capable-p
                   (list (substitute-command-keys
                          "write memory `\\[save-buffer]'"))))
             " ")))
    (dape--with-request-bind
        ((&key address data &allow-other-keys) error)
        (dape-request conn "readMemory"
                      (list :memoryReference dape--memory-offset
                            :count dape-read-memory-bytes))
      (cond
       (error (message "Failed to read memory: %s" error))
       ((not data) (message "No bytes returned from adapter"))
       (t
        (let ((inhibit-read-only t))
          (setq dape--memory-offset address
                buffer-undo-list nil)
          (save-excursion
            (erase-buffer)
            (insert (base64-decode-string data))
            (let (buffer-undo-list)
              (hexlify-buffer))
            ;; Now we need to translate the address fields after the
            ;; fact ugghh
            (goto-char (point-min))
            (let ((offset (dape--memory-offset-number)))
              (while (re-search-forward "^[0-9a-f]+" nil t)
                (let ((address
                       (format "%08x" (+ offset
                                         (string-to-number (match-string 0) 16)))))
                  (delete-region (match-beginning 0) (match-end 0))
                  ;; `hexl' does not support address over 8 hex chars
                  (insert (append (substring address (- (length address) 8)))))))))
        (set-buffer-modified-p nil)
        (when write-capable-p
	  (add-hook 'write-contents-functions #'dape--memory-write))
        (rename-buffer (format "*dape-memory @ %s*" address) t))))))

(defun dape--memory-write ()
  "Write buffer contents to stopped connection."
  (let ((conn (dape--live-connection 'last))
        (buffer (current-buffer))
        (start (point-min))
        (end (point-max))
        (offset dape--memory-offset))
    (with-temp-buffer
      (insert-buffer-substring buffer start end)
      (dehexlify-buffer)
      (dape--with-request-bind
          (_body error)
          (dape-request conn "writeMemory"
                        (list :memoryReference offset
                              :data (base64-encode-string (buffer-string) t)))
        (if error
            (message "Failed to write memory: %s" error)
          (with-current-buffer buffer
            (set-buffer-modified-p nil))
          (message "Memory written successfully at %s" offset)
          (dape--update conn nil t t)))))
  ;; Return `t' to signal buffer written
  t)

(define-derived-mode dape-memory-mode hexl-mode "Memory"
  "Mode for reading and writing memory."
  :interactive nil
  ;; TODO Replace or improve hexl.
  ;;      hexl is not really fitted for our use case as it does
  ;;      support offsets in any way.  The buffer is created with the
  ;;      hexl binary as is.  Filling the buffer with junk before
  ;;      `hexlify-buffer' is not an option as it might be extremely
  ;;      large.
  (add-hook 'eldoc-documentation-functions
            #'dape--memory-print-current-point-info nil t)
  ;; FIXME Is `revert-buffer-in-progress-p' is not respected
  ;;       as most of the work is done in an callback.
  (setq revert-buffer-function #'dape--memory-revert))

(define-key dape-memory-mode-map [remap hexl-goto-address] #'dape-memory-set-offset)
(define-key dape-memory-mode-map [remap hexl-goto-hex-address] #'dape-memory-set-offset)

(defun dape-memory-set-offset (offset)
  "Set memory OFFSET."
  (interactive (list (read-string "Set offset: " dape--memory-offset)))
  (setq dape--memory-offset offset)
  (revert-buffer))

(defun dape-memory-forward (&optional backward)
  "Move offset half `dape-read-memory-bytes' forward.
When BACKWARD is non nil move backward instead."
  (interactive nil dape-memory-mode)
  (let ((op (if backward '- '+)))
    (dape-memory-set-offset
     (format "0x%08x"
             (funcall op (dape--memory-offset-number)
                      (thread-first dape-read-memory-bytes (/ 2) (floor)))))))

(defun dape-memory-backward ()
  "Move offset half `dape-read-memory-bytes' backward."
  (interactive nil dape-memory-mode)
  (dape-memory-forward 'backward))

(defun dape-memory-revert ()
  "Revert all `dape-memory-mode' buffers."
  (cl-loop for buffer in (buffer-list)
           when (eq (with-current-buffer buffer major-mode)
                    'dape-memory-mode)
           do (with-current-buffer buffer (revert-buffer))))

(defun dape-read-memory (offset)
  "Read `dape-read-memory-bytes' bytes of memory at MEMORY-REFERENCE."
  (interactive
   (list (string-trim
          (read-string "Offset: "
                       (when-let ((number (thing-at-point 'number)))
                         (format "0x%08x" number))))))
  (let ((conn (dape--live-connection 'stopped)))
    (unless (dape--capable-p conn :supportsReadMemoryRequest)
      (user-error "Adapter not capable of reading memory."))
    (let ((buffer
           (generate-new-buffer (format "*dape-memory @ %s*" offset))))
      (with-current-buffer buffer
        (dape-memory-mode)
        (setq dape--memory-offset offset)
        (revert-buffer))
      (display-buffer buffer))))

;;; Breakpoints

(dape--mouse-command dape-mouse-breakpoint-toggle
  "Toggle breakpoint at line."
  dape-breakpoint-toggle)

(dape--mouse-command dape-mouse-breakpoint-expression
  "Add log expression at line."
  dape-breakpoint-expression)

(dape--mouse-command dape-mouse-breakpoint-log
  "Add log breakpoint at line."
  dape-breakpoint-log)

(defvar dape-breakpoint-global-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [left-fringe mouse-1] 'dape-mouse-breakpoint-toggle)
    (define-key map [left-margin mouse-1] 'dape-mouse-breakpoint-toggle)
    (define-key map [left-fringe mouse-2] 'dape-mouse-breakpoint-expression)
    (define-key map [left-margin mouse-2] 'dape-mouse-breakpoint-expression)
    (define-key map [left-fringe mouse-3] 'dape-mouse-breakpoint-log)
    (define-key map [left-margin mouse-3] 'dape-mouse-breakpoint-log)
    map)
  "Keymap for `dape-breakpoint-global-mode'.")

(define-minor-mode dape-breakpoint-global-mode
  "Adds fringe and margin breakpoint controls."
  :global t
  :lighter "dape")

(defvar dape--original-margin nil
  "Bookkeeping for buffer margin width.")

(defun dape--margin-cleanup (buffer)
  "Reset BUFFERs margin if it's unused."
  (when buffer
    (with-current-buffer buffer
      (when (and dape--original-margin ;; Buffer has been touched by Dape
                 (not (thread-last dape--breakpoints
                                   (seq-filter (lambda (ov)
                                                 (not (overlay-get ov 'after-string))))
                                   (seq-group-by 'overlay-buffer)
                                   (alist-get buffer))))
        (setq-local left-margin-width dape--original-margin
                    dape--original-margin nil)
        ;; Update margin
        (when-let ((window (get-buffer-window buffer)))
          (set-window-buffer window buffer))))))

(defun dape--overlay-icon (overlay string bitmap face &optional in-margin)
  "Put STRING or BITMAP on OVERLAY with FACE.
If IN-MARGING put STRING in margin, otherwise put overlay over buffer
contents."
  (when-let ((buffer (overlay-buffer overlay)))
    (let ((before-string
           (cond
            ((and (window-system) ;; running in term
                  (not (eql (frame-parameter (selected-frame) 'left-fringe) 0)))
             (propertize " " 'display
                         `(left-fringe ,bitmap ,face)))
            (in-margin
             (with-current-buffer buffer
               (unless dape--original-margin
                 (setq-local dape--original-margin left-margin-width)
                 (setq left-margin-width 2)
                 (when-let ((window (get-buffer-window)))
                   (set-window-buffer window buffer))))
             (propertize " " 'display `((margin left-margin)
                                        ,(propertize string 'face face))))
            (t
             (move-overlay overlay
                           (overlay-start overlay)
                           (+ (overlay-start overlay)
                              (min
                               (length string)
                               (with-current-buffer (overlay-buffer overlay)
                                 (goto-char (overlay-start overlay))
                                 (- (line-end-position) (overlay-start overlay))))))
             (overlay-put overlay 'display "")
             (propertize string 'face face)))))
      (overlay-put overlay 'before-string before-string))))

(defun dape--breakpoint-freeze (overlay _after _begin _end &optional _len)
  "Make sure that Dape OVERLAY region covers line."
  ;; FIXME Press evil "O" on a break point line this will mess things up
  (apply 'move-overlay overlay
         (dape--overlay-region (eq (overlay-get overlay 'category)
                                   'dape-stack-pointer))))

(defun dape--breakpoints-at-point ()
  "Dape overlay breakpoints at point."
  (seq-filter (lambda (overlay)
                (eq 'dape-breakpoint (overlay-get overlay 'category)))
              (overlays-in (line-beginning-position) (line-end-position))))

(defun dape--breakpoint-buffer-kill-hook (&rest _)
  "Hook to remove breakpoint on buffer killed."
  (let ((breakpoints
         (alist-get (current-buffer)
                    (seq-group-by 'overlay-buffer
                                  dape--breakpoints))))
    (dolist (breakpoint breakpoints)
      (setq dape--breakpoints (delq breakpoint dape--breakpoints)))
    (dolist (conn (dape--live-connections))
      (when (dape--initialized-p conn)
        (dape--set-breakpoints-in-buffer conn (current-buffer)))))
  (run-hooks 'dape-update-ui-hooks))

(defun dape--breakpoint-place (&optional log-message expression skip-update)
  "Place breakpoint at current line.
If LOG-MESSAGE place log breakpoint with LOG-MESSAGE string.
If EXPRESSION place conditional breakpoint with EXPRESSION string.
Unless SKIP-UPDATE is non nil update adapter with breakpoint changes
in current buffer.  If there is an breakpoint at current line remove
that breakpoint as DAP only supports one breakpoint per line."
  (unless (derived-mode-p 'prog-mode)
    (user-error "Trying to set breakpoint in none `prog-mode' buffer"))
  (when-let ((prev-breakpoints (dape--breakpoints-at-point)))
    (dolist (prev-breakpoint prev-breakpoints)
      (dape--breakpoint-remove prev-breakpoint 'skip-update)))
  (let ((breakpoint (apply 'make-overlay (dape--overlay-region))))
    (overlay-put breakpoint 'window t)
    (overlay-put breakpoint 'category 'dape-breakpoint)
    (cond
     (log-message
      (overlay-put breakpoint 'dape-log-message log-message)
      (overlay-put breakpoint 'after-string
                   (concat
                    " "
                    (propertize (format "Log: %s" log-message)
                                'face 'dape-log-face
                                'mouse-face 'highlight
                                'help-echo "mouse-1: edit log message"
                                'keymap
                                (let ((map (make-sparse-keymap)))
                                  (define-key map [mouse-1] #'dape-mouse-breakpoint-log)
                                  map)))))
     (expression
      (overlay-put breakpoint 'dape-expr-message expression)
      (overlay-put breakpoint 'after-string
                   (concat
                    " "
                    (propertize
                     (format "Break: %s" expression)
                     'face 'dape-expression-face
                     'mouse-face 'highlight
                     'help-echo "mouse-1: edit break expression"
                     'keymap
                     (let ((map (make-sparse-keymap)))
                       (define-key map [mouse-1] #'dape-mouse-breakpoint-expression)
                       map)))))
     (t
      (overlay-put breakpoint 'dape-breakpoint t)
      (dape--overlay-icon breakpoint
                          dape-breakpoint-margin-string
                          'large-circle
                          'dape-breakpoint-face
                          'in-margin)))
    (overlay-put breakpoint 'modification-hooks '(dape--breakpoint-freeze))
    (push breakpoint dape--breakpoints)
    (dolist (conn (dape--live-connections))
      (unless skip-update
        (dape--set-breakpoints-in-buffer conn (current-buffer)))
      ;; FIXME Update stack pointer colors should be it's own function
      ;;       it's a shame we need conn here as only the color needs to
      ;;       be updated
      (when-let ((conn (dape--live-connection 'stopped t)))
        (dape--update-stack-pointers conn t t)))
    (add-hook 'kill-buffer-hook 'dape--breakpoint-buffer-kill-hook nil t)
    (run-hooks 'dape-update-ui-hooks)
    breakpoint))

(defun dape--breakpoint-remove (overlay &optional skip-update)
  "Remove OVERLAY breakpoint from buffer and session.
When SKIP-UPDATE is non nil, does not notify adapter about removal."
  (setq dape--breakpoints (delq overlay dape--breakpoints))
  (let ((buffer (overlay-buffer overlay)))
    (delete-overlay overlay)
    (unless skip-update
      (dolist (conn (dape--live-connections))
        (dape--set-breakpoints-in-buffer conn buffer))
      ;; FIXME Update stack pointer colors should be it's own function
      ;;       it's a shame we need conn here as only the color needs to
      ;;       be updated
      (when-let ((conn (dape--live-connection 'stopped t)))
        (dape--update-stack-pointers conn t t)))
    (dape--margin-cleanup buffer))
  (run-hooks 'dape-update-ui-hooks))

(defun dape--breakpoint-update (conn overlay breakpoint)
  "Update breakpoint OVERLAY with BREAKPOINT plist."
  (let ((id (plist-get breakpoint :id))
        (verified (eq (plist-get breakpoint :verified) t)))
    (overlay-put overlay 'dape-id id)
    (overlay-put overlay 'dape-verified verified)
    (run-hooks 'dape-update-ui-hooks))
  (when-let* ((old-buffer (overlay-buffer overlay))
              (old-line (with-current-buffer old-buffer
                          (line-number-at-pos (overlay-start overlay))))
              (breakpoint
               (append breakpoint
                       ;; Default to current overlay as `:source'
                       `(:source
                         ,(or (when-let ((path (buffer-file-name old-buffer)))
                                `(:path ,(dape--path conn path 'remote)))
                              (with-current-buffer old-buffer
                                dape--source))))))
    (dape--with-request (dape--source-ensure conn breakpoint)
      (when-let* ((marker (dape--object-to-marker conn breakpoint))
                  (new-buffer (marker-buffer marker))
                  (new-line (plist-get breakpoint :line)))
        (unless (and (= old-line new-line)
                     (eq old-buffer new-buffer))
          (with-current-buffer new-buffer
            (save-excursion
              (goto-char (point-min))
              (forward-line (1- new-line))
              (dape-breakpoint-remove-at-point)
              (pcase-let ((`(,beg ,end) (dape--overlay-region)))
                (move-overlay overlay beg end new-buffer))
              (pulse-momentary-highlight-region (line-beginning-position)
                                                (line-beginning-position 2)
                                                'next-error)))
          (dape--repl-message
           (format "* Breakpoint in %s moved from line %s to %s *"
                   old-buffer
                   old-line
                   new-line))
          (dape--update-stack-pointers conn t t)
          (run-hooks 'dape-update-ui-hooks))))))


;;; Source buffers

(defun dape--source-ensure (conn plist cb)
  "Ensure that source object in PLIST exist for adapter CONN.
See `dape-request' for expected CB signature."
  (let* ((source (plist-get plist :source))
         (path (plist-get source :path))
         (source-reference (plist-get source :sourceReference))
         (buffer (plist-get dape--source-buffers source-reference)))
    (cond
     ((or (not conn)
          (not (jsonrpc-running-p conn))
          (and path (file-exists-p (dape--path conn path 'local)))
          (and buffer (buffer-live-p buffer)))
      (dape--request-return cb))
     ((and (numberp source-reference) (> source-reference 0))
      (dape--with-request-bind
          ((&key content mimeType &allow-other-keys) error)
          (dape-request conn "source" (list :source source
                                            :sourceReference source-reference))
        (cond
         (error
          (dape--repl-message (format "%s" error) 'dape-repl-error-face))
         (content
          (let ((buffer
                 (generate-new-buffer (format "*dape-source %s*"
                                              (plist-get source :name)))))
            (setq dape--source-buffers
                  (plist-put dape--source-buffers
                             (plist-get source :sourceReference) buffer))
            (with-current-buffer buffer
              (if-let ((mode
                        (alist-get mimeType dape-mime-mode-alist nil nil 'equal)))
                  (unless (eq major-mode mode)
                    (funcall mode))
                (message "Unknown mime type %s, see `dape-mime-mode-alist'"
                         mimeType))
              (setq-local buffer-read-only t
                          dape--source source)
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert content))
              (goto-char (point-min)))
            (dape--request-return cb)))))))))


;;; Stack pointers

(defvar dape--stack-position (make-overlay 0 0)
  "Dape stack position overlay for arrow.")

(defvar dape--stack-position-overlay nil
  "Dape stack position overlay for line.")

(defun dape--remove-stack-pointers ()
  "Remove stack pointer marker."
  (when-let ((buffer (overlay-buffer dape--stack-position)))
    (with-current-buffer buffer
      (dape--remove-eldoc-hook)))
  (when (overlayp dape--stack-position-overlay)
    (delete-overlay dape--stack-position-overlay))
  (delete-overlay dape--stack-position))

(defun dape--update-stack-pointers (conn &optional
                                         skip-stack-pointer-flash skip-display)
  "Update stack pointer marker for adapter CONN.
If SKIP-STACK-POINTER-FLASH is non nil refrain from flashing line.
If SKIP-DISPLAY is non nil refrain from going to selected stack."
  (when-let (((dape--stopped-threads conn))
             (frame (dape--current-stack-frame conn)))
    (dape--remove-stack-pointers)
    (let ((deepest-p (eq frame (car (plist-get (dape--current-thread conn)
                                               :stackFrames)))))
      (dape--with-request (dape--source-ensure conn frame)
        (when-let ((marker (dape--object-to-marker conn frame)))
          (unless skip-display
            (when-let ((window
                        (display-buffer (marker-buffer marker)
                                        dape-display-source-buffer-action)))
              ;; Change selected window if not dape-repl buffer is selected
              (unless (with-current-buffer (window-buffer)
                        (memq major-mode '(dape-repl-mode)))
                (select-window window))
              (unless skip-stack-pointer-flash
                (with-current-buffer (marker-buffer marker)
                  (with-selected-window window
                    (goto-char (marker-position marker))
                    (pulse-momentary-highlight-region (line-beginning-position)
                                                      (line-beginning-position 2)
                                                      'next-error))))))
          (with-current-buffer (marker-buffer marker)
            (dape--add-eldoc-hook)
            (save-excursion
              (goto-char (marker-position marker))
              (setq dape--stack-position-overlay
                    (let ((ov
                           (make-overlay (line-beginning-position)
                                         (line-beginning-position 2))))
                      (overlay-put ov 'face 'dape-stack-trace-face)
                      (when deepest-p
                        (when-let ((exception-description
                                    (dape--exception-description conn)))
                          (overlay-put ov 'after-string
                                       (concat
                                        (propertize exception-description
                                                    'face
                                                    'dape-exception-description-face)
                                        "\n"))))
                      ov))
              ;; HACK I don't believe that it's defined
              ;;      behavior in which order fringe bitmaps
              ;;      are displayed in, maybe it's the order
              ;;      of overlay creation?
              (setq dape--stack-position
                    (make-overlay (line-beginning-position)
                                  (line-beginning-position)))
              (dape--overlay-icon dape--stack-position
                                  overlay-arrow-string
                                  'right-triangle
                                  (cond
                                   ((seq-filter (lambda (ov)
                                                  (overlay-get ov 'dape-breakpoint))
                                                (dape--breakpoints-at-point))
                                    'dape-breakpoint-face)
                                   (deepest-p
                                    'default)
                                   (t
                                    'shadow))))))))))

;;; Info Buffers

;; TODO Because buttons where removed from info buffer
;;      there should be a way to control execution by mouse

(defvar-local dape--info-buffer-related nil
  "List of related buffers.")
(defvar-local dape--info-buffer-identifier nil
  "Identifying var for buffers, used only in scope buffer.
Used there as scope index.")

(defvar dape--info-buffers nil
  "List containing `dape-info' buffers, might be un-live.")

(defun dape--info-buffer-list ()
  "Return all live `dape-info-parent-mode'."
  (setq dape--info-buffers
        (seq-filter 'buffer-live-p dape--info-buffers)))

(defun dape--info-buffer-p (mode &optional identifier)
  "Is buffer of MODE with IDENTIFIER.
Uses `dape--info-buffer-identifier' as IDENTIFIER."
  (and (eq major-mode mode)
       (or (not identifier)
           (equal dape--info-buffer-identifier identifier))))

(defun dape--info-buffer-tab (&optional reversed)
  "Select next related buffer in `dape-info' buffers.
REVERSED selects previous."
  (interactive)
  (unless dape--info-buffer-related
    (user-error "No related buffers for current buffer"))
  (pcase-let* ((order-fn (if reversed 'reverse 'identity))
               (`(,mode ,id)
                (or
                 (thread-last (append dape--info-buffer-related
                                      dape--info-buffer-related)
                              (funcall order-fn)
                              (seq-drop-while (pcase-lambda (`(,mode ,id))
                                                (not (dape--info-buffer-p mode id))))
                              (cadr))
                 (car dape--info-buffer-related))))
    (gdb-set-window-buffer
     (dape--info-get-buffer-create mode id) t)))

(defvar dape-info-parent-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<backtab>")
                (lambda () (interactive) (dape--info-buffer-tab t)))
    (define-key map "\t" 'dape--info-buffer-tab)
    map)
  "Keymap for `dape-info-parent-mode'.")

(defun dape--info-buffer-change-fn (&rest _rest)
  "Hook fn for `window-buffer-change-functions' to ensure update."
  (when (derived-mode-p 'dape-info-parent-mode)
    (ignore-errors (revert-buffer))))

(define-derived-mode dape-info-parent-mode special-mode ""
  "Generic mode to derive all other Dape gud buffer modes from."
  :interactive nil
  ;; Setup header-line without `buffer-revert'
  :after-hook (progn
                (dape--info-set-related-buffers)
                (dape--info-set-header-line-format))
  (setq-local buffer-read-only t
              truncate-lines t
              cursor-in-non-selected-windows nil
              ;; FIXME Is `revert-buffer-in-progress-p' is not
              ;;       respected as most of the work is done in an
              ;;       callback.
              revert-buffer-function #'dape--info-revert)
  (add-hook 'window-buffer-change-functions 'dape--info-buffer-change-fn
            nil 'local)
  (when dape-info-hide-mode-line
    (setq-local mode-line-format nil))
  (buffer-disable-undo))

(defun dape--info-header (name mode id help-echo mouse-face face)
  "Helper to create buffer header.
Creates header with string NAME, mouse map to select buffer
identified with MODE and ID (see `dape--info-buffer-identifier')
with HELP-ECHO string, MOUSE-FACE and FACE."
  (propertize name 'help-echo help-echo 'mouse-face mouse-face 'face face
              'keymap
              (gdb-make-header-line-mouse-map
	       'mouse-1
	       (lambda (event) (interactive "e")
		 (save-selected-window
		   (select-window (posn-window (event-start event)))
                   (let ((buffer (dape--info-get-buffer-create mode id)))
                     (with-current-buffer buffer (revert-buffer))
                     (gdb-set-window-buffer buffer t)))))))

(defun dape--info-set-header-line-format ()
  "Helper for dape info buffers to set header line.
Header line is custructed from buffer local
`dape--info-buffer-related'."
  (setq header-line-format
        (mapcan
         (pcase-lambda (`(,mode ,id ,name))
           (list
            (if (dape--info-buffer-p mode id)
                (dape--info-header name mode id nil nil 'mode-line)
              (dape--info-header name mode id "mouse-1: select"
                                 'mode-line-highlight
                                 'mode-line-inactive))
            " "))
         dape--info-buffer-related)))

(defun dape--info-call-update-with (fn &optional buffer)
  "Helper for `dape--info-revert' functions.
Erase buffer content and updates `header-line-format'.
FN is expected to update insert buffer contents, update
`dape--info-buffer-related' and `header-line-format'."
  (setq buffer (or buffer (current-buffer)))
  (with-current-buffer buffer
    (unless (derived-mode-p 'dape-info-parent-mode)
      (error "Trying to update non info buffer"))
    ;; Would be nice with replace-buffer-contents
    ;; But it seams to messes up string properties
    (let ((line (line-number-at-pos (point) t))
          (old-window (selected-window)))
      ;; Still don't know any better way of keeping window scroll?
      (when-let ((window (get-buffer-window buffer)))
        (select-window window))
      (save-window-excursion
        (let ((inhibit-read-only t))
          (erase-buffer)
          (funcall fn))
        (ignore-errors
          (goto-char (point-min))
          (forward-line (1- line)))
        (dape--info-set-related-buffers)
        (dape--info-set-header-line-format))
      (when old-window
        (select-window old-window)))))

(defmacro dape--info-update-with (&rest body)
  "Creates an update function from BODY.
See `dape--info-call-update-with'."
  (declare (indent 0))
  `(dape--info-call-update-with (lambda () ,@body)))

(defun dape--info-get-live-buffer (mode &optional identifier)
  "Get live dape info buffer with MODE and IDENTIFIER."
  (seq-find (lambda (buffer)
              (with-current-buffer buffer
                (dape--info-buffer-p mode identifier)))
            (dape--info-buffer-list)))

(defun dape--info-get-buffer-create (mode &optional identifier)
  "Get or create info buffer with MODE and IDENTIFIER."
  (let* ((identifier (or identifier 0))
         (buffer
          (or (dape--info-get-live-buffer mode identifier)
              (get-buffer-create (dape--info-buffer-name mode identifier)))))
    (with-current-buffer buffer
      (unless (eq major-mode mode)
        (funcall mode)
        (setq dape--info-buffer-identifier identifier)
        (push buffer dape--info-buffers)))
    buffer))

(defun dape-info-update ()
  "Update and display `dape-info-*' buffers."
  (dolist (buffer (dape--info-buffer-list))
    (when (get-buffer-window buffer)
      (with-current-buffer buffer
        (revert-buffer)))))

(defun dape-info (&optional maybe-kill kill)
  "Update and display *dape-info* buffers.
When called interactively MAYBE-KILL is non nil.
When optional MAYBE-KILL is non nil kill buffers if all *dape-info*
buffers are already displayed.
When optional kill is non nil kill buffers *dape-info* buffers.

See `dape-info-buffer-window-groups' to customize which buffers get
displayed."
  (interactive (list t))
  (cl-labels ((kill-dape-info ()
                (dolist (buffer (buffer-list))
                  (when (with-current-buffer buffer
                          (derived-mode-p 'dape-info-parent-mode))
                    (kill-buffer buffer)))))
    (if kill
        (kill-dape-info)
      (let (buffer-displayed-p)
        (dolist (group dape-info-buffer-window-groups)
          (unless (seq-find (lambda (buffer)
                              (and (get-buffer-window buffer)
                                   (with-current-buffer buffer
                                     (memq major-mode group))))
                            (dape--info-buffer-list))
            (setq buffer-displayed-p t)
            (dape--display-buffer
             (dape--info-get-buffer-create (car group)))))
        (dape-info-update)
        (when (and maybe-kill (not buffer-displayed-p))
          (kill-dape-info))))))

(defconst dape--info-buffer-name-alist
  '((dape-info-breakpoints-mode . "Breakpoints")
    (dape-info-threads-mode . "Threads")
    (dape-info-stack-mode . "Stack")
    (dape-info-modules-mode . "Modules")
    (dape-info-sources-mode . "Sources")
    (dape-info-watch-mode . "Watch"))
  "Lookup for `dape-info-parent-mode' derived modes names.")

(defun dape--info-buffer-name (mode &optional identifier)
  "Create buffer name from MODE and IDENTIFIER."
  (format "*dape-info %s*"
          (if (eq 'dape-info-scope-mode mode)
              (format "Scope <%s>" identifier)
            (if-let ((name (alist-get mode dape--info-buffer-name-alist)))
                name
              (error "Unable to create mode from %s with %s" mode identifier)))))

(defun dape--info-set-related-buffers ()
  "Store related buffers "
  (setq dape--info-buffer-related
        (cl-loop with group =
                 (cl-find-if (lambda (group) (memq major-mode group))
                             dape-info-buffer-window-groups)
                 with conn = (dape--live-connection 'stopped t)
                 with scopes = (plist-get (dape--current-stack-frame conn)
                                          :scopes)
                 for mode in group
                 append
                 (cond
                  ((and (not scopes) (eq mode 'dape-info-scope-mode))
                   ;; TODO Should grab `dape--info-buffer-related'
                   ;;      from other buffers if there are no
                   ;;      `dape-info-scope-modes' in the current ctx.
                   ;;      This would fix tabbing into other scopes after
                   ;;      an adapter has been killed.
                   (seq-filter (lambda (related)
                                 (eq (car related) 'dape-info-scope-mode))
                               dape--info-buffer-related))
                  ((eq mode 'dape-info-scope-mode)
                   (cl-loop for scope in scopes
                            for i from 0
                            for name = (plist-get scope :name)
                            collect
                            (list 'dape-info-scope-mode i name)))
                  (t
                   `((,mode nil
                            ,(alist-get mode dape--info-buffer-name-alist))))))))


;;; Info breakpoints buffer

(dape--command-at-line dape-info-breakpoint-goto (dape--info-breakpoint)
  "Goto breakpoint at line in dape info buffer."
  (when-let* ((buffer (overlay-buffer dape--info-breakpoint)))
    (with-selected-window (display-buffer buffer dape-display-source-buffer-action)
      (goto-char (overlay-start dape--info-breakpoint)))))

(dape--command-at-line dape-info-breakpoint-delete (dape--info-breakpoint)
  "Delete breakpoint at line in dape info buffer."
  (dape--breakpoint-remove dape--info-breakpoint)
  (dape--display-buffer (dape--info-get-buffer-create 'dape-info-breakpoints-mode)))

(dape--command-at-line dape-info-breakpoint-log-edit (dape--info-breakpoint)
  "Edit breakpoint at line in dape info buffer."
  (let ((edit-fn
         (cond
          ((overlay-get dape--info-breakpoint 'dape-log-message)
           'dape-breakpoint-log)
          ((overlay-get dape--info-breakpoint 'dape-expr-message)
           'dape-breakpoint-expression)
          ((user-error "Unable to edit breakpoint on line without log or expression breakpoint")))))
    (when-let* ((buffer (overlay-buffer dape--info-breakpoint)))
      (with-selected-window (display-buffer buffer dape-display-source-buffer-action)
        (goto-char (overlay-start dape--info-breakpoint))
        (call-interactively edit-fn)))))

(dape--buffer-map dape-info-breakpoints-line-map dape-info-breakpoint-goto
  (define-key map "D" 'dape-info-breakpoint-delete)
  (define-key map "d" 'dape-info-breakpoint-delete)
  (define-key map "e" 'dape-info-breakpoint-log-edit))

(dape--command-at-line dape-info-exceptions-toggle (dape--info-exception)
  "Toggle exception at line in dape info buffer."
  (plist-put dape--info-exception :enabled
             (not (plist-get dape--info-exception :enabled)))
  (dape-info-update)
  (dolist (conn (dape--live-connections))
    (dape--set-exception-breakpoints conn)))

(dape--buffer-map dape-info-exceptions-line-map dape-info-exceptions-toggle)

(define-derived-mode dape-info-breakpoints-mode dape-info-parent-mode
  "Breakpoints"
  :interactive nil
  "Major mode for Dape info breakpoints.")

(cl-defmethod dape--info-revert (&context (major-mode (eql dape-info-breakpoints-mode))
                                          &optional _ignore-auto _noconfirm _preserve-modes)
  "Revert buffer function for `dape-info-breakpoints-mode'."
  (dape--info-update-with
    (let ((table (make-gdb-table)))
      (gdb-table-add-row table '("Type" "On" "Where" "What"))
      (dolist (breakpoint (reverse dape--breakpoints))
        (when-let* ((buffer (overlay-buffer breakpoint))
                    (line (with-current-buffer buffer
                            (line-number-at-pos (overlay-start breakpoint)))))
          (gdb-table-add-row
           table
           (list
            (cond
             ((overlay-get breakpoint 'dape-log-message)
              "log")
             ((overlay-get breakpoint 'dape-expr-message)
              "condition")
             ("breakpoint"))
            (if (overlay-get breakpoint 'dape-verified)
                (propertize "y" 'font-lock-face
                            font-lock-warning-face)
              (propertize "" 'font-lock-face
                          font-lock-comment-face))
            (if-let (file (buffer-file-name buffer))
                (dape--format-file-line file line)
              (buffer-name buffer))
            (cond
             ((overlay-get breakpoint 'dape-log-message)
              (propertize (overlay-get breakpoint 'dape-log-message)
                          'face 'dape-log-face))
             ((overlay-get breakpoint 'dape-expr-message)
              (propertize (overlay-get breakpoint 'dape-expr-message)
                          'face 'dape-expression-face))
             ("")))
           (list
            'dape--info-breakpoint breakpoint
            'keymap dape-info-breakpoints-line-map
            'mouse-face 'highlight
            'help-echo "mouse-2, RET: visit breakpoint"))))
      (dolist (exception dape--exceptions)
        (gdb-table-add-row table
                           (list
                            "exception"
                            (if (plist-get exception :enabled)
                                (propertize "y" 'font-lock-face
                                            font-lock-warning-face)
                              (propertize "n" 'font-lock-face
                                          font-lock-comment-face))
                            (plist-get exception :label)
                            " ")
                           (list
                            'dape--info-exception exception
                            'mouse-face 'highlight
                            'keymap dape-info-exceptions-line-map
                            'help-echo "mouse-2, RET: toggle exception")))
      (insert (gdb-table-string table " ")))))


;;; Info threads buffer

(defvar dape--info-thread-position nil
  "`dape-info-thread-mode' marker for `overlay-arrow-variable-list'.")

(dape--command-at-line dape-info-select-thread (dape--info-thread)
  "Select thread at line in dape info buffer."
  (dape-select-thread (dape--live-connection 'stopped)
                      (plist-get dape--info-thread :id)))

(defvar dape--info-threads-font-lock-keywords
  (append gdb-threads-font-lock-keywords
          '((" \\(unknown\\)"  (1 font-lock-warning-face))
            (" \\(exited\\)"  (1 font-lock-warning-face))
            (" \\(started\\)"  (1 font-lock-string-face))))
  "Keywords for `dape-info-threads-mode'.")

(dape--buffer-map dape-info-threads-line-map dape-info-select-thread
  ;; TODO Add bindings for individual threads.
  )

(defun dape--info-threads-all-stack-trace (conn cb)
  "Populate CONN stack frame data for non selected threads.
See `dape-request' for expected CB signature."
  (if (not (dape--threads conn))
      (dape--request-return cb)
    (let ((responses 0))
      (dolist (thread (dape--threads conn))
        (dape--with-request (dape--stack-trace conn thread 1)
          (setf responses (1+ responses))
          (when (length= (dape--threads conn) responses)
            (dape--request-return cb)))))))

(define-derived-mode dape-info-threads-mode dape-info-parent-mode "Threads"
  "Major mode for Dape info threads."
  :interactive nil
  (setq font-lock-defaults '(dape--info-threads-font-lock-keywords)
        dape--info-thread-position (make-marker))
  (add-to-list 'overlay-arrow-variable-list 'dape--info-thread-position))


(cl-defmethod dape--info-revert (&context (major-mode (eql dape-info-threads-mode))
                                          &optional _ignore-auto _noconfirm _preserve-modes)
  "Revert buffer function for `dape-info-threads-mode'."
  (if-let ((conn (or (dape--live-connection 'stopped t)
                     (dape--live-connection 'last t)))
           (threads (dape--threads conn)))
      (dape--with-request (dape--info-threads-all-stack-trace conn)
        (dape--info-update-with
          (let ((table (make-gdb-table))
                (current-thread (dape--current-thread conn)))
            (set-marker dape--info-thread-position nil)
            (dolist (thread threads)
              (gdb-table-add-row
               table
               (list
                (format "%s" (plist-get thread :id))
                (concat
                 (when dape-info-thread-buffer-verbose-names
                   (concat (plist-get thread :name) " "))
                 (or (plist-get thread :status)
                     "unknown")
                 ;; Include frame information for stopped threads
                 (if-let* (((equal (plist-get thread :status) "stopped"))
                           (top-stack (thread-first thread
                                                    (plist-get :stackFrames)
                                                    (car))))
                     (concat
                      " in " (plist-get top-stack :name)
                      (when-let* ((dape-info-thread-buffer-locations)
                                  (path (thread-first top-stack
                                                      (plist-get :source)
                                                      (plist-get :path)))
                                  (path (dape--path conn path 'local))
                                  (line (plist-get top-stack :line)))
                        (concat " of " (dape--format-file-line path line)))
                      (when-let ((dape-info-thread-buffer-addresses)
                                 (addr
                                  (plist-get top-stack :instructionPointerReference)))
                        (concat " at " addr))
                      " "))))
               (list
                'dape--info-thread thread
                'mouse-face 'highlight
                'keymap dape-info-threads-line-map
                'help-echo "mouse-2, RET: select thread")))
            (insert (gdb-table-string table " "))
            (when current-thread
              (cl-loop for thread in threads
                       for line from 1
                       until (eq current-thread thread)
                       finally (gdb-mark-line line dape--info-thread-position))))))
    (dape--info-update-with
      (set-marker dape--info-thread-position nil)
      (insert "No thread information available."))))


;;; Info stack buffer

(defvar dape--info-stack-position nil
  "`dape-info-stack-mode' marker for `overlay-arrow-variable-list'.")

(defvar dape--info-stack-font-lock-keywords
  '(("in \\([^ ]+\\)"  (1 font-lock-function-name-face)))
  "Font lock keywords used in `gdb-frames-mode'.")

(dape--command-at-line dape-info-stack-select (dape--info-frame)
  "Select stack at line in dape info buffer."
  (dape-select-stack (dape--live-connection 'stopped)
                     (plist-get dape--info-frame :id)))

(dape--buffer-map dape-info-stack-line-map dape-info-stack-select)

(define-derived-mode dape-info-stack-mode dape-info-parent-mode "Stack"
  "Major mode for Dape info stack."
  :interactive nil
  (setq font-lock-defaults '(dape--info-stack-font-lock-keywords)
        dape--info-stack-position (make-marker))
  (add-to-list 'overlay-arrow-variable-list 'dape--info-stack-position))

(defun dape--info-stack-buffer-insert (conn current-stack-frame stack-frames)
  "Helper for inserting stack info into *dape-info Stack* buffer.
Create table from CURRENT-STACK-FRAME and STACK-FRAMES and insert into
current buffer with CONN config."
  (cl-loop with table = (make-gdb-table)
           for frame in stack-frames
           do
           (gdb-table-add-row
            table
            (list
             "in"
             (concat
              (plist-get frame :name)
              (when-let* ((dape-info-stack-buffer-locations)
                          (path (thread-first frame
                                              (plist-get :source)
                                              (plist-get :path)))
                          (path (dape--path conn path 'local)))
                (concat " of "
                        (dape--format-file-line path
                                                (plist-get frame :line))))
              (when-let ((dape-info-stack-buffer-addresses)
                         (ref
                          (plist-get frame :instructionPointerReference)))
                (concat " at " ref))
              " "))
            (list
             'dape--info-frame frame
             'mouse-face 'highlight
             'keymap dape-info-stack-line-map
             'help-echo "mouse-2, RET: Select frame"))
           finally (insert (gdb-table-string table " ")))
  (cl-loop for stack-frame in stack-frames
           for line from 1
           until (eq current-stack-frame stack-frame)
           finally (gdb-mark-line line dape--info-stack-position)))

(cl-defmethod dape--info-revert (&context (major-mode (eql dape-info-stack-mode))
                                          &optional _ignore-auto _noconfirm _preserve-modes)
  "Revert buffer function for `dape-info-stack-mode'."
  (let* ((conn (or (dape--live-connection 'stopped t)
                   (dape--live-connection 'last t)))
         (current-thread (dape--current-thread conn))
         (stack-frames (plist-get current-thread :stackFrames))
         (current-stack-frame (dape--current-stack-frame conn)))
    (cond
     ((or (not current-stack-frame)
          (not (dape--stopped-threads conn)))
      (dape--info-update-with
        (set-marker dape--info-stack-position nil)
        (insert "No stopped threads.")))
     (t
      ;; Why are we updating it twice? Calls to `dape--stack-trace'
      ;; with an large nof can be expensive, therefore 1 nof is fetchd
      ;; at an 'update event, then we fetch the rest here.

      ;; Start off with shoving available stack info into buffer
      (dape--info-update-with
        (dape--info-stack-buffer-insert conn current-stack-frame stack-frames))
      (dape--with-request (dape--stack-trace conn
                                             current-thread
                                             dape-stack-trace-levels)
        ;; If stack trace lookup with `dape-stack-trace-levels' frames changed
        ;; the stack frame list, we need to update the buffer again
        (unless (eq stack-frames (plist-get current-thread :stackFrames))
          (dape--info-update-with
            (dape--info-stack-buffer-insert conn current-stack-frame
                                            (plist-get current-thread :stackFrames)))))))))


;;; Info modules buffer

(defvar dape--info-modules-font-lock-keywords
  '(("^\\([^ ]+\\) "  (1 font-lock-function-name-face)))
  "Font lock keywords used in `gdb-frames-mode'.")

(dape--command-at-line dape-info-modules-goto (dape--info-module)
  "Goto module."
  (let ((conn (dape--live-connection 'last t))
        (source (list :source dape--info-module)))
    (dape--with-request (dape--source-ensure conn source)
      (if-let ((marker
                (dape--object-to-marker conn source)))
          (pop-to-buffer (marker-buffer marker))
        (user-error "Unable to open module")))))

(dape--buffer-map dape-info-module-line-map dape-info-modules-goto)

(define-derived-mode dape-info-modules-mode dape-info-parent-mode "Modules"
  "Major mode for Dape info modules."
  :interactive nil
  (setq font-lock-defaults '(dape--info-modules-font-lock-keywords)))

(cl-defmethod dape--info-revert (&context (major-mode (eql dape-info-modules-mode))
                                          &optional _ignore-auto _noconfirm _preserve-modes)
  "Revert buffer function for `dape-info-modules-mode'."
  (dape--info-update-with
    ;; Use last connection if current is dead
    (when-let ((conn (or (dape--live-connection 'stopped t)
                         (dape--live-connection 'last t)
                         dape--connection)))
      (cl-loop with modules = (dape--modules conn)
               with table = (make-gdb-table)
               for module in (reverse modules)
               do
               (gdb-table-add-row
                table
                (list
                 (concat
                  (plist-get module :name)
                  (when-let ((path (plist-get module :path)))
                    (concat " of " (dape--format-file-line path nil)))
                  (when-let ((address-range (plist-get module :addressRange)))
                    (concat " at "
                            address-range nil))
                  " "))
                (list
                 'dape--info-module module
                 'mouse-face 'highlight
                 'help-echo (format "mouse-2: goto module")
                 'keymap dape-info-module-line-map))
               finally (insert (gdb-table-string table " "))))))


;;; Info sources buffer

(dape--command-at-line dape-info-sources-goto (dape--info-source)
  "Goto source."
  ;; TODO Should be storing connection in `dape--info-source' instead of
  ;;      guessing
  (let ((conn (dape--live-connection 'last t))
        (source (list :source dape--info-source)))
    (dape--with-request (dape--source-ensure conn source)
      (if-let ((marker
                (dape--object-to-marker conn source)))
          (pop-to-buffer (marker-buffer marker))
        (user-error "Unable to get source")))))

(dape--buffer-map dape-info-sources-line-map dape-info-sources-goto)

(define-derived-mode dape-info-sources-mode dape-info-parent-mode "Sources"
  "Major mode for Dape info sources."
  :interactive nil)

(cl-defmethod dape--info-revert (&context (major-mode (eql dape-info-sources-mode))
                                          &optional _ignore-auto _noconfirm _preserve-modes)
  "Revert buffer function for `dape-info-sources-mode'."
  (dape--info-update-with
    ;; Use last connection if current is dead
    (when-let ((conn (or (dape--live-connection 'stopped t)
                         (dape--live-connection 'last t)
                         dape--connection)))
      (cl-loop with sources = (dape--sources conn)
               with table = (make-gdb-table)
               for source in (reverse sources)
               do (gdb-table-add-row table
                                     (list (concat (plist-get source :name) " "))
                                     (list
                                      'dape--info-source source
                                      'mouse-face 'highlight
                                      'keymap dape-info-sources-line-map
                                      'help-echo "mouse-2, RET: goto source"))
               finally (insert (gdb-table-string table " "))))))


;;; Info scope buffer

(defvar dape--info-expanded-p (make-hash-table :test 'equal)
  "Hash table to keep track of expanded info variables.")

(dape--command-at-line dape-info-scope-toggle (dape--info-path)
  "Expand or contract variable at line in dape info buffer."
  (unless (dape--live-connection 'stopped)
    (user-error "No stopped threads"))
  (puthash dape--info-path (not (gethash dape--info-path dape--info-expanded-p))
           dape--info-expanded-p)
  (revert-buffer))

(dape--buffer-map dape-info-variable-prefix-map dape-info-scope-toggle)

(dape--command-at-line dape-info-scope-watch-dwim (dape--info-variable)
  "Watch variable or remove from watch at line in dape info buffer."
  (dape-watch-dwim (or (plist-get dape--info-variable :evaluateName)
                       (plist-get dape--info-variable :name))
                   (eq major-mode 'dape-info-watch-mode)
                   (eq major-mode 'dape-info-scope-mode))
  (when (derived-mode-p 'dape-info-parent-mode)
    (gdb-set-window-buffer
     (dape--info-get-buffer-create 'dape-info-watch-mode) t)))

(dape--buffer-map dape-info-variable-name-map dape-info-scope-watch-dwim)

(dape--command-at-line dape-info-variable-edit
  (dape--info-ref dape--info-variable)
  "Edit variable value at line in dape info buffer."
  (dape--set-variable (dape--live-connection 'stopped)
                      dape--info-ref
                      dape--info-variable
                      (read-string
                       (format "Set value of %s `%s' = "
                               (plist-get dape--info-variable :type)
                               (plist-get dape--info-variable :name))
                       (or (plist-get dape--info-variable :value)
                           (plist-get dape--info-variable :result)))))

(dape--buffer-map dape-info-variable-value-map dape-info-variable-edit)

(defvar dape-info-scope-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "e" 'dape-info-scope-toggle)
    (define-key map "W" 'dape-info-scope-watch-dwim)
    (define-key map "=" 'dape-info-variable-edit)
    map)
  "Local keymap for dape scope buffers.")

;; TODO Add bindings for adding data breakpoint

(defun dape--info-locals-table-columns-list (alist)
  "Format and arrange the columns in locals display based on ALIST."
  ;; Stolen from gdb-mi but reimpleted due to usage of dape customs
  ;; org function `gdb-locals-table-columns-list'.
  (let (columns)
    (dolist (config dape-info-variable-table-row-config columns)
      (let* ((key  (car config))
             (max  (cdr config))
             (prop-org (alist-get key alist))
             (prop prop-org))
        (when prop-org
          (when (eq dape-info-buffer-variable-format 'line)
            (setq prop
                  (substring prop
                             0 (string-match-p "\n" prop))))
          (if (and (> max 0) (length> prop max))
              (push (propertize (string-truncate-left prop max) 'help-echo prop-org)
                    columns)
            (push prop columns)))))
    (nreverse columns)))

(defun dape--info-scope-add-variable (table object ref path maps)
  "Add variable OBJECT with REF and PATH to TABLE.
MAPS is an plist with keys; name, value and prefix.  The values of the
plist are used as keymap for each sections defined by the key."
  (let* ((name (or (plist-get object :name) " "))
         (type (or (plist-get object :type) " "))
         (value (or (plist-get object :value)
                    (plist-get object :result)
                    " "))
         (prefix (make-string (* (1- (length path)) 2) ? ))
         (path (cons (plist-get object :name) path))
         (expanded (gethash path dape--info-expanded-p))
         row)
    (setq name
          (propertize name
                      'mouse-face 'highlight
                      'help-echo "mouse-2: create or remove watch expression"
                      'keymap (plist-get maps 'name)
                      'font-lock-face font-lock-variable-name-face)
          type
          (propertize type
                      'font-lock-face font-lock-type-face)
          value
          (propertize value
                      'mouse-face 'highlight
                      'help-echo "mouse-2: edit value"
                      'keymap (plist-get maps 'value))
          prefix
          (concat
           (cond
            ((zerop (or (plist-get object :variablesReference) 0))
             (concat prefix " "))
            ((and expanded (plist-get object :variables))
             (propertize (concat prefix "-")
                         'mouse-face 'highlight
                         'help-echo "mouse-2: contract"
                         'keymap (plist-get maps 'prefix)))
            (t
             (propertize (concat prefix "+")
                         'mouse-face 'highlight
                         'help-echo "mouse-2: expand"
                         'keymap (plist-get maps 'prefix))))
           " "))
    (setq row (dape--info-locals-table-columns-list
               `((name  . ,name)
                 (type  . ,type)
                 (value . ,value))))
    (setcar row (concat prefix (car row)))
    (gdb-table-add-row table
                       (if dape-info-variable-table-aligned
                           row
                         (list (mapconcat 'identity row " ")))
                       (list 'dape--info-variable object
                             'dape--info-path path
                             'dape--info-ref ref))
    (when expanded
      ;; TODO Should be paged
      (dolist (variable (plist-get object :variables))
        (dape--info-scope-add-variable table
                                       variable
                                       (plist-get object :variablesReference)
                                       path
                                       maps)))))

;; FIXME Empty header line when adapter is killed
(define-derived-mode dape-info-scope-mode dape-info-parent-mode "Scope"
  "Major mode for Dape info scope."
  :interactive nil)

(cl-defmethod dape--info-revert (&context (major-mode (eql dape-info-scope-mode))
                                          &optional _ignore-auto _noconfirm _preserve-modes)
  "Revert buffer function for `dape-info-scope-mode'."
  (when-let* ((conn (or (dape--live-connection 'stopped t)
                        (dape--live-connection 'last t)))
              (frame (dape--current-stack-frame conn))
              (scopes (plist-get frame :scopes))
              ;; FIXME if scope is out of range here scope list could
              ;;       have shrunk since last update and current
              ;;       scope buffer should be killed and replaced if
              ;;       if visible
              (scope (nth dape--info-buffer-identifier scopes))
              ;; Check for stopped threads to reduce flickering
              ((dape--stopped-threads conn)))
    (dape--with-request (dape--variables conn scope)
      (dape--with-request
          (dape--variables-recursive conn
                                     scope
                                     (list (plist-get scope :name))
                                     (lambda (path object)
                                       (and (not (eq (plist-get object :expensive) t))
                                            (gethash (cons (plist-get object :name) path)
                                                     dape--info-expanded-p))))
        (when (and scope scopes (dape--stopped-threads conn))
          (dape--info-update-with
            (rename-buffer (format "*dape-info Scope: %s*" (plist-get scope :name)) t)
            (cl-loop with table = (make-gdb-table)
                     for object in (plist-get scope :variables)
                     initially (setf (gdb-table-right-align table)
                                     dape-info-variable-table-aligned)
                     do
                     (dape--info-scope-add-variable table
                                                    object
                                                    (plist-get scope :variablesReference)
                                                    (list (plist-get scope :name))
                                                    (list 'name dape-info-variable-name-map
                                                          'value dape-info-variable-value-map
                                                          'prefix dape-info-variable-prefix-map))
                     finally (insert (gdb-table-string table " ")))))))))


;;; Info watch buffer

(defvar dape-info-watch-mode-map (copy-keymap dape-info-scope-mode-map)
  "Local keymap for dape watch buffer.")

(define-derived-mode dape-info-watch-mode dape-info-parent-mode "Watch"
  "Major mode for Dape info watch."
  :interactive nil)

(cl-defmethod dape--info-revert (&context (major-mode (eql dape-info-watch-mode))
                                          &optional _ignore-auto _noconfirm _preserve-modes)
  "Revert buffer function for `dape-info-watch-mode'."
  (let ((conn (dape--live-connection 'stopped t)))
    (cond
     ((not dape--watched)
      (dape--info-update-with
        (insert "No watched variable.")))
     (conn
      (let ((frame (dape--current-stack-frame conn))
            (responses 0))
        (dolist (plist dape--watched)
          (plist-put plist :variablesReference nil)
          (plist-put plist :variables nil)
          (dape--with-request-bind
              (body error)
              (dape--evaluate-expression conn
                                         (plist-get frame :id)
                                         (plist-get plist :name)
                                         "watch")
            (unless error
              (cl-loop for (key value) on body by 'cddr
                       do (plist-put plist key value)))
            (setf responses (1+ responses))
            (when (length= dape--watched responses)
              (dape--with-request
                  (dape--variables-recursive conn
                                             (list :variables dape--watched)
                                             (list "Watch")
                                             (lambda (path object)
                                               (and (not (eq (plist-get object :expensive) t))
                                                    (gethash (cons (plist-get object :name) path)
                                                             dape--info-expanded-p))))
                (dape--info-update-with
                  (cl-loop with table = (make-gdb-table)
                           for watch in dape--watched
                           initially (setf (gdb-table-right-align table)
                                           dape-info-variable-table-aligned)
                           do
                           (dape--info-scope-add-variable table watch 'watch (list "Watch")
                                                          (list 'name dape-info-variable-name-map
                                                                'value dape-info-variable-value-map
                                                                'prefix dape-info-variable-prefix-map))
                           finally (insert (gdb-table-string table " "))))))))))
     (t
      (dape--info-update-with
        (cl-loop with table = (make-gdb-table)
                 for watch in dape--watched
                 initially (setf (gdb-table-right-align table)
                                 dape-info-variable-table-aligned)
                 do
                 (dape--info-scope-add-variable table watch 'watch (list "Watch")
                                                (list 'name dape-info-variable-name-map
                                                      'value dape-info-variable-value-map
                                                      'prefix dape-info-variable-prefix-map))
                 finally (insert (gdb-table-string table " "))))))))


;;; REPL buffer

(defvar dape--repl-prompt "> "
  "Dape repl prompt.")

(defun dape--repl-message (msg &optional face)
  "Insert MSG with FACE in *dape-repl* buffer.
Handles newline."
  (when (and (stringp msg) (not (string-empty-p msg)))
    (when (eql (aref msg (1- (length msg))) ?\n)
      (setq msg (substring msg 0 (1- (length msg)))))
    (setq msg (concat "\n" msg))
    (if (not (get-buffer-window "*dape-repl*"))
        (when (stringp msg)
          (message (format "%s" (string-trim msg))
                   'face face))
      (cond
       (dape--repl-insert-text-guard
        (run-with-timer 0.1 nil 'dape--repl-message msg))
       (t
        (let ((dape--repl-insert-text-guard t))
          (when-let ((buffer (get-buffer "*dape-repl*")))
            (with-current-buffer buffer
              (let (start)
                (if comint-last-prompt
                    (goto-char (1- (marker-position (car comint-last-prompt))))
                  (goto-char (point-max)))
                (setq start (point-marker))
                (let ((inhibit-read-only t))
                  (insert (apply 'propertize msg
                                 (when face (list 'font-lock-face face)))))
                (goto-char (point-max))
                ;; HACK Run hooks as if comint-output-filter was executed
                ;;      Could not get comint-output-filter to work by moving
                ;;      process marker. Comint removes forgets last prompt
                ;;      and everything goes to shit.
                (when-let ((process (get-buffer-process buffer)))
                  (set-marker (process-mark process)
                              (point-max)))
                (let ((comint-last-output-start start))
                  (run-hook-with-args 'comint-output-filter-functions msg)))))))))))

(defun dape--repl-insert-prompt ()
  "Insert `dape--repl-insert-prompt' into repl."
  (cond
   (dape--repl-insert-text-guard
    (run-with-timer 0.01 nil 'dape--repl-insert-prompt))
   (t
    (let ((dape--repl-insert-text-guard t))
      (when-let* ((buffer (get-buffer "*dape-repl*"))
                  (dummy-process (get-buffer-process buffer)))
        (comint-output-filter dummy-process dape--repl-prompt))))))

(defun dape--repl-update-variable (point variable)
  "Insert VARIABLE at POINT in *dape-repl* buffer.
VARIABLE is expected to be the string representation of a varable."
  (cond
   (dape--repl-insert-text-guard
    (run-with-timer 0.01 nil 'dape--repl-update-variable
                    point variable))
   (t
    (let ((dape--repl-insert-text-guard t))
      (when-let ((buffer (get-buffer "*dape-repl*")))
        (with-current-buffer buffer
          (when-let ((start
                      (save-excursion
                        (previous-single-property-change point
                                                         'dape--repl-variable)))
                     (end
                      (save-excursion
                        (next-single-property-change point
                                                     'dape--repl-variable))))
            (save-window-excursion
              (let ((inhibit-read-only t)
                    (line (line-number-at-pos (point) t)))
                (delete-region start end)
                (goto-char start)
                (insert variable)
                (ignore-errors
                  (goto-char (point-min))
                  (forward-line (1- line))))))))))))

(dape--command-at-line dape-repl-scope-toggle (dape--info-path
                                               dape--repl-variable)
  "Expand or contract variable at line in dape repl buffer."
  (unless (dape--live-connection 'stopped)
    (user-error "No stopped threads"))
  (puthash dape--info-path (not (gethash dape--info-path dape--info-expanded-p))
           dape--info-expanded-p)
  (dape--repl-create-variable-table (or (dape--live-connection 'stopped t)
                                        (dape--live-connection 'last))
                                    dape--repl-variable
                                    (apply-partially #'dape--repl-update-variable
                                                     (1+ (point)))))

(dape--buffer-map dape-repl-variable-prefix-map dape-repl-scope-toggle)

(defun dape--repl-create-variable-table (conn variable cb)
  (dape--with-request (dape--variables conn variable)
    (dape--with-request
        (dape--variables-recursive conn variable
                                   (list (plist-get variable :name) "Watch")
                                   (lambda (path object)
                                     (and (not (eq (plist-get object :expensive) t))
                                          (gethash (cons (plist-get object :name) path)
                                                   dape--info-expanded-p))))
      (let ((table (make-gdb-table)))
        (setf (gdb-table-right-align table)
              dape-info-variable-table-aligned)
        (dape--info-scope-add-variable table variable
                                       'watch
                                       (list "Watch")
                                       (list 'name dape-info-variable-name-map
                                             'value dape-info-variable-value-map
                                             'prefix dape-repl-variable-prefix-map))
        (funcall cb (propertize (gdb-table-string table " ")
                                'dape--repl-variable variable))))))

(defun dape--repl-input-sender (dummy-process input)
  "Dape repl `comint-input-sender'.
Send INPUT to DUMMY-PROCESS."
  (let (cmd)
    (cond
     ;; Run previous input
     ((and (string-empty-p input)
           (not (string-empty-p (car (ring-elements comint-input-ring)))))
      (when-let ((last (car (ring-elements comint-input-ring))))
        (message "Using last command %s" last)
        (dape--repl-input-sender dummy-process last)))
     ;; Run command from `dape-named-commands'
     ((setq cmd
            (or (alist-get input dape-repl-commands nil nil 'equal)
                (and dape-repl-use-shorthand
                     (cl-loop for (key . value) in dape-repl-commands
                              when (equal (substring key 0 1) input)
                              return value))))
      (dape--repl-insert-prompt)
      (call-interactively cmd))
     ;; Evaluate expression
     (t
      (dape--repl-insert-prompt)
      (let ((conn (or (dape--live-connection 'stopped t)
                      (dape--live-connection 'last)))
            (input (string-trim (substring-no-properties input))))
        (dape--with-request-bind
            ((&whole body &key variablesReference result &allow-other-keys) error)
            (dape--evaluate-expression conn (plist-get (dape--current-stack-frame conn) :id)
                                       input "repl")
          (cond
           (error
            (dape--repl-message error 'dape-repl-error-face))
           ((and-let* (((numberp variablesReference))
                       ((not (zerop variablesReference)))))
            (dape--repl-create-variable-table conn
                                              (plist-put body :name input)
                                              #'dape--repl-message))
           (t
            (dape--update conn nil t)
            (dape--repl-message result)))))))))

(defun dape--repl-completion-at-point ()
  "Completion at point function for *dape-repl* buffer."
  ;; FIXME still not 100% it's functional
  ;;       - compleation is messed up if point is in text and
  ;;         compleation is triggered
  ;;       - compleation is done on whole line for `debugpy'
  (when (or (symbol-at-point)
            (member (buffer-substring-no-properties (1- (point)) (point))
                    (or (thread-first (dape--live-connection 'last t)
                                      (dape--capabilities)
                                      (plist-get :completionTriggerCharacters)
                                      (append nil))
                        '("."))))
    (let* ((bounds (save-excursion
                     (cons (and (skip-chars-backward "^\s")
                                (point))
                           (and (skip-chars-forward "^\s")
                                (point)))))
           (column (1+ (- (cdr bounds) (car bounds))))
           (str (buffer-substring-no-properties
                 (car bounds)
                 (cdr bounds)))
           (collection
            (mapcar (lambda (cmd)
                      (cons (car cmd)
                            (format " %s"
                                    (propertize (symbol-name (cdr cmd))
                                                'face 'font-lock-builtin-face))))
                    dape-repl-commands))
           done)
      (list
       (car bounds)
       (cdr bounds)
       (completion-table-dynamic
        (lambda (_str)
          (when-let ((conn (or (dape--live-connection 'stopped t)
                               (dape--live-connection 'last t))))
            (dape--with-request-bind
                ((&key targets &allow-other-keys) _error)
                (dape-request conn
                              "completions"
                              (append
                               (when (dape--stopped-threads conn)
                                 (list :frameId
                                       (plist-get (dape--current-stack-frame conn) :id)))
                               (list
                                :text str
                                :column column
                                :line 1)))
              (setq collection
                    (append
                     collection
                     (mapcar
                      (lambda (target)
                        (cons
                         (cond
                          ((plist-get target :text)
                           (plist-get target :text))
                          ((and (plist-get target :label)
                                (plist-get target :start))
                           (let ((label (plist-get target :label))
                                 (start (plist-get target :start)))
                             (concat (substring str 0 start)
                                     label
                                     (substring str
                                                (thread-first
                                                  target
                                                  (plist-get :length)
                                                  (+ 1 start)
                                                  (min (length str)))))))
                          ((and (plist-get target :label)
                                (memq (aref str (1- (length str))) '(?. ?/ ?:)))
                           (concat str (plist-get target :label)))
                          ((and (plist-get target :label)
                                (length> (plist-get target :label)
                                         (length str)))
                           (plist-get target :label))
                          ((and (plist-get target :label)
                                (length> (plist-get target :label)
                                         (length str)))
                           (cl-loop with label = (plist-get target :label)
                                    for i downfrom (1- (length label)) downto 1
                                    when (equal (substring str (- (length str) i))
                                                (substring label 0 i))
                                    return (concat str (substring label i))
                                    finally return label)))
                         (when-let ((type (plist-get target :type)))
                           (format " %s"
                                   (propertize type
                                               'face 'font-lock-type-face)))))
                      targets)))
              (setf done t))
            (while-no-input
              (while (not done)
                (accept-process-output nil 0 1))))
          collection))
       :annotation-function
       (lambda (str)
         (when-let ((annotation
                     (alist-get (substring-no-properties str) collection
                                nil nil 'equal)))
           annotation))))))

(defvar dape-repl-mode nil)

(define-derived-mode dape-repl-mode comint-mode "Dape REPL"
  "Mode for *dape-repl* buffer."
  :group 'dape
  :interactive nil
  (when dape-repl-mode
    (user-error "`dape-repl-mode' all ready enabled"))
  (setq-local dape-repl-mode t
              comint-prompt-read-only t
              comint-scroll-to-bottom-on-input t
              ;; HACK ? Always keep prompt at the bottom of the window
              scroll-conservatively 101
              comint-input-sender 'dape--repl-input-sender
              comint-prompt-regexp (concat "^" (regexp-quote dape--repl-prompt))
              comint-process-echoes nil)
  (add-hook 'completion-at-point-functions #'dape--repl-completion-at-point nil t)
  ;; Stolen from ielm
  ;; Start a dummy process just to please comint
  (unless (comint-check-proc (current-buffer))
    (let ((process
           (start-process "dape-repl" (current-buffer) nil)))
      (add-hook 'kill-buffer-hook (lambda () (delete-process process)) nil t))
    (set-process-query-on-exit-flag (get-buffer-process (current-buffer))
                                    nil)
    (set-process-filter (get-buffer-process (current-buffer))
                        'comint-output-filter)
    (insert (format
             "* Welcome to Dape REPL! *
Available Dape commands: %s
Empty input will rerun last command.\n"
             (mapconcat 'identity
                        (mapcar (lambda (cmd)
                                  (let ((str (car cmd)))
                                    (if dape-repl-use-shorthand
                                        (concat
                                         (propertize
                                          (substring str 0 1)
                                          'font-lock-face 'help-key-binding)
                                         (substring str 1))
                                      str)))
                                dape-repl-commands)
                        ", ")))
    (set-marker (process-mark (get-buffer-process (current-buffer))) (point))
    (comint-output-filter (get-buffer-process (current-buffer))
                          dape--repl-prompt)))

(defun dape-repl ()
  "Create or select *dape-repl* buffer."
  (interactive)
  (let ((buffer-name "*dape-repl*")
        window)
    (with-current-buffer (get-buffer-create buffer-name)
      (unless dape-repl-mode
        (dape-repl-mode))
      (setq window (dape--display-buffer (current-buffer)))
      (when (called-interactively-p 'interactive)
        (select-window window)))))



;;; Minibuffer config hints

(defvar dape--minibuffer-suggestions nil
  "Suggested configurations in minibuffer.")

(defvar dape--minibuffer-last-buffer nil
  "Helper var for `dape--minibuffer-hint'.")

(defvar dape--minibuffer-cache nil
  "Helper var for `dape--minibuffer-hint'.")

(defvar dape--minibuffer-hint-overlay nil
  "Overlay for `dape--minibuffer-hint'.")

(dolist (fn '(dape-cwd
              dape-command-cwd
              dape-buffer-default
              dape--rust-program
              dape--netcoredbg-program
              dape--rdbg-c
              dape--jdtls-file-path
              dape--jdtls-main-class
              dape--jdtls-project-name))
  (put fn 'dape--minibuffer-hint t))

(defun dape--minibuffer-hint (&rest _)
  "Display current configuration in minibuffer in overlay."
  (save-excursion
    (let ((str
           (string-trim (buffer-substring (minibuffer-prompt-end)
                                          (point-max))))
          use-cache use-ensure-cache error-message hint-key hint-config hint-rows)

      (ignore-errors
        (pcase-setq `(,hint-key ,hint-config) (dape--config-from-string str t)))
      (setq default-directory
            (dape--guess-root hint-config)
            use-cache
            (pcase-let ((`(,key ,config)
                         dape--minibuffer-cache))
              (and (equal hint-key key)
                   (equal hint-config config)))
            use-ensure-cache
            (pcase-let ((`(,key config ,error-message)
                         dape--minibuffer-cache))
              ;; FIXME ensure is expensive so we are a bit cheap
              ;; here, correct would be to use `use-cache'
              (and (equal hint-key key)
                   (not error-message)))
            error-message
            (if use-ensure-cache
                (pcase-let ((`(key config ,error-message)
                             dape--minibuffer-cache))
                  error-message)
              (condition-case err
                  (progn
                    (with-current-buffer dape--minibuffer-last-buffer
                      (dape--config-ensure hint-config t))
                    nil)
                (error (setq error-message (error-message-string err)))))
            hint-rows
            (if use-cache
                (pcase-let ((`(key config error-message ,hint-rows)
                             dape--minibuffer-cache))
                  hint-rows)
              (cl-loop with base-config = (alist-get hint-key dape-configs)
                       for (key value) on hint-config by 'cddr
                       unless (or (memq key dape-minibuffer-hint-ignore-properties)
                                  (and (eq key 'port) (eq value :autoport))
                                  (eq key 'ensure))
                       collect (concat
                                (propertize (format "%s" key)
                                            'face font-lock-keyword-face)
                                " "
                                (propertize
                                 (format "%S"
                                         (with-current-buffer dape--minibuffer-last-buffer
                                           (condition-case _
                                               (dape--config-eval-value value nil nil t)
                                             (error 'error))))
                                 'face (when (equal value (plist-get base-config key))
                                         'shadow)))))
            dape--minibuffer-cache
            (list hint-key hint-config error-message hint-rows))
      (overlay-put dape--minibuffer-hint-overlay
                   'before-string
                   (concat
                    (propertize " " 'cursor 0)
                    (when error-message
                      (format "%s" (propertize error-message 'face 'error)))))
      (when dape-minibuffer-hint
        (overlay-put dape--minibuffer-hint-overlay
                     'after-string
                     (concat
                      (when hint-rows
                        (concat
                         "\n\n"
                         (mapconcat 'identity hint-rows "\n")))))))
    (move-overlay dape--minibuffer-hint-overlay
                  (point-max) (point-max) (current-buffer))))


;;; Config

(defun dape--plistp (object)
  "Non-nil if and only if OBJECT is a valid plist."
  (and-let* (((listp object))
             (len (length object))
             ((zerop (% len 2))))))

(defun dape--config-eval-value (value &optional skip-function for-adapter for-hints)
  "Evaluate dape config VALUE.
If SKIP-FUNCTION and VALUE is an function it is not invoked.
If FOR-ADAPTER current value is for the debug adapter.  Other rules
apply.
If FOR-HINTS handle function symbols as if they are going to be
displayed as hints display."
  (cond
   ((functionp value)
    (cond
     (skip-function value)
     (for-hints
      (cond
       ((and (symbolp value) (get value 'dape--minibuffer-hint))
        (funcall value))
       ((eq (car-safe value) 'lambda)
        value)
       (t value)))
     (t (funcall-interactively value))))
   ((dape--plistp value)
    (dape--config-eval-1 value skip-function for-adapter for-hints))
   ((vectorp value) (cl-map 'vector
                            (lambda (value)
                              (dape--config-eval-value value
                                                       skip-function
                                                       for-adapter
                                                       for-hints))
                            value))
   ((and (symbolp value)
         (not (eq (symbol-value value) value)))
    (dape--config-eval-value (symbol-value value)
                             skip-function for-adapter for-hints))
   (t value)))

(defun dape--config-eval-1 (config &optional skip-functions for-adapter for-hints)
  "Helper for `dape--config-eval'."
  (cl-loop for (key value) on config by 'cddr
           append (cond
                   ((memql key '(modes fn ensure)) (list key value))
                   ((and for-adapter (not (keywordp key)))
                    (user-error "Unexpected key %S; lists of things needs be \
arrays [%S ...], if meant as an object replace (%S ...) with (:%s ...)"
                                key key key key))
                   (t (list key (dape--config-eval-value value
                                                         skip-functions
                                                         (or for-adapter
                                                             (keywordp key))
                                                         for-hints))))))

(defun dape--config-eval (key options)
  "Evaluate Dape config with KEY and OPTIONS."
  (let ((base-config (alist-get key dape-configs)))
    (unless base-config
      (user-error "Unable to find `%s' in `dape-configs', available configurations: %s"
                  key (mapconcat (lambda (e) (symbol-name (car e)))
                                 dape-configs ", ")))
    (dape--config-eval-1 (seq-reduce (apply-partially 'apply 'plist-put)
                                     (seq-partition options 2)
                                     (copy-tree base-config)))))

(defun dape--config-from-string (str &optional loose-parsing)
  "Parse list of name and config from STR.
If LOOSE-PARSING is non nil ignore arg parsing failures."
  (let (name read-config base-config)
    (with-temp-buffer
      (insert str)
      (goto-char (point-min))
      (unless (setq name (ignore-errors (read (current-buffer))))
        (user-error "Expects config name (%s)"
                    (mapconcat (lambda (e) (symbol-name (car e)))
                               dape-configs ", ")))
      (unless (alist-get name dape-configs)
        (user-error "No configuration named `%s'" name))
      (setq base-config (copy-tree (alist-get name dape-configs)))
      (condition-case _
          ;; FIXME ugly
          (while (not (string-empty-p (string-trim (buffer-substring (point) (point-max)))))
            (push (read (current-buffer))
                  read-config))
        (error
         (unless loose-parsing
           (user-error "Unable to parse options %s"
                       (buffer-substring (point) (point-max)))))))
    (when (and loose-parsing
               (not (dape--plistp read-config)))
      (pop read-config))
    (setq read-config (nreverse read-config))
    (unless (dape--plistp read-config)
      (user-error "Bad options format, see `dape-configs'"))
    (cl-loop for (key value) on read-config by 'cddr
             do (setq base-config (plist-put base-config key value)))
    (list name base-config)))

(defun dape--config-diff (key post-eval)
  "Create a diff of config KEY and POST-EVAL config."
  (let ((base-config (alist-get key dape-configs)))
    (cl-loop for (key value) on post-eval by 'cddr
             unless (or (memql key '(modes fn ensure)) ;; Skip meta params
                        (and
                         ;; Does the key exist in `base-config'?
                         (plist-member base-config key)
                         ;; Has value changed?
                         (equal (dape--config-eval-value (plist-get base-config key)
                                                         t)
                                value)))
             append (list key value))))

(defun dape--config-to-string (key post-eval-config)
  "Create string from KEY and POST-EVAL-CONFIG."
  (let ((config-diff (dape--config-diff key post-eval-config)))
    (concat (when key (format "%s" key))
            (and-let* ((config-diff) (config-str (prin1-to-string config-diff)))
              (format " %s"
                      (substring config-str
                                 1
                                 (1- (length config-str))))))))

(defun dape--config-ensure (config &optional signal)
  "Ensure that CONFIG is valid executable.
If SIGNAL is non nil raises an `user-error'."
  (if-let ((ensure-fn (plist-get config 'ensure)))
      (let ((default-directory
             (or (when-let ((command-cwd (plist-get config 'command-cwd)))
                   (dape--config-eval-value command-cwd))
                 default-directory)))
        (condition-case err
            (or (funcall ensure-fn config) t)
          (error
           (if signal (user-error (error-message-string err)) nil))))
    t))

(defun dape--config-mode-p (config)
  "Is CONFIG enabled for current mode."
  (let ((modes (plist-get config 'modes)))
    (or (not modes)
        (apply 'provided-mode-derived-p
               major-mode (cl-map 'list 'identity modes))
        (and-let* (((not (derived-mode-p 'prog-mode)))
                   (last-hist (car dape-history))
                   (last-config (cadr (dape--config-from-string last-hist))))
          (cl-some (lambda (mode)
                     (memql mode (plist-get last-config 'modes)))
                   modes)))))

(defun dape--config-completion-at-point ()
  "Function for `completion-at-point' fn for `dape--read-config'."
  (let (key args args-bounds last-p)
    (save-excursion
      (goto-char (minibuffer-prompt-end))
      (setq key
            (ignore-errors (read (current-buffer))))
      (ignore-errors
        (while t
          (setq last-p (point))
          (push (read (current-buffer))
                args)
          (push (cons last-p (point))
                args-bounds))))
    (setq args (nreverse args)
          args-bounds (nreverse args-bounds))
    (cond
     ;; Complete config key
     ((or (not key)
          (and (not args)
               (thing-at-point 'symbol)))
      (pcase-let ((`(,start . ,end)
                   (or (bounds-of-thing-at-point 'symbol)
                       (cons (point) (point)))))
        (list start end
              (mapcar (lambda (suggestion) (format "%s " suggestion))
                      dape--minibuffer-suggestions))))
     ;; Complete config args
     ((and (alist-get key dape-configs)
           (or (and (plistp args)
                    (thing-at-point 'whitespace))
               (cl-loop with p = (point)
                        for ((start . end) _) on args-bounds by 'cddr
                        when (and (<= start p) (<= p end))
                        return t
                        finally return nil)))
      (pcase-let ((`(,start . ,end)
                   (or (bounds-of-thing-at-point 'symbol)
                       (cons (point) (point)))))
        (list start end
              (cl-loop with plist = (append (alist-get key dape-configs)
                                            '(compile nil))
                       for (key _) on plist by 'cddr
                       collect (format "%s " key)))))
     (t
      (list (point) (point)
            nil
            :exclusive 'no)))))

(defun dape--read-config ()
  "Read config from minibuffer.
Initial contents defaults to valid configuration if there is only one
or last mode valid history item from this session.

See `dape--config-mode-p' how \"valid\" is defined."
  (let* ((suggested-configs
          (cl-loop for (key . config) in dape-configs
                   when (and (dape--config-mode-p config)
                             (dape--config-ensure config))
                   collect (dape--config-to-string key nil)))
         (initial-contents
          (or
           ;; Take `dape-command' if exist
           (when dape-command
             (dape--config-to-string (car dape-command)
                                     (cdr dape-command)))
           ;; Take first valid history item
           (seq-find (lambda (str)
                       (ignore-errors
                         (member (thread-first (dape--config-from-string str)
                                               (car)
                                               (dape--config-to-string nil))
                                 suggested-configs)))
                     dape-history)
           ;; Take first suggested config if only one exist
           (and (length= suggested-configs 1)
                (car suggested-configs)))))
    (setq dape--minibuffer-last-buffer (current-buffer)
          dape--minibuffer-cache nil)
    (minibuffer-with-setup-hook
        (lambda ()
          (setq-local dape--minibuffer-suggestions suggested-configs
                      comint-completion-addsuffix nil
                      resize-mini-windows t
                      max-mini-window-height 0.5
                      dape--minibuffer-hint-overlay (make-overlay (point) (point))
                      default-directory (dape-command-cwd))
          (set-syntax-table emacs-lisp-mode-syntax-table)
          (add-hook 'completion-at-point-functions
                    'comint-filename-completion nil t)
          (add-hook 'completion-at-point-functions
                    #'dape--config-completion-at-point nil t)
          (add-hook 'after-change-functions
                    #'dape--minibuffer-hint nil t)
          (dape--minibuffer-hint))
      (pcase-let* ((str
                    (let ((history-add-new-input nil))
                      (read-from-minibuffer
                       "Run adapter: "
                       initial-contents
                       (let ((map (make-sparse-keymap)))
                         (set-keymap-parent map minibuffer-local-map)
                         (define-key map (kbd "C-M-i") #'completion-at-point)
                         (define-key map "\t" #'completion-at-point)
                         (define-key map (kbd "C-c C-k")
                                     (lambda ()
                                       (interactive)
                                       (pcase-let* ((str (buffer-substring (minibuffer-prompt-end)
                                                                           (point-max)))
                                                    (`(,key) (dape--config-from-string str t)))
                                         (delete-region (minibuffer-prompt-end) (point-max))
                                         (insert (format "%s" key) " "))))
                         map)
                       nil 'dape-history initial-contents)))
                   (`(,key ,config)
                    (dape--config-from-string (substring-no-properties str) t))
                   (evaled-config (dape--config-eval key config)))
        (setq dape-history
              (cons (dape--config-to-string key evaled-config)
                    dape-history))
        evaled-config))))


;;; Hover

(defun dape-hover-function (cb)
  "Hook function to produce doc strings for `eldoc'.
On success calls CB with the doc string.
See `eldoc-documentation-functions', for more infomation."
  (and-let* ((conn (dape--live-connection 'last t))
             ((dape--capable-p conn :supportsEvaluateForHovers))
             (symbol (thing-at-point 'symbol)))
    (dape--with-request-bind
        (body error)
        (dape--evaluate-expression conn
                                   (plist-get (dape--current-stack-frame conn) :id)
                                   (substring-no-properties symbol)
                                   "hover")
      (unless error
        (funcall cb (dape--variable-string
                     (plist-put body :name symbol))))))
  t)

(defun dape--add-eldoc-hook ()
  "Add `dape-hover-function' from eldoc hook."
  (add-hook 'eldoc-documentation-functions #'dape-hover-function nil t))

(defun dape--remove-eldoc-hook ()
  "Remove `dape-hover-function' from eldoc hook."
  (remove-hook 'eldoc-documentation-functions #'dape-hover-function t))


;;; Mode line

(defun dape--update-state (conn state)
  "Update Dape mode line with STATE symbol for adapter CONN."
  (setf (dape--state conn) state)
  (force-mode-line-update t))

(defun dape--mode-line-format ()
  "Format Dape mode line."
  (let ((conn (or (dape--live-connection 'last t)
                  dape--connection)))
    (concat (propertize "dape" 'face 'font-lock-constant-face)
            ":"
            (propertize
             (format "%s" (or (and conn (dape--state conn))
                              'unknown))
             'face 'font-lock-doc-face))))

(add-to-list 'mode-line-misc-info
             `(dape-active-mode
               (" [" (:eval (dape--mode-line-format)) "] ")))


;;; Savehist mode

(defvar savehist-additional-variables) ;; skip savehist require

(defvar dape--breakpoints-savehist nil
  "Used to save and load `dape--breakpoints' in an printable format.")

(defun dape-savehist-load ()
  "Load breakpoints and exceptions saved by `savehist-mode'."
  (when (and dape-use-savehist (not dape--breakpoints))
    (add-to-list 'savehist-additional-variables 'dape--breakpoints-savehist)
    (add-to-list 'savehist-additional-variables 'dape--exceptions)
    (cl-loop for (file point . args) in dape--breakpoints-savehist
             do (ignore-errors
                  (with-current-buffer (find-file-noselect file)
                    (save-excursion
                      (goto-char point)
                      (apply #'dape--breakpoint-place args)))))
    (add-hook 'savehist-save-hook #'dape--breakpoints-savehist-save))
  (remove-hook 'savehist-mode-hook #'dape-savehist-load))

(defun dape--breakpoints-savehist-save ()
  "Store breakpoints in an printable format for `savehist-mode'."
  (setq dape--breakpoints-savehist
        (cl-loop with arg-symbols = '(dape-log-message dape-expr-message)
                 for ov in dape--breakpoints
                 for file = (buffer-file-name (overlay-buffer ov))
                 for point = (overlay-start ov)
                 for args = (mapcar (apply-partially 'overlay-get ov) arg-symbols)
                 when (and file point)
                 collect (append (list file point) args))))

(if (bound-and-true-p savehist-loaded)
    (dape-savehist-load)
  (add-hook 'savehist-mode-hook #'dape-savehist-load))


;;; Keymaps

(defvar dape-global-map
  (let ((map (make-sparse-keymap)))
    (define-key map "d" #'dape)
    (define-key map "p" #'dape-pause)
    (define-key map "c" #'dape-continue)
    (define-key map "n" #'dape-next)
    (define-key map "s" #'dape-step-in)
    (define-key map "o" #'dape-step-out)
    (define-key map "r" #'dape-restart)
    (define-key map "i" #'dape-info)
    (define-key map "R" #'dape-repl)
    (define-key map "m" #'dape-read-memory)
    (define-key map "l" #'dape-breakpoint-log)
    (define-key map "e" #'dape-breakpoint-expression)
    (define-key map "b" #'dape-breakpoint-toggle)
    (define-key map "B" #'dape-breakpoint-remove-all)
    (define-key map "t" #'dape-select-thread)
    (define-key map "S" #'dape-select-stack)
    (define-key map ">" #'dape-stack-select-down)
    (define-key map "<" #'dape-stack-select-up)
    (define-key map "x" #'dape-evaluate-expression)
    (define-key map "w" #'dape-watch-dwim)
    (define-key map "D" #'dape-disconnect-quit)
    (define-key map "q" #'dape-quit)
    map))

(dolist (cmd '(dape
               dape-pause
               dape-continue
               dape-next
               dape-step-in
               dape-step-out
               dape-restart
               dape-breakpoint-log
               dape-breakpoint-expression
               dape-breakpoint-toggle
               dape-breakpoint-remove-all
               dape-stack-select-up
               dape-stack-select-down
               dape-watch-dwim))
  (put cmd 'repeat-map 'dape-global-map))

(when dape-key-prefix (global-set-key dape-key-prefix dape-global-map))


;;; Hooks

;; Cleanup conn before bed time
(add-hook 'kill-emacs-hook
          (defun dape-kill-busy-wait ()
            (let (done)
              (dape--with-request (dape-kill dape--connection)
                (setf done t))
              ;; Busy wait for response at least 2 seconds
              (cl-loop with max-iterations = 20
                       for i from 1 to max-iterations
                       until done
                       do (accept-process-output nil 0.1)))))

(provide 'dape)

;;; dape.el ends here
