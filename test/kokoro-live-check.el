;;; kokoro-live-check.el --- Manual check with the real server  -*- lexical-binding: t; -*-
;; Speaks two sentences through the real server.
;; Run with: emacs -Q --batch -L .. -l kokoro-live-check.el
;;   (KOKORO_PYTHON=/path/to/python to use another Python)
;; Live check: real server, two sentences (one non-ASCII), log events.
(require 'kokoro)
;; The default `kokoro-python' fits Windows and Linux; KOKORO_PYTHON overrides it.
(when-let* ((python (getenv "KOKORO_PYTHON")))
  (setq kokoro-python (expand-file-name python)))
(defvar live-events nil)
(advice-add 'kokoro--handle :before (lambda (e) (push (format "%s %s" (plist-get e :event) (plist-get e :id)) live-events)))
(with-current-buffer (get-buffer-create "live")
  (insert "Kokoro is reading inside Emacs. The café opens at nine.")
  (kokoro-read-buffer)
  (let ((t0 (float-time)))
    (while (and (< (- (float-time) t0) 180)
                (not (and kokoro--ready (null kokoro--session))))
      (accept-process-output kokoro--process 0.2)))
  (princ (format "events: %S\nsession left: %S\n" (reverse live-events) kokoro--session))
  (kokoro-quit)
  (with-current-buffer " *kokoro-log*"
    (princ (format "log tail: %s\n" (substring (buffer-string) (max 0 (- (buffer-size) 600))))))
  (princ "\n"))


