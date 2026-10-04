;;; impro.el --- Scripted, re-recordable demos of Emacs packages -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, multimedia

;;; Commentary:

;; Plays a scenario in a second Emacs (your own config, or `emacs -Q') and
;; records its window to an MP4 and a GIF.  Keys go through the real
;; command loop on a timer, with a caption and the keys pressed in the
;; mode line (keycast when it loads, a built-in segment otherwise).
;;
;;   M-x impro-doctor     check this system can record, and what to fix
;;   M-x impro-new        start a scenario for a package from a template
;;   M-x impro-draft      or draft one from the package's README (gptel)
;;   M-x impro-lint       check a scenario without playing it
;;   M-x impro-rehearse   play a scenario, no recording; shows the step log
;;   M-x impro-record     record it to OUT.mp4 and OUT.gif
;;   M-x impro-abort      stop the take in progress
;;
;; Takes run in the background, so you can keep working (just don't type
;; into the demo window).  From a shell, or CI:
;;
;;   emacs --batch -l impro.el -f impro-batch SCENARIO.el OUT
;;   emacs --batch -l impro.el -f impro-batch SCENARIO.el --rehearse
;;   emacs --batch -l impro.el -f impro-batch SCENARIO.el --lint
;;   emacs --batch -l impro.el -f impro-batch --doctor
;;
;; Only the demo window is recorded, never the rest of the screen (see
;; `impro-recorder'): on Linux the demo Emacs saves its own frames (a
;; Cairo build; X11, Wayland, or headless under Xvfb); on macOS a small
;; ScreenCaptureKit helper, wincap.swift, is compiled on first use; on
;; Windows ffmpeg captures the window (untested).  Encoding needs ffmpeg.
;;
;; The demo Emacs never writes your state: session, recent files, history,
;; places and the like go to the work directory, and it quits without
;; running `kill-emacs-hook'.  It is only ever force-killed, never killed
;; normally, since a normal kill runs that hook too.
;;
;; A scenario file calls `impro-setup', opens its document with
;; `impro-open', then `impro-play' with a list of steps:
;;
;;   (caption "TEXT" [SECS])   show TEXT in the mode line
;;   (goto "TEXT" [SECS])      put point at the start of TEXT in the document
;;   (keys "C-c w ;" [SECS])   press a key sequence (kbd syntax)
;;   (type "words" [PER-KEY])  type characters one by one
;;   (wait SECS)               pause
;;   (eval FORM [SECS])        run FORM in the document buffer
;;   (end [SECS])              hold the last frame, then quit Emacs
;;
;; SECS is how long to wait before the next step.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(defgroup impro nil
  "Scripted, re-recordable demos of Emacs packages."
  :group 'tools)

(defcustom impro-emacs nil
  "Emacs binary that plays the demo; nil means the one running now."
  :type '(choice (const nil) file))

(defcustom impro-clean nil
  "Non-nil runs the demo Emacs with `-Q' instead of your config."
  :type 'boolean)

(defcustom impro-max-seconds 300
  "Stop a take that runs longer than this."
  :type 'number)

(defcustom impro-gif-width 960
  "Width of the GIF in pixels; the MP4 keeps full resolution."
  :type 'integer)

(defcustom impro-gif-fps 12
  "Frames per second of the GIF."
  :type 'integer)

(defcustom impro-ffmpeg-program "ffmpeg"
  "The ffmpeg program."
  :type 'string)

(defcustom impro-directory (locate-user-emacs-file "impro/")
  "Where `impro-new' and `impro-draft' puts scenarios: DIR/PACKAGE/PACKAGE-demo.el.
Takes and the package's demo state go beside each one."
  :type 'directory)

(defcustom impro-wincap-program (locate-user-emacs-file "impro/wincap")
  "Where wincap.swift gets compiled to."
  :type 'file)

(defconst impro--dir (file-name-directory (or load-file-name buffer-file-name))
  "Where impro.el and wincap.swift live.")

;;; Recording (runs in your Emacs)

(defcustom impro-recorder 'auto
  "How a take records the demo window; `auto' picks by system.
`frames'  the demo Emacs saves its own frames: needs an Emacs built
          with Cairo (most Linux builds; X11 or Wayland, and headless
          under Xvfb).  Nothing else on screen can show up.
`wincap'  macOS: a ScreenCaptureKit helper compiled from wincap.swift
          (needs the Xcode command line tools).  Window-only too.
`gdigrab' Windows: ffmpeg captures the window by its title.  Untested,
          and windows covering the demo may show up in the video."
  :type '(choice (const auto) (const frames) (const wincap) (const gdigrab)))

(defcustom impro-frame-rate 12
  "Most frames per second the `frames' recorder saves."
  :type 'integer)

(defun impro--recorder ()
  "The recorder takes use on this system."
  (if (not (eq impro-recorder 'auto)) impro-recorder
    (pcase system-type ('darwin 'wincap) ('windows-nt 'gdigrab) (_ 'frames))))

;; A take runs the demo Emacs and, for `wincap' and `gdigrab', a capture
;; process.  They talk through files in the work directory: the demo Emacs
;; writes `ready' (holding its frame's title) once its frame has settled;
;; the capture process starts; then we write `go' and the demo plays.
;; With `frames', the demo Emacs captures itself into frames/ and lists
;; them, with times, in frames.log.  It also writes `log' (the steps) and,
;; if a step fails, `error'.

(cl-defstruct (impro--take (:constructor impro--take-create))
  scenario out rehearse recorder work callback notes
  emacs capturer watchdog
  emacs-ok captured done)

(defvar impro--current nil "The take in progress, if any.")

(defun impro--take-file (take name)
  "Path of NAME in TAKE's work directory."
  (expand-file-name name (impro--take-work take)))

(defun impro--take-read (take name)
  "Contents of NAME in TAKE's work directory, or nil."
  (let ((file (impro--take-file take name)))
    (when (file-exists-p file)
      (with-temp-buffer (insert-file-contents file) (string-trim (buffer-string))))))

(defun impro--process (name command then)
  "Run COMMAND as NAME; call THEN with nil on success, else an error string."
  (let ((buf (generate-new-buffer (format " *impro %s*" name))))
    (make-process
     :name (concat "impro-" name) :buffer buf :command command
     :connection-type 'pipe :noquery t
     :sentinel
     (lambda (proc _)
       (unless (process-live-p proc)
         (let ((out (with-current-buffer buf (string-trim (buffer-string)))))
           (kill-buffer buf)
           (funcall then
                    (unless (and (eq (process-status proc) 'exit)
                                 (zerop (process-exit-status proc)))
                      (format "%s failed (%s)%s" name (process-exit-status proc)
                              (if (string-empty-p out) "" (concat ":\n" out)))))))))))

(defun impro--wait-for (take pred secs then else)
  "Call THEN once PRED holds, checking every 0.2s; call ELSE after SECS.
Stop checking once TAKE is over."
  (unless (impro--take-done take)
    (cond ((funcall pred) (funcall then))
          ((<= secs 0) (funcall else))
          (t (run-at-time 0.2 nil #'impro--wait-for take pred (- secs 0.2) then else)))))

(defun impro--finish (take err)
  "End TAKE with ERR (nil on success): kill what's left, clean up, report."
  (unless (impro--take-done take)
    (setf (impro--take-done take) t)
    (when (eq impro--current take) (setq impro--current nil))
    (when (impro--take-watchdog take) (cancel-timer (impro--take-watchdog take)))
    ;; Only ever SIGKILL the demo Emacs: see `impro--quit'.
    (dolist (proc (list (impro--take-emacs take) (impro--take-capturer take)))
      (when (process-live-p proc) (signal-process proc 'SIGKILL)))
    (let ((log (concat (impro--take-notes take) (impro--take-read take "log"))))
      (delete-directory (impro--take-work take) t)
      (funcall (impro--take-callback take) take err log))))

(defun impro--ensure-wincap (then)
  "Compile wincap.swift if needed, then call THEN with nil or an error."
  (let ((src (expand-file-name "wincap.swift" impro--dir))
        (bin (expand-file-name impro-wincap-program)))
    (if (and (file-executable-p bin)
             (not (file-newer-than-file-p src bin)))
        (funcall then nil)
      (make-directory (file-name-directory bin) t)
      (message "impro: compiling wincap...")
      (impro--process "swiftc" (list "swiftc" "-O" "-swift-version" "5"
                                     "-o" bin src)
                      (lambda (err)
                        (funcall then (and err (concat "Building wincap needs the Xcode "
                                                       "command line tools.  " err))))))))

(defun impro--run-emacs (take)
  "Start TAKE's demo Emacs, and the watchdog that stops a stuck one."
  (setf (impro--take-emacs take)
        (impro--process
         "emacs"
         `(,(or impro-emacs (expand-file-name invocation-name invocation-directory))
           ,@(and impro-clean '("-Q"))
           "-l" ,(expand-file-name "impro" impro--dir)
           "--eval" ,(format "%S" `(impro--child-start
                                    ,(impro--take-scenario take) ,(impro--take-work take)
                                    ',(impro--take-recorder take) ,impro-frame-rate)))
         (lambda (err) (impro--emacs-exited take err))))
  (setf (impro--take-watchdog take)
        (run-at-time impro-max-seconds nil #'impro--finish take
                     (format "The demo didn't finish within %ss" impro-max-seconds))))

(defun impro--go (take)
  "Tell TAKE's demo Emacs to start playing."
  (write-region "" nil (impro--take-file take "go") nil 'silent))

(defun impro--start-capture (take)
  "Start recording TAKE's demo window, then say `go'."
  (pcase (impro--take-recorder take)
    ('frames
     ;; The demo Emacs records itself once it plays.
     (setf (impro--take-captured take) t)
     (impro--go take))
    ('wincap
     (impro--run-capturer
      take (list (expand-file-name impro-wincap-program)
                 (number-to-string (process-id (impro--take-emacs take)))
                 (impro--take-file take "raw.mov")
                 (impro--take-file take "capturing"))
      (lambda () (file-exists-p (impro--take-file take "capturing")))
      (concat "If it's a permission problem, allow Screen Recording for the app "
              "running Emacs (System Settings > Privacy & Security > Screen Recording).")))
    ('gdigrab
     (let ((raw (impro--take-file take "raw.mkv")))
       (impro--run-capturer
        take (list impro-ffmpeg-program "-hide_banner" "-loglevel" "error" "-y"
                   "-f" "gdigrab" "-framerate" "30" "-draw_mouse" "0"
                   "-i" (concat "title=" (impro--take-read take "ready")) raw)
        (lambda () (> (or (file-attribute-size (file-attributes raw)) 0) 0))
        "ffmpeg didn't find the demo window by its title.")))))

(defun impro--run-capturer (take command started-p hint)
  "Run TAKE's capture COMMAND; say `go' once STARTED-P, else fail with HINT."
  (setf (impro--take-capturer take)
        (impro--process "capture" command
                        (lambda (err) (impro--capturer-exited take err))))
  (impro--wait-for take started-p 10
                   (lambda () (impro--go take))
                   (lambda () (impro--finish take (concat "Window capture didn't start.  " hint)))))

(defun impro--stop-capturer (take)
  "Ask TAKE's capture process to finish its file."
  (let ((proc (impro--take-capturer take)))
    (if (eq (impro--take-recorder take) 'wincap)
        (signal-process proc 'SIGTERM)
      (process-send-string proc "q"))))   ; ffmpeg: stop and close the file

;; The demo window closing stops wincap by itself, so the two processes
;; exit in either order; whichever exits second starts the encoding.

(defun impro--emacs-exited (take err)
  "The demo Emacs of TAKE exited, with ERR if it failed."
  (cond ((or (impro--take-read take "error") err)
         (impro--finish take (or (impro--take-read take "error") err)))
        ((impro--take-rehearse take) (impro--finish take nil))
        (t (setf (impro--take-emacs-ok take) t)
           (cond ((impro--take-captured take) (impro--encode take))
                 ((process-live-p (impro--take-capturer take))
                  (impro--stop-capturer take))))))

(defun impro--capturer-exited (take err)
  "The capture process of TAKE exited, with ERR if it failed."
  (if err (impro--finish take err)
    (setf (impro--take-captured take) t)
    (when (impro--take-emacs-ok take) (impro--encode take))))

(defun impro--frames-input (take)
  "ffmpeg input arguments for TAKE's saved frames, each shown until the next.
Writes frames.ffconcat from frames.log (\"SECONDS FILE\" lines, then
\"SECONDS END\"); frames are only saved when the picture changes."
  (let* ((entries (mapcar (lambda (line)
                            (pcase-let ((`(,secs ,file) (split-string line " ")))
                              (cons (string-to-number secs) file)))
                          (split-string (or (impro--take-read take "frames.log") "") "\n" t)))
         (last nil))
    (with-temp-file (impro--take-file take "frames.ffconcat")
      (insert "ffconcat version 1.0\n")
      (cl-loop for (this next) on entries
               while next
               do (insert (format "file '%s'\nduration %.3f\n"
                                  (cdr this) (- (car next) (car this))))
                  (setq last (cdr this)))
      ;; ffmpeg ignores the last duration unless the last file follows it.
      (when last (insert (format "file '%s'\n" last))))
    (unless last (error "No frames were captured"))
    (list "-f" "concat" "-safe" "0" "-i" (impro--take-file take "frames.ffconcat"))))

(defun impro--encode (take)
  "Turn TAKE's capture into OUT.mp4 and OUT.gif."
  (let ((mp4 (concat (impro--take-out take) ".mp4"))
        (gif (concat (impro--take-out take) ".gif"))
        (ffmpeg (list impro-ffmpeg-program "-hide_banner" "-loglevel" "error" "-y")))
    (condition-case err
        (let ((input (pcase (impro--take-recorder take)
                       ('frames (impro--frames-input take))
                       ('wincap (list "-i" (impro--take-file take "raw.mov")))
                       ('gdigrab (list "-i" (impro--take-file take "raw.mkv"))))))
          (make-directory (file-name-directory mp4) t)
          (impro--process
           "ffmpeg" `(,@ffmpeg ,@input "-vf" "fps=30,pad=ceil(iw/2)*2:ceil(ih/2)*2"
                               "-c:v" "libx264" "-pix_fmt" "yuv420p" "-crf" "20"
                               "-movflags" "+faststart" ,mp4)
           (lambda (err)
             (if err (impro--finish take err)
               (impro--process
                "ffmpeg" `(,@ffmpeg "-i" ,mp4 "-vf"
                                    ,(format "fps=%d,scale=%d:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
                                             impro-gif-fps impro-gif-width)
                                    ,gif)
                (lambda (err) (impro--finish take err)))))))
      (error (impro--finish take (error-message-string err))))))

;;; Checking a scenario (nothing in it is evaluated)

(defconst impro--step-args
  '((caption stringp &optional numberp) (goto stringp &optional numberp)
    (keys stringp &optional numberp) (type stringp &optional numberp)
    (wait numberp) (eval always &optional numberp) (end &optional numberp))
  "Each step's arguments, as predicates.")

(defun impro--args-ok-p (spec args)
  "Non-nil if ARGS match SPEC, a list of predicates with maybe `&optional'."
  (let (optional)
    (catch 'bad
      (dolist (pred spec)
        (cond ((eq pred '&optional) (setq optional t))
              (args (unless (funcall pred (pop args)) (throw 'bad nil)))
              ((not optional) (throw 'bad nil))))
      (null args))))

(defun impro--find-call (fn form)
  "The first (FN ...) call inside FORM, or nil."
  (cond ((and (consp form) (eq (car form) fn)) form)
        ((consp form) (or (impro--find-call fn (car form))
                          (impro--find-call fn (cdr form))))))

(defun impro--lint (source)
  "Problems in scenario SOURCE (its text), without evaluating any of it.
A list of (LEVEL . MESSAGE), LEVEL being `error', `warning' or `info'.
Catches what would otherwise fail minutes into a rehearsal: malformed
steps, `goto' text that isn't in the document, invalid keys, no `end'.
Whether keys are bound is checked when playing (`impro--note-undefined')."
  (let (problems forms)
    (cl-flet ((add (level fmt &rest args)
                (push (cons level (apply #'format fmt args)) problems)))
	     (condition-case err
		 (with-temp-buffer
		   (with-syntax-table emacs-lisp-mode-syntax-table
		     (insert source)
		     (goto-char (point-min))
		     (while (progn (forward-comment (buffer-size)) (not (eobp)))
                       (push (read (current-buffer)) forms))))
               (error (add 'error "Can't read the scenario: %s" (error-message-string err))
		      (setq forms :unreadable)))
	     (unless (eq forms :unreadable)
	       (let* ((open (impro--find-call 'impro-open forms))
		      (play (impro--find-call 'impro-play forms))
		      (doc (and (stringp (nth 2 open)) (nth 2 open)))
		      (steps (pcase (nth 1 play) (`(quote ,steps) steps)))
		      (typed (mapconcat (lambda (s) (if (eq (car-safe s) 'type) (format "%s" (cadr s)) ""))
					steps "\n"))
		      (secs 1))
		 (cond ((not open) (add 'error "No (impro-open NAME TEXT) call"))
		       ((not doc) (add 'warning "The document isn't a string literal: `goto' steps aren't checked")))
		 (cond ((not play) (add 'error "No (impro-play '(STEPS...)) call"))
		       ((not (consp steps)) (add 'warning "The steps aren't a quoted list: they aren't checked")))
		 (dolist (step (and (consp steps) steps))
		   (let ((spec (alist-get (car-safe step) impro--step-args)))
		     (cond
		      ((not spec) (add 'error "Unknown step %S" step))
		      ((not (impro--args-ok-p spec (cdr step)))
		       (add 'error "Malformed step %S (see the step list in impro.el)" step))
		      (t
		       (pcase step
			 (`(goto ,text . ,_)
			  (unless (or (not doc) (string-search text doc) (string-search text typed))
			    (add 'warning "%S: not in the document (fine if an earlier step adds it)" step)))
			 (`(keys ,keys . ,_)
			  (unless (key-valid-p keys)
			    (add 'error "%S: not a valid key sequence (kbd syntax: \"C-c w ;\")" step))))
		       (cl-incf secs (pcase step
				       (`(wait ,s) s)
				       (`(type ,text . ,d) (* (length text) (impro--secs 'type d)))
				       ;; SECS, when given, is the last argument.
				       (_ (let ((n (car (last step))))
					    (if (numberp n) n (impro--secs (car step) nil))))))))))
		 (when (and (consp steps) (not (eq (car-safe (car (last steps))) 'end)))
		   (add 'error "The last step isn't (end): the demo would never quit"))
		 ;; ponytail: a name match, not a proof; it only nudges toward faking.
		 (when (and (string-match-p "gptel\\|\\_<llm\\|url-retrieve\\|\\_<plz\\_>\\|\\_<request\\_>" source)
			    (not (string-match-p "advice-add" source)))
		   (add 'warning "It mentions a network or model library but fakes nothing (advice-add): the demo may send real requests"))
		 (when (consp steps)
		   (add (if (> secs 150) 'warning 'info) "Runs about %ds, %d steps%s"
			secs (length steps) (if (> secs 150) "; aim for 2 minutes at most" ""))))))
    (nreverse problems)))

(defun impro--format-problems (problems)
  "PROBLEMS from `impro--lint', one per line."
  (mapconcat (lambda (p) (format "%s: %s" (car p) (cdr p))) problems "\n"))

(defun impro--file-string (file)
  "FILE's text, from its buffer if it's being edited."
  (if-let* ((buf (find-buffer-visiting file)))
      (with-current-buffer buf (buffer-string))
    (with-temp-buffer (insert-file-contents file) (buffer-string))))

;;;###autoload
(defun impro-lint (scenario)
  "Check SCENARIO without playing it (unsaved edits included)."
  (interactive (list (impro--read-scenario)))
  (let ((problems (impro--lint (impro--file-string scenario))))
    (with-current-buffer (get-buffer-create "*impro*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Checked %s\n\n%s\n" scenario (impro--format-problems problems))))
      (special-mode)
      (display-buffer (current-buffer)))
    problems))

(defun impro--start (scenario out rehearse callback)
  "Play SCENARIO; unless REHEARSE, record it to OUT.mp4 and OUT.gif.
Call CALLBACK with the take, an error string or nil, and the step log."
  (when impro--current
    (user-error "A take is already running (M-x impro-abort stops it)"))
  (unless (or rehearse (executable-find impro-ffmpeg-program))
    (user-error "Recording needs ffmpeg (see M-x impro-doctor)"))
  (let* ((problems (seq-remove (lambda (p) (eq (car p) 'info))
                               (impro--lint (impro--file-string scenario))))
         (take (impro--take-create
               :scenario (expand-file-name scenario)
               :out (and out (expand-file-name out)) :rehearse rehearse
               :recorder (and (not rehearse) (impro--recorder))
               :work (file-name-as-directory (make-temp-file "impro-" t))
               :callback callback
               :notes (and problems (concat (impro--format-problems problems) "

")))))
    (when (assq 'error problems)
      (delete-directory (impro--take-work take) t)
      (user-error "Scenario problems:
%s" (impro--format-problems problems)))
    (setq impro--current take)
    (if rehearse
        (progn (impro--go take) (impro--run-emacs take))
      (funcall
       (if (eq (impro--take-recorder take) 'wincap) #'impro--ensure-wincap
         (lambda (then) (funcall then nil)))
       (lambda (err)
         (if err (impro--finish take err)
           (impro--run-emacs take)
           (impro--wait-for
            take (lambda () (file-exists-p (impro--take-file take "ready")))
            impro-max-seconds             ; a slow config is fine; the watchdog bounds it
            (lambda () (impro--start-capture take))
            (lambda () (impro--finish take "Emacs didn't start the demo")))))))
    take))

(defun impro--report (take err log)
  "Show how TAKE went: ERR, or where the files are; the step LOG if useful."
  (if (not (or err (impro--take-rehearse take)))
      (message "impro: wrote %s.mp4 and .gif" (impro--take-out take))
    (with-current-buffer (get-buffer-create "*impro*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (if err (format "Failed: %s\n\n" err) "Rehearsal finished.\n\n")
                (or log "")))
      (special-mode)
      (display-buffer (current-buffer)))
    (message "impro: %s" (or err "rehearsal finished"))))

(defun impro--read-scenario ()
  "Ask for a scenario file, defaulting to the current one."
  (read-file-name "Scenario: " nil nil t
                  (and buffer-file-name (file-name-nondirectory buffer-file-name))))

;;;###autoload
(defun impro-rehearse (scenario)
  "Play SCENARIO without recording, then show the step log."
  (interactive (list (impro--read-scenario)))
  (impro--start scenario nil t #'impro--report))

;;;###autoload
(defun impro-record (scenario out)
  "Record SCENARIO to OUT.mp4 and OUT.gif, in the background."
  (interactive
   (let ((scenario (impro--read-scenario)))
     (list scenario (read-file-name "Output (no extension): "
                                    (file-name-directory scenario) nil nil
                                    (file-name-base scenario)))))
  (impro--start scenario out nil #'impro--report))

(defun impro-abort ()
  "Stop the take in progress."
  (interactive)
  (if impro--current (impro--finish impro--current "aborted")
    (message "impro: no take running")))

(defun impro-batch ()
  "Record or rehearse from the command line; see the Commentary."
  (let* ((rehearse (member "--rehearse" command-line-args-left))
         (args (remove "--rehearse" command-line-args-left))
         result)
    (setq command-line-args-left nil)
    (when (equal (car args) "--doctor")
      (pcase-let ((`(,text . ,ok) (impro--doctor-report)))
        (princ (concat text "\n"))
        (kill-emacs (if ok 0 1))))
    (when (equal (cadr args) "--lint")
      (let ((problems (impro--lint (impro--file-string (car args)))))
        (princ (concat (impro--format-problems problems) "
"))
        (kill-emacs (if (assq 'error problems) 1 0))))
    (unless (and args (or rehearse (cadr args)))
      (error "Usage: emacs --batch -l impro.el -f impro-batch {SCENARIO.el {OUT | --rehearse | --lint} | --doctor}"))
    (impro--start (car args) (cadr args) rehearse
                  (lambda (take err log) (setq result (list take err log))))
    (while (not result) (accept-process-output nil 0.2))
    (pcase-let ((`(,take ,err ,log) result))
      (when (and log (or err rehearse)) (princ (concat log "\n")))
      (if err (message "impro: %s" err)
        (unless rehearse
          (message "Wrote %s.mp4 and %s.gif" (impro--take-out take) (impro--take-out take))))
      (kill-emacs (if err 1 0)))))

;;; Setting up: checking the tools, starting a scenario

(defun impro--demo-emacs ()
  "The Emacs binary that plays demos."
  (or impro-emacs (expand-file-name invocation-name invocation-directory)))

(defun impro--doctor-checks ()
  "What takes need on this system: a list of (STATUS WHAT DETAIL).
STATUS is `ok', `fail' (takes can't record) or `note'."
  (let* ((recorder (impro--recorder))
         (emacs (impro--demo-emacs))
         (ffmpeg (executable-find impro-ffmpeg-program))
         (check (lambda (ok what good bad) (list (if ok 'ok 'fail) what (if ok good bad)))))
    (append
     (list
      (funcall check (version<= "29.1" emacs-version) "Emacs 29.1 or newer"
               emacs-version (format "%s: impro needs 29.1" emacs-version))
      (funcall check (file-executable-p emacs) "Demo Emacs" emacs
               (format "%s isn't executable: set `impro-emacs'" emacs))
      (funcall check ffmpeg "ffmpeg, to encode the MP4 and GIF" ffmpeg
               (pcase system-type
                 ('darwin "missing: brew install ffmpeg")
                 ('windows-nt "missing: winget install ffmpeg (then restart Emacs)")
                 (_ "missing: install ffmpeg with your package manager")))
      (list 'note "Recorder" (format "%s%s" recorder (if (eq impro-recorder 'auto) " (auto)" ""))))
     (pcase recorder
       ('frames
        (let ((cairo (equal "t" (and (file-executable-p emacs)
                                     (car (process-lines-ignore-status
                                           emacs "-Q" "--batch" "--eval"
                                           "(princ (and (featurep 'cairo) (fboundp 'x-export-frames)))")))))
              (display (or (getenv "WAYLAND_DISPLAY") (getenv "DISPLAY"))))
          (list (funcall check cairo "Demo Emacs is built with Cairo (records itself)" "yes"
                         "no: use a Cairo build (most Linux GTK builds, e.g. Debian's emacs-gtk), or set `impro-emacs' to one")
                (funcall check display "A display for the demo window" display
                         "none: run in a graphical session, or headless under Xvfb (see the README)"))))
       ('wincap
        (let ((built (file-executable-p (expand-file-name impro-wincap-program)))
              (swiftc (executable-find "swiftc")))
          (list (funcall check (or built swiftc) "wincap, the window recorder"
                         (if built "built" "compiled on the first recording")
                         "can't be built: xcode-select --install (the Xcode command line tools)")
                (list 'note "Screen Recording permission"
                      "macOS asks on the first recording; it's granted to the app running Emacs"))))
       ('gdigrab
        (list (funcall check (and ffmpeg (string-match-p
                                          "gdigrab" (shell-command-to-string
                                                     (format "%s -hide_banner -devices"
                                                             (shell-quote-argument ffmpeg)))))
                       "ffmpeg's gdigrab (window capture)" "yes" "this ffmpeg has no gdigrab")
              (list 'note "Windows recording is untested"
                    "windows covering the demo may show up in the video")))
       (_ (list (list 'fail "Recorder" (format "unknown recorder %S" recorder)))))
     (list
      (list 'note "keycast (optional)"
            (if (locate-library "keycast") "installed" "not installed: the built-in key display is used"))
      (list 'note "gptel (optional, for M-x impro-draft)"
            (if (locate-library "gptel") "installed" "not installed"))))))

(defun impro--doctor-report ()
  "The doctor's checks as text, and whether takes can record: (TEXT . OK)."
  (let ((checks (impro--doctor-checks)))
    (cons (mapconcat (lambda (c)
                       (pcase-let ((`(,status ,what ,detail) c))
                         (format "%s %-50s %s" (pcase status ('ok "✓") ('fail "✗") (_ "·"))
                                 what detail)))
                     checks "\n")
          (not (assq 'fail checks)))))

;;;###autoload
(defun impro-doctor ()
  "Check that this system can record demos, and how to fix what's missing."
  (interactive)
  (pcase-let ((`(,text . ,ok) (impro--doctor-report)))
    (with-current-buffer (get-buffer-create "*impro doctor*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text "\n\n" (if ok "Ready to record." "Fix the ✗ lines to record (rehearsing works anyway).") "\n"))
      (special-mode)
      (display-buffer (current-buffer)))
    ok))

(defconst impro--template "\
;;; {{PKG}}-demo.el --- impro scenario for {{PKG}} -*- lexical-binding: t; -*-

;; M-x impro-lint, then M-x impro-rehearse, then M-x impro-record.
;; Steps: (caption \"TEXT\" [SECS])  (goto \"TEXT\" [SECS])  (keys \"C-c x\" [SECS])
;;        (type \"words\" [PER-KEY])  (wait SECS)  (eval FORM [SECS])  (end [SECS])
;; SECS is how long to wait before the next step.

;;; Code:

(impro-setup :columns 100 :lines 30 :font-size 16)   ; or :maximized t

;; The package from its working tree, even if your config loads another copy.
(load \"{{MAIN}}\" nil t)

;; Keep the package's own state files out of yours, e.g.:
;; (setq {{PKG}}-directory (expand-file-name \"state/\" (file-name-directory load-file-name)))

;; A demo must never reach the network or a model.  Load the real library,
;; then replace its request function with fixed replies after a fixed delay:
;; (require 'gptel nil t)
;; (advice-add 'gptel-request :override
;;             (lambda (_prompt &rest args)
;;               (run-at-time 1.0 nil (plist-get args :callback) \"A canned reply.\" nil)))

;; The document the demo works in.  Every `goto' text must appear in it.
(impro-open \"notes.org\" \"#+title: Notes

* A heading
Some text for the demo to work on.  Write a real-length document:
fill the window, and give every feature something to act on.
\" #'org-mode)

(impro-play
 '((caption \"{{PKG}}: what it does, in one line\" 3)

   (caption \"The first feature — C-c …\" 1)
   (goto \"Some text\" 1)
   ;; (keys \"C-c …\" 2)

   (caption \"{{PKG}} — where to get it\" 3)
   (end 1.5)))

;;; {{PKG}}-demo.el ends here
"
  "What `impro-new' writes.")

;;;###autoload
(defun impro-new (package-dir)
  "Start a scenario for the package in PACKAGE-DIR, and open it.
Writes `impro-directory'/PACKAGE/PACKAGE-demo.el from a template that
loads the package from PACKAGE-DIR; opens it as is if it exists.
`impro-draft' writes one from the package's README instead."
  (interactive (list (read-directory-name "Package directory: ")))
  (let* ((dir (file-name-as-directory (expand-file-name package-dir)))
         (pkg (string-remove-suffix ".el" (file-name-nondirectory (directory-file-name dir))))
         (main (or (seq-find #'file-exists-p (list (expand-file-name (concat pkg ".el") dir)))
                   (car (directory-files dir t "\\.el\\'"))
                   (expand-file-name (concat pkg ".el") dir)))
         (file (expand-file-name (format "%s/%s-demo.el" pkg pkg) impro-directory)))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert (string-replace "{{MAIN}}" (abbreviate-file-name main)
                                (string-replace "{{PKG}}" pkg impro--template)))))
    (find-file file)
    file))

;;; Drafting a scenario from a README (optional: needs gptel)

(defconst impro--draft-rules "\
You write demo scenarios for impro: it plays a scripted demo of an Emacs \
package in a real Emacs and records it as a video for the package's README.

A scenario is an Emacs Lisp file, shaped like this:

  (impro-setup :maximized t :font-size 16)
  (load \"MAIN-FILE\" nil t)          ; the package from its working tree
  ;; Settings; point the package's state files into this folder:
  ;; (expand-file-name \"state/\" (file-name-directory load-file-name))
  (impro-open \"NAME.org\" \"DOCUMENT TEXT\" #'org-mode)
  (PACKAGE-mode 1)                  ; whatever turns the package on
  (impro-play
   '((caption \"PACKAGE: what it is for, in one line\" 3.5)
     (caption \"Cycle in place — C-c w ]\" 1)
     (goto \"tension\" 1)
     (keys \"C-c w ]\" 1.6)
     ...
     (end 1.5)))

Steps (SECS is how long to wait before the next step):
  (caption \"TEXT\" [SECS])   show TEXT in the mode line
  (goto \"TEXT\" [SECS])      put point at the first match of TEXT in the document
  (keys \"C-c w ;\" [SECS])   press keys (kbd syntax); they go through the real command loop
  (type \"words\" [PER-KEY])  type characters one by one
  (wait SECS)               pause
  (eval FORM [SECS])        run FORM in the document buffer
  (end [SECS])              hold the last frame, then quit; always the last step

Rules:
- Show the main features in the order a new user needs them; one idea per \
caption; about 2 minutes in all.
- Each caption names the feature and its keys, like \"Cycle in place — C-c w ]\".
- Use only key bindings shown in the README or the source excerpt. Keys \
meant for a prompt or a menu simply follow the keys that opened it.
- Write an original document of real length that fills the window and gives \
every feature something to act on. Every goto TEXT must appear in it exactly.
- Give menus, panels and replies time to be read (2-4 s), and pause about \
1.5 s on a highlighted option before RET.
- Never let the demo reach a network or a model: (require 'LIB nil t), then \
advice-add the request function :override with a function that answers with \
fixed text after a fixed delay (run-at-time). Never a plain defun stub.
- Output only the Emacs Lisp file, with no explanation and no Markdown."
  "System prompt for `impro-draft'.")

(defun impro--source-keys (file)
  "Lines of FILE that look like key bindings."
  (with-temp-buffer
    (insert-file-contents file)
    (let (lines)
      (while (re-search-forward
              (concat "^.*\\(define-key\\|keymap-set\\|defvar-keymap\\|global-set-key\\).*$"
                      ;; A `defvar-keymap' body line: "KEY" #'command, or "KEY" some-map.
                      "\\|^[ \t]+\"[^\"\n]+\"[ \t]+\\(#'\\)?[[:alnum:]-]+)*[ \t]*$")
              nil t)
        (push (match-string 0) lines))
      (string-join (nreverse lines) "\n"))))

(declare-function gptel-request "ext:gptel")

;;;###autoload
(defun impro-draft (package-dir)
  "Draft a scenario for the package in PACKAGE-DIR, from its README.
Asks the model through gptel, puts the draft in a buffer for you to
review (not saved), and checks it with `impro-lint'.  Nothing is played."
  (interactive (list (read-directory-name "Package directory: ")))
  (unless (require 'gptel nil t) (user-error "impro-draft needs gptel"))
  (let* ((dir (file-name-as-directory (expand-file-name package-dir)))
         (pkg (string-remove-suffix ".el" (file-name-nondirectory (directory-file-name dir))))
         (readme (let ((case-fold-search t))
                   (seq-find (lambda (f) (string-match-p "\\`readme\\(\\.\\(md\\|org\\|txt\\)\\)?\\'"
                                                         (file-name-nondirectory f)))
                             (directory-files dir t))))
         (main (seq-find #'file-exists-p (list (expand-file-name (concat pkg ".el") dir)
                                               (car (directory-files dir t "\\.el\\'")))))
         (file (expand-file-name (format "%s/%s-demo.el" pkg pkg) impro-directory)))
    (unless readme (user-error "No README in %s" dir))
    (message "impro: drafting a scenario for %s..." pkg)
    (gptel-request
        (concat (format "Package: %s\nMain file: %s\n\nREADME:\n" pkg (or main "unknown"))
                ;; ponytail: whole README, capped; summarize first if models choke.
                (truncate-string-to-width (impro--file-string readme) 60000)
                (and main (format "\n\nKey bindings in %s:\n%s"
                                  (file-name-nondirectory main) (impro--source-keys main))))
      :system impro--draft-rules
      :callback
      (lambda (response info)
        (cond
         ((null response)
          (message "impro: drafting failed: %s" (plist-get info :status)))
         ((stringp response)
          (make-directory (file-name-directory file) t)
          (with-current-buffer (find-file-noselect file)
            (erase-buffer)              ; undoable, and nothing is saved
            (insert (if (string-match "```[a-z-]*\n\\(\\(?:.\\|\n\\)*?\\)```" response)
                        (match-string 1 response)
                      response))
            (goto-char (point-min))
            (pop-to-buffer (current-buffer))
            (let ((problems (impro--lint (buffer-string))))
              (message "impro: draft ready, not saved.  %s"
                       (impro--format-problems problems))))))))))

;;; Playing (runs in the demo Emacs)

(defvar impro--work nil "Work directory shared with the recorder.")
(defvar impro--steps nil "Steps still to play.")
(defvar impro--buffer nil "The document buffer being demonstrated.")
(defvar impro--caption "" "Caption shown in the mode line.")
(defvar impro--keys nil "Recent (KEYS . COMMAND) pairs, newest first.")
(defvar impro--t0 nil "When playback started.")
(defvar impro--size nil "Requested frame size: (COLUMNS . LINES), or `maximized'.")
(defvar impro--recording nil "The recorder of this take (see `impro-recorder'), or nil.")

(defface impro-caption '((t :weight bold))
  "Face for demo captions.")

;;; Keeping the user's state out of it

(defun impro--state-dir ()
  "Where the demo Emacs keeps the state it would otherwise share with you."
  (let ((dir (expand-file-name "state/" (or impro--work temporary-file-directory))))
    (make-directory dir t)
    dir))

(defvar persp-auto-save-opt)
(defvar company-global-modes)
(defvar global-corfu-modes)

(defun impro--isolate ()
  "Point session, history and cache files into the work directory.
The demo runs with the user's config (e.g. Doom), which saves workspaces,
recent files, minibuffer history, places... into the user's directories.
Setting these before the packages that own them save keeps every write in
the demo's own folder."
  (let ((dir (impro--state-dir)))
    (dolist (var '((persp-save-dir . "workspaces/")
                   (recentf-save-file . "recentf")
                   (savehist-file . "savehist")
                   (save-place-file . "saveplace")
                   (bookmark-default-file . "bookmarks")
                   (transient-history-file . "transient-history.el")
                   (transient-levels-file . "transient-levels.el")
                   (transient-values-file . "transient-values.el")
                   (org-persist-directory . "org-persist/")
                   (undo-fu-session-directory . "undo-fu-session/")
                   (projectile-known-projects-file . "projectile-projects.eld")
                   (tramp-persistency-file-name . "tramp")
                   ;; shell-maker shells (chatgpt-shell, ...) save history here.
                   (shell-maker-root-path . "shell-maker/")))
      (set (car var) (expand-file-name (cdr var) dir))))
  (setq persp-auto-save-opt 0)        ; no workspace autosave at all
  (setq auto-save-list-file-prefix nil))

(defun impro--quit (code)
  "Quit with exit CODE, skipping `kill-emacs-hook'.
That hook is where configs save sessions and history, and where messages
like \"Wrote .../workspaces/autosave\" would land in the recording."
  (impro--capture-stop)
  (let ((kill-emacs-hook nil)
        (kill-emacs-query-functions nil))
    (kill-emacs code)))

;;; Keys and captions

(defun impro--caption-string ()
  "Mode-line text for the caption."
  (if (string-empty-p impro--caption) ""
    (concat (propertize (string-replace "%" "%%" impro--caption) 'face 'impro-caption)
            "     ")))

(defun impro--keys-string ()
  "Mode-line text for the last keys pressed, when keycast isn't installed."
  (mapconcat (lambda (k)
               (concat (propertize (car k) 'face 'keycast-key)
                       " " (propertize (truncate-string-to-width (cdr k) 28 nil nil "…")
                                       'face 'keycast-command)))
             (reverse impro--keys) "   "))

(defun impro--log-key ()
  "Remember the key just pressed (`pre-command-hook').
Typing shows itself; mouse and wheel events aren't part of the demo."
  (let* ((keys (this-command-keys-vector))
         (k (key-description keys)))
    (unless (or (string-empty-p k)
                ;; Also `org-self-insert-command' and friends.
                (and (symbolp this-command)
                     (string-suffix-p "self-insert-command" (symbol-name this-command)))
                (seq-some (lambda (e) (or (mouse-event-p e) (consp e))) keys))
      (push (cons k (if (symbolp this-command) (symbol-name this-command) ""))
            impro--keys)
      (setq impro--keys (seq-take impro--keys 2))
      (force-mode-line-update t))))

(defun impro--key-faces ()
  "Make the key display subtle: accent-colored keys, dim command names.
The caption uses the accent too, in bold."
  (let ((accent (face-foreground 'link nil t)))
    (set-face-attribute 'impro-caption nil :foreground accent :weight 'bold)
    (unless (facep 'keycast-key) (make-face 'keycast-key))
    (unless (facep 'keycast-command) (make-face 'keycast-command))
    (set-face-attribute 'keycast-key nil :inherit 'unspecified :box nil
                        :background 'unspecified :foreground accent
                        :weight 'bold :height 'unspecified)
    (set-face-attribute 'keycast-command nil :inherit 'shadow :box nil
                        :background 'unspecified :weight 'normal)))

(declare-function keycast--update "ext:keycast")
(declare-function keycast--minibuffer-exit "ext:keycast")
(defvar keycast-mode-line)

(defvar keycast-mode-line-window-predicate)

(defun impro--doc-window-p ()
  "Non-nil when the mode line being drawn is the demo document's."
  (eq (current-buffer) impro--buffer))

(defun impro--show-keys ()
  "Show the caption, then the keys, in the demo document's mode line.
Keys come from keycast if it loads, else a built-in segment.  Both go
through `global-mode-string', which doom-modeline and the default mode
line both show; `keycast-mode-line-mode' instead inserts itself at a
fixed spot that doom-modeline doesn't have."
  ;; A keycast that's installed but fails to load (e.g. a release needing
  ;; newer dependencies than the config pins) falls back to the built-in.
  (condition-case err (require 'keycast nil t)
    (error (impro--log "keycast didn't load (%s); using the built-in key display"
                      (error-message-string err))))
  (impro--key-faces)
  (if (featurep 'keycast)
      (progn
        ;; What `keycast-mode-line-mode' sets up, minus its own placement.
        (setq keycast-mode-line-window-predicate #'impro--doc-window-p)
        (add-hook 'post-command-hook #'keycast--update t)
        (add-hook 'minibuffer-exit-hook #'keycast--minibuffer-exit t)
        (add-to-list 'global-mode-string '("" keycast-mode-line " ")))
    (add-hook 'pre-command-hook #'impro--log-key)
    (add-to-list 'global-mode-string
                 '(:eval (when (impro--doc-window-p) (concat (impro--keys-string) " ")))))
  ;; The caption goes first, so it reads: caption, then the keys.
  (add-to-list 'global-mode-string
               '(:eval (when (impro--doc-window-p) (impro--caption-string)))))

;;; Frame

(cl-defun impro-setup (&key (columns 100) (lines 28) maximized (font-size 16) theme)
  "Prepare the frame: COLUMNS x LINES, or MAXIMIZED; font at FONT-SIZE px.
THEME, if given, replaces the current one; by default your own theme
\(e.g. Doom's) stays."
  (setq inhibit-startup-screen t
        ;; Completion popups are noise in a demo, and configs often turn
        ;; them on globally later (Doom: on the first keypress).
        company-global-modes nil
        global-corfu-modes nil
        ring-bell-function #'ignore
        use-short-answers t
        make-backup-files nil
        auto-save-default nil)
  (menu-bar-mode -1)
  ;; Not defined in builds without GUI support.
  (when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
  (when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
  (blink-cursor-mode -1)
  (when theme (load-theme theme t))
  (set-face-attribute 'default nil :height (* 10 font-size))
  (setq impro--size (if maximized 'maximized (cons columns lines)))
  (impro--size-frame)
  (impro--raise)
  (impro--show-keys))

(defun impro--size-frame ()
  "Leave native fullscreen, then apply the requested size or maximize.
Native fullscreen is left with `toggle-frame-fullscreen' (only when the
frame is in it, since it toggles): macOS then brings the window back to a
desktop Space and shows that Space, so the window is on screen to record."
  (pcase (frame-parameter nil 'fullscreen)
    ((or 'fullboth 'fullscreen) (toggle-frame-fullscreen))
    (state
     (if (eq impro--size 'maximized)
         (unless (eq state 'maximized) (set-frame-parameter nil 'fullscreen 'maximized))
       (when state (set-frame-parameter nil 'fullscreen nil))
       (set-frame-size nil (car impro--size) (cdr impro--size))
       (set-frame-position nil 60 80)))))

(defun impro--settled-p ()
  "Non-nil once the frame is out of native fullscreen at the requested size."
  (let ((state (frame-parameter nil 'fullscreen)))
    (if (eq impro--size 'maximized)
        (eq state 'maximized)
      (and (null state)
           (= (frame-width) (car impro--size))
           (= (frame-height) (cdr impro--size))))))

(defun impro--when-settled (then &optional tries)
  "Call THEN once the frame has settled; keep re-applying the size meanwhile.
On macOS, leaving fullscreen is animated and finishes some time later
\(and a config may have just started entering it), so check, not assume."
  (let ((tries (or tries 0)))
    (if (or (impro--settled-p) (>= tries 25))
        (progn (when (>= tries 25) (impro--log "frame didn't settle; recording anyway"))
               (run-at-time 0.6 nil then))   ; let a maximize animation finish
      (impro--size-frame)
      (run-at-time 0.3 nil #'impro--when-settled then (1+ tries)))))

(defun impro--raise ()
  "Bring the frame to the front, so you can watch it play.
The recording captures only this window (wincap), so it doesn't need to
stay on top."
  (select-frame-set-input-focus (selected-frame)))

(defun impro--log (fmt &rest args)
  "Append FMT with ARGS to the run log shared with the recorder."
  (when impro--work
    (let ((inhibit-message t))
      (write-region (concat (apply #'format fmt args) "\n") nil
                    (expand-file-name "log" impro--work) t 'silent))))

(defun impro-open (name text &optional mode)
  "Open a fresh file NAME holding TEXT, in MODE (default `text-mode')."
  (let ((file (expand-file-name name (or impro--work temporary-file-directory))))
    (with-temp-file file (insert text))
    (find-file file)
    (funcall (or mode #'text-mode))
    (visual-line-mode 1)
    ;; In-buffer completion popups and spell-check squiggles are noise here.
    (dolist (mode '(company-mode corfu-mode flyspell-mode spell-fu-mode))
      (when (and (boundp mode) (symbol-value mode))
        (funcall mode -1)))
    ;; And no completion sources at all, so nothing looks up words (or says
    ;; "Starting look process...") while the demo types.
    (setq-local completion-at-point-functions nil)
    (setq-local company-backends nil)
    (delete-other-windows)
    (goto-char (point-min))
    (message nil)                       ; clear the startup message
    (setq impro--buffer (current-buffer))))

;;; Playing

(defconst impro--step-secs
  '((caption . 1.5) (goto . 0.5) (keys . 0.9) (type . 0.07) (eval . 0.5) (end . 2))
  "Default SECS of each step (per key, for `type').")

(defun impro--secs (step d)
  "SECS given to STEP (its optional argument D), or its default."
  (or (car d) (alist-get step impro--step-secs)))

(defvar impro--undefined nil
  "Keys that ran no command during playback, or nil.")

(defvar impro--last-keys nil "The last `keys' step played.")

(defun impro--note-undefined ()
  "Remember keys that ran no command (`pre-command-hook').
That's always a scenario bug, and the rest of the keys would then type
into the document; `impro--next' fails the demo on it."
  (when (and impro--t0 (null this-command))
    (setq impro--undefined (format "%s… (from %S)"
                                   (key-description (this-command-keys-vector))
                                   impro--last-keys))))

(defun impro--step (step)
  "Do STEP; return seconds to wait before the next one, or nil to stop."
  (pcase step
    (`(caption ,text . ,d) (setq impro--caption text) (force-mode-line-update t) (impro--secs 'caption d))
    (`(goto ,text . ,d)
     (with-selected-window (get-buffer-window impro--buffer)
       (goto-char (point-min))
       (search-forward text)
       (goto-char (match-beginning 0)))
     (impro--secs 'goto d))
    (`(keys ,keys . ,d)
     (setq impro--last-keys step)
     (setq unread-command-events
           (append unread-command-events (listify-key-sequence (kbd keys))))
     (impro--secs 'keys d))
    (`(type ,text . ,d)
     (setq impro--steps (append (mapcar (lambda (c) `(char ,c ,(impro--secs 'type d))) text)
                               impro--steps))
     0)
    (`(char ,c ,d) (setq unread-command-events (append unread-command-events (list c))) d)
    (`(wait ,secs) secs)
    (`(eval ,form . ,d) (with-current-buffer impro--buffer (eval form t)) (impro--secs 'eval d))
    (`(end . ,d)
     (run-at-time (impro--secs 'end d) nil
                  (lambda ()
                    (when impro--work
                      (with-temp-file (expand-file-name "done" impro--work)))
                    (impro--quit 0)))
     nil)
    (_ (error "Unknown demo step: %S" step))))

(defun impro--next ()
  "Play the next step, then schedule the one after.
A failing step stops the demo and quits Emacs with an error, rather than
leaving a recording running forever."
  (when-let* ((step (pop impro--steps)))
    (unless (eq (car step) 'char) (impro--log "%.1fs %S" (float-time (time-since impro--t0)) step))
    (condition-case err
        (when-let* ((delay (if impro--undefined
                               (error "Unbound key %s"
                                      impro--undefined)
                             (impro--step step))))
          (run-at-time delay nil #'impro--next))
      (error
       (impro--log "ERROR in %S: %s\n--- document at the time ---\n%s"
                  step (error-message-string err)
                  (with-current-buffer impro--buffer (buffer-string)))
       (when impro--work
         (with-temp-file (expand-file-name "error" impro--work)
           (insert (format "Step %S failed: %s\n" step (error-message-string err)))))
       (impro--quit 1)))))

(defun impro--write-ready ()
  "Tell the recorder the frame is ready, and its title (to find the window)."
  (with-temp-file (expand-file-name "ready" impro--work)
    (insert (or (frame-parameter nil 'title) (frame-parameter nil 'name) ""))))

(defun impro--wait-for-go ()
  "Start playing once the recorder is recording (it creates the `go' file)."
  (if (file-exists-p (expand-file-name "go" impro--work))
      (progn (setq impro--t0 (current-time))
             (when (eq impro--recording 'frames) (impro--capture-start))
             (run-at-time 1 nil #'impro--next))
    (run-at-time 0.2 nil #'impro--wait-for-go)))

;;; Recording itself (the `frames' recorder)

;; An Emacs built with Cairo can render its own frame to a PNG.  That's
;; the demo window's own pixels, whatever covers it, on X11 or Wayland or
;; under Xvfb.  Frames are saved only when the picture changes, each with
;; the time it was taken; the recorder shows each one until the next.

(declare-function x-export-frames "xfns.c" (&optional frames type))

(defvar impro--frame-rate 12 "Most frames per second to save.")
(defvar impro--capture-timer nil "The timer saving frames, while recording.")
(defvar impro--capture-last nil "The last frame saved, as PNG data.")
(defvar impro--capture-count 0 "How many frames are saved.")

(defun impro--capture-note (what)
  "Add WHAT (a frame's file, or END) to frames.log, with the time now."
  (write-region (format "%.3f %s\n" (float-time) what) nil
                (expand-file-name "frames.log" impro--work) t 'silent))

(defun impro--capture ()
  "Save the demo frame if it changed since the last one saved."
  (let ((png (x-export-frames nil 'png)))
    (unless (equal png impro--capture-last)
      (setq impro--capture-last png)
      (let ((file (format "frames/%06d.png" (cl-incf impro--capture-count)))
            (coding-system-for-write 'binary))
        (write-region png nil (expand-file-name file impro--work) nil 'silent)
        (impro--capture-note file)))))

(defun impro--capture-start ()
  "Start saving frames."
  (make-directory (expand-file-name "frames" impro--work) t)
  (setq impro--capture-timer
        (run-at-time 0 (/ 1.0 impro--frame-rate) #'impro--capture)))

(defun impro--capture-stop ()
  "Stop saving frames, after a last one, and mark the end."
  (when impro--capture-timer
    (cancel-timer impro--capture-timer)
    (setq impro--capture-timer nil)
    (ignore-errors (impro--capture))
    (impro--capture-note "END")))

(defun impro--can-record-itself-p ()
  "Non-nil if this Emacs can save its own frames (a Cairo build)."
  (and (featurep 'cairo) (fboundp 'x-export-frames)))

(defun impro-play (steps)
  "Play STEPS once the frame has settled (and recording has started)."
  (setq impro--steps steps)
  (add-hook 'pre-command-hook #'impro--note-undefined)
  (run-at-time 1 nil
               (lambda ()
                 (impro--when-settled
                  (lambda ()
                    (impro--raise)
                    (redisplay t)
                    (if (not impro--work)
                        (progn (setq impro--t0 (current-time)) (impro--next))
                      (impro--write-ready)
                      (impro--wait-for-go)))))))

(defun impro--load-scenario (scenario)
  "Load SCENARIO; on error, report it to the recorder and quit."
  (condition-case err
      (load scenario nil t)
    (error
     (impro--log "ERROR loading %s: %s" scenario (error-message-string err))
     (when impro--work
       (with-temp-file (expand-file-name "error" impro--work)
         (insert (format "Loading the scenario failed: %s\n" (error-message-string err)))))
     (impro--quit 1))))

(defun impro--child-start (scenario &optional dir recorder frame-rate)
  "Load SCENARIO, sharing work directory DIR with the recorder.
RECORDER is how the take records (nil when rehearsing), FRAME-RATE the
`frames' recorder's most frames per second.
`--eval' runs before the startup hooks, where configs like Doom show their
dashboard and apply fonts and themes; so wait until startup is over, or
the config would undo the scenario's setup."
  (setq impro--work dir
        impro--recording recorder
        impro--frame-rate (or frame-rate impro--frame-rate))
  (when (and (eq recorder 'frames) (not (impro--can-record-itself-p)))
    (with-temp-file (expand-file-name "error" dir)
      (insert "This Emacs can't record itself: it isn't built with Cairo.  "
              "Use a Cairo build (most Linux GTK builds are; see M-x impro-doctor), "
              "or set `impro-emacs' to one."))
    (impro--quit 1))
  (impro--isolate)
  (let ((loaded nil))
    (cl-flet ((go () (unless loaded
                       (setq loaded t)
                       (impro--isolate)  ; again, after the config's own setq's
                       (run-at-time 0.5 nil #'impro--load-scenario scenario))))
      (add-hook 'window-setup-hook #'go 100)
      ;; In case startup is already over and the hook won't run again.
      (run-at-time 10 nil #'go))))

(provide 'impro)
;;; impro.el ends here
