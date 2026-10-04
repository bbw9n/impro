;;; smoke-demo.el --- impro's own smoke test -*- lexical-binding: t; -*-

;; A few seconds of every kind of step, in plain `emacs -Q' terms.
;;   make smoke          record it here
;;   make smoke-linux    record it on Linux, headless, in Docker

;;; Code:

(impro-setup :columns 80 :lines 20)

(impro-open "smoke.org" "#+title: Smoke test

* Hello impro
This is a smoke test.
" #'org-mode)

(impro-play
 '((caption "impro smoke test" 1.5)
   (goto "smoke" 0.5)
   (keys "M-d" 0.6)
   (type "quick" 0.05)
   (eval (goto-char (point-min)) 0.5)
   (keys "C-n C-n" 0.8)
   (end 1)))

;;; smoke-demo.el ends here
