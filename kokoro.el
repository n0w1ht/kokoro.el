;;; kokoro.el --- Read text aloud with the Kokoro-82M voice  -*- lexical-binding: t; -*-

;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: multimedia, convenience

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Reads buffers, EPUB chapters (nov.el) and PDF pages (pdf-tools) aloud
;; with the Kokoro-82M text-to-speech model, highlighting each sentence
;; as it is spoken, on the PDF page too.  A small Python server
;; (kokoro_server.py, next to this file) keeps the model loaded, so
;; reading starts at once after the first time; Emacs hands it one
;; sentence at a time, a few ahead.
;;
;; Setup:
;;
;;   (require 'kokoro)
;;   (setq kokoro-python "~/kokoro-tts/.venv/Scripts/python.exe")
;;   (global-set-key (kbd "C-c t") 'kokoro-command-map)
;;
;; Keys (prefix C-c t):
;;
;;   C-c t t     read the region; without one, read from point on.  In
;;               a PDF, read the selected text or the pages from the
;;               current one on
;;   C-c t r     read the region          C-c t a   read the whole buffer
;;   C-c t .     read the paragraph
;;   C-c t c     read on from where you stopped in this file (C-u: in
;;               another file read before)
;;   C-c t SPC   pause or resume          C-c t s   stop
;;   C-c t n/p   skip to the next/previous sentence, also across PDF
;;               pages and EPUB chapters
;;   C-c t ]/[   skip to the next/previous paragraph (PDF: page)
;;   C-c t ,     read the sentence again
;;   C-c t v     choose the voice         C-c t +/- faster/slower
;;   C-c t S     set the speed
;;   C-c t w     save a file (text, EPUB, PDF, Word) as MP3, Opus or WAV
;;   C-c t W     save the region as audio
;;   C-c t h     show or hide the controls in the header line
;;   C-c t q     shut the speech server down (frees its memory)
;;
;; With C-u, C-c t v and C-c t S set the voice or speed for the buffer
;; being read only, e.g. a British voice for one book.
;;
;; While reading, the header line has buttons for the same commands and
;; shows how far along you are.  Text passes through
;; `kokoro-text-functions' before it is spoken; `kokoro-pronunciations'
;; says how to say words the voice gets wrong.  Code blocks, tables and
;; drawers in Org and Markdown are skipped (see `kokoro-skip-rules').
;; At the end of a PDF page or an EPUB chapter, reading goes on to the
;; next one (see `kokoro-continue').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'color)

(declare-function image-mode-window-get "image-mode")
(declare-function pdf-info-charlayout "ext:pdf-info")
(declare-function pdf-info-number-of-pages "ext:pdf-info")
(declare-function pdf-view-goto-page "ext:pdf-view")
(declare-function pdf-view-active-region-p "ext:pdf-view")
(declare-function pdf-view-active-region-text "ext:pdf-view")
(declare-function pdf-view-display-region "ext:pdf-view")
(declare-function pdf-view-display-image "ext:pdf-view")
(declare-function pdf-view-create-image "ext:pdf-view")
(declare-function pdf-view-image-size "ext:pdf-view")
(declare-function pdf-info-renderpage-highlight "ext:pdf-info")
(declare-function pdf-info-renderpage-text-regions "ext:pdf-info")
(defvar pdf-view-midnight-colors)
(declare-function pdf-view-redisplay "ext:pdf-view")
(declare-function nov-next-document "ext:nov")
(declare-function nov-goto-document "ext:nov")
(declare-function nov-previous-document "ext:nov")
(defvar nov-documents)
(defvar nov-documents-index)
(defvar nov-file-name)

;;;; Options

(defgroup kokoro nil
  "Read text aloud with Kokoro-82M."
  :group 'multimedia
  :prefix "kokoro-")

(defconst kokoro--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Where kokoro.el and its Python scripts are.")

(defcustom kokoro-python
  (expand-file-name (if (eq system-type 'windows-nt)
                        "~/kokoro-tts/.venv/Scripts/python.exe"
                      "~/kokoro-tts/.venv/bin/python"))
  "Python interpreter of the environment Kokoro is installed in."
  :type 'file)

(defcustom kokoro-narrate-script (expand-file-name "narrate.py" kokoro--directory)
  "Script that narrates a document into a WAV file."
  :type 'file)

(defcustom kokoro-voice "af_heart"
  "Voice to read with.
The first letter picks the accent: a for American, b for British English.
Set it for one file with \\[universal-argument] \\[kokoro-select-voice]."
  :type 'string
  :safe #'stringp)

(defcustom kokoro-voices
  '("af_heart" "af_bella" "af_nicole" "af_sarah" "af_sky" "af_nova" "af_river"
    "af_alloy" "af_aoede" "af_jessica" "af_kore"
    "am_michael" "am_fenrir" "am_puck" "am_adam" "am_echo" "am_eric" "am_liam" "am_onyx"
    "bf_emma" "bf_isabella" "bf_alice" "bf_lily"
    "bm_george" "bm_fable" "bm_daniel" "bm_lewis")
  "Voices offered by `kokoro-select-voice'."
  :type '(repeat string))

(defcustom kokoro-speed 1.0
  "Reading speed; 1.0 is normal.
Set it for one file with \\[universal-argument] \\[kokoro-set-speed]."
  :type 'number
  :safe #'numberp)

(defcustom kokoro-sources-file (locate-user-emacs-file "kokoro-sources.eld")
  "File remembering the voice and speed chosen for particular files.
They are chosen with `kokoro-select-voice' and `kokoro-set-speed' with
a prefix argument, and forgotten with `kokoro-forget-source'.
When nil, nothing is remembered."
  :type '(choice file (const :tag "Do not remember" nil)))

(defcustom kokoro-remember-place t
  "When non-nil, remember where reading got to in each file.
\\[kokoro-resume] reads on from there.  It is kept in `kokoro-sources-file'."
  :type 'boolean)

(defcustom kokoro-follow t
  "When non-nil, scroll so the sentence being read stays in view."
  :type 'boolean)

(defcustom kokoro-continue t
  "When non-nil, go on to the next PDF page or EPUB chapter at the end of one."
  :type 'boolean)

(defcustom kokoro-header-line t
  "When non-nil, show reading controls in the header line while reading."
  :type 'boolean)

(defcustom kokoro-lookahead 3
  "How many sentences are handed to the server ahead of time."
  :type 'natnum)

(defcustom kokoro-max-chars 400
  "Longest piece of text sent as one sentence; longer ones are cut at a space."
  :type 'natnum)

(defcustom kokoro-remove-regexps nil
  "Regexps of text that is not read, in every file.
E.g. \"{[0-9.]+}\" for references like {1.42}.  Each file can have more,
added with \\[kokoro-skip-text]."
  :type '(repeat regexp)
  :safe (lambda (v) (and (listp v) (cl-every #'stringp v))))

(defcustom kokoro-text-functions
  '(kokoro-text-remove kokoro-text-links kokoro-text-symbols kokoro-text-markup
    kokoro-text-pronounce kokoro-text-whitespace)
  "Functions that turn a sentence from the buffer into what is spoken.
Each takes a string and returns a string; they run in order."
  :type '(repeat function))

(defcustom kokoro-pronunciations
  '(("e.g." . "for example") ("i.e." . "that is") ("et al." . "and colleagues")
    ("vs." . "versus") ("approx." . "approximately") ("cf." . "compare")
    ("Fig." . "Figure") ("Figs." . "Figures") ("Eq." . "Equation")
    ("mg/dL" . "milligrams per deciliter") ("mmol/L" . "millimoles per liter")
    ("mg/kg" . "milligrams per kilogram")
    ("mg" . "milligrams") ("mcg" . "micrograms") ("µg" . "micrograms")
    ("ng" . "nanograms") ("kg" . "kilograms")
    ("mL" . "milliliters") ("µL" . "microliters") ("dL" . "deciliters")
    ("mmol" . "millimoles") ("µmol" . "micromoles") ("nmol" . "nanomoles")
    ("mEq" . "milliequivalents") ("µm" . "micrometers")
    ("mm" . "millimeters") ("cm" . "centimeters")
    ("mmHg" . "millimeters of mercury")
    ("b.i.d." . "twice a day") ("t.i.d." . "three times a day")
    ("q.i.d." . "four times a day") ("p.r.n." . "as needed") ("p.o." . "by mouth"))
  "How to say words the voice gets wrong: an alist (TEXT . SPOKEN).
TEXT matches as a whole word, with case; earlier entries are tried first,
so put longer ones (\"mg/dL\") before shorter ones (\"mg\")."
  :type '(alist :key-type string :value-type string))

(defcustom kokoro-symbols
  '(("-->" . "leads to") ("->" . "leads to")
    ("≥" . "greater than or equal to") ("≤" . "less than or equal to")
    ("≠" . "not equal to") ("≈" . "approximately") ("±" . "plus or minus")
    ("→" . "leads to") ("←" . "comes from") ("↔" . "and back")
    ("↑" . "increased") ("↓" . "decreased") ("×" . "times") ("÷" . "divided by")
    ("°C" . "degrees Celsius") ("°F" . "degrees Fahrenheit") ("°" . "degrees")
    ("‰" . "per thousand") ("∞" . "infinity") ("√" . "square root of")
    ("α" . "alpha") ("β" . "beta") ("γ" . "gamma") ("δ" . "delta") ("ε" . "epsilon")
    ("ζ" . "zeta") ("η" . "eta") ("θ" . "theta") ("κ" . "kappa") ("λ" . "lambda")
    ("μ" . "mu") ("ν" . "nu") ("ξ" . "xi") ("π" . "pi") ("ρ" . "rho") ("σ" . "sigma")
    ("τ" . "tau") ("φ" . "phi") ("χ" . "chi") ("ψ" . "psi") ("ω" . "omega")
    ("Δ" . "delta") ("Σ" . "sum of") ("Ω" . "omega"))
  "How to say symbols: an alist (SYMBOL . SPOKEN), used by `kokoro-text-symbols'.
SYMBOL matches anywhere, not only as a word.  Earlier entries are tried
first."
  :type '(alist :key-type string :value-type string))

(defcustom kokoro-abbreviations
  '("Dr." "Mr." "Mrs." "Ms." "Prof." "St." "Jr." "Sr." "vs." "e.g." "i.e."
    "et al." "cf." "approx." "Fig." "Figs." "Eq." "No." "Vol." "pp." "ca.")
  "Words ending in a period that do not end a sentence."
  :type '(repeat string))

(defcustom kokoro-skip-rules
  '((org-mode
     ("^[ \t]*#\\+begin_\\(?:src\\|example\\|export\\)\\_>" "^[ \t]*#\\+end_" "Code block.")
     ("^[ \t]*|" nil "Table.")
     ("^[ \t]*:[[:alpha:]_-]+:[ \t]*$" "^[ \t]*:end:" nil)
     ("^[ \t]*#\\+[[:alpha:]_]+:" nil nil)
     ("^[ \t]*# " nil nil))
    (markdown-mode
     ("^[ \t]*\\(?:```\\|~~~\\)" "^[ \t]*\\(?:```\\|~~~\\)[ \t]*$" "Code block.")
     ("^[ \t]*|" nil "Table.")))
  "Parts of a buffer that are not read, by major mode.
Each rule is (START END SAY).  START matches the first line of the part.
END matches its last line; when END is nil the part is the following
lines that match START too.  SAY is spoken in its place, or nil to pass
over it silently.  Case is ignored."
  :type '(alist :key-type symbol
                :value-type (repeat (list regexp (choice regexp (const nil))
                                          (choice string (const nil))))))

(defcustom kokoro-pdf-margins '(0.06 . 0.06)
  "Parts of a PDF page left out, as fractions of its height: (TOP . BOTTOM).
They are usually running headers, footers and page numbers.  Each PDF
can have its own, set with \\[kokoro-set-pdf-margins]."
  :type '(cons number number)
  :safe (lambda (v) (and (consp v) (numberp (car v)) (numberp (cdr v)))))

(defcustom kokoro-pdf-highlight t
  "When non-nil, highlight the sentence being read on the PDF page."
  :type 'boolean)

(defcustom kokoro-pdf-highlight-style 'marker
  "How the sentence being read is shown on a PDF page.
`marker': a pale color behind the words, like a highlighter pen.
`underline': a line under the words, which leaves them uncovered."
  :type '(choice (const :tag "Highlighter pen" marker)
                 (const :tag "Underline" underline)))

(defcustom kokoro-pdf-highlight-color "#ffd84d"
  "Color of the sentence being read on a PDF page."
  :type 'color)

(defcustom kokoro-pdf-highlight-opacity 0.3
  "How deep `kokoro-pdf-highlight-color' is on a PDF page, 0.0 to 1.0.
Lower is paler; the words stay on top of it.  Underlines are drawn at
twice this, at most fully."
  :type 'number)

(defface kokoro-sentence '((t :inherit highlight))
  "Face of the sentence being read.")

(defconst kokoro--server-script (expand-file-name "kokoro_server.py" kokoro--directory))

;;;; State

(defvar kokoro--process nil)
(defvar kokoro--ready nil "Non-nil once the server has loaded the model.")
(defvar kokoro--partial "" "Server output after the last complete line.")
(defvar kokoro--session nil
  "What is being read: a plist.
:buffer, :pos and :end say where the text is.  :display is the buffer
the reader sees (the PDF for a PDF page), and :page the PDF page being
read, with :skip characters at its start left out.  :next is nil or a
function that starts the following page or chapter and returns non-nil
when it did.  :prev is nil or a function that starts the page or chapter
before, from its start, or from its last sentence when called with
`last'.  :progress is nil or a function returning where the reading is.")
(defvar kokoro--pending nil
  "Sentences handed to the server, oldest first: lists (ID BEG END).")
(defvar kokoro--current nil "Entry of `kokoro--pending' being spoken.")
(defvar kokoro--next-id 0)
(defvar kokoro--paused nil)
(defvar kokoro--overlay nil)
(defvar kokoro--ui-buffer nil "Buffer showing the reading controls.")

;;;; Server

(defun kokoro--start ()
  "Start the speech server unless it is running."
  (unless (process-live-p kokoro--process)
    (unless (file-executable-p kokoro-python)
      (user-error "Kokoro: no Python at %s (see `kokoro-python')" kokoro-python))
    (setq kokoro--ready nil
          kokoro--partial "")
    (message "Kokoro: loading the voice model...")
    (let ((process-environment (append '("PYTHONIOENCODING=utf-8" "PYTHONWARNINGS=ignore")
                                       process-environment))
          (log (get-buffer-create " *kokoro-log*")))
      (setq kokoro--process
            (make-process :name "kokoro"
                          :command (list kokoro-python "-u" kokoro--server-script)
                          :connection-type 'pipe
                          :coding 'utf-8-unix
                          :noquery t
                          :stderr log
                          :filter #'kokoro--filter
                          :sentinel #'kokoro--sentinel))
      (when-let* ((err (get-buffer-process log)))
        (set-process-query-on-exit-flag err nil)))))

(defun kokoro--send (msg)
  "Send MSG, a plist, to the server as one JSON line."
  (when (process-live-p kokoro--process)
    (let ((json (json-serialize msg)))
      (unless (multibyte-string-p json)
        (setq json (decode-coding-string json 'utf-8)))
      (process-send-string kokoro--process (concat json "\n")))))

(defun kokoro--filter (_proc output)
  (setq kokoro--partial (concat kokoro--partial output))
  (let ((lines (split-string kokoro--partial "\n")))
    (setq kokoro--partial (car (last lines)))
    (dolist (line (butlast lines))
      (when (string-prefix-p "{" line)
        (condition-case err
            (kokoro--handle (json-parse-string line :object-type 'plist))
          (error (message "Kokoro: %s" (error-message-string err))))))))

(defun kokoro--sentinel (proc _event)
  (unless (process-live-p proc)
    (unless kokoro--ready
      (message "Kokoro: the speech server did not start; see the \" *kokoro-log*\" buffer"))
    (kokoro--clear)
    (kokoro--ui-end)
    (setq kokoro--process nil
          kokoro--ready nil)))

(defun kokoro--handle (event)
  "Act on EVENT, a plist parsed from a server line."
  (let ((id (plist-get event :id)))
    (pcase (plist-get event :event)
      ("ready"
       (setq kokoro--ready t)
       (force-mode-line-update t)
       (kokoro--feed))
      ("start"
       (when-let* ((entry (assq id kokoro--pending)))
         (setq kokoro--current entry)
         (kokoro--note-place entry)
         (kokoro--show entry)))
      ("end"
       (when (assq id kokoro--pending)
         (setq kokoro--pending (cl-remove-if (lambda (e) (<= (car e) id)) kokoro--pending))
         (kokoro--feed)))
      ("error"
       (message "Kokoro: %s" (plist-get event :msg))))))

;;;; Sentences

(defun kokoro--abbreviation-before-p ()
  "Non-nil if the text before point ends with one of `kokoro-abbreviations'."
  (let ((case-fold-search nil))
    (looking-back (concat "\\(?:^\\|[^[:alnum:]]\\)" (regexp-opt kokoro-abbreviations)
                          "[\"'”’)]*")
                  (line-beginning-position 0))))

(defun kokoro--forward-sentence (limit)
  "Move to the end of the sentence, not stopping after an abbreviation."
  (let ((sentence-end-double-space nil))
    (forward-sentence)
    (while (and (< (point) limit)
                (kokoro--abbreviation-before-p)
                (let ((here (point)))
                  (forward-sentence)
                  (> (point) here))))))

(defun kokoro--skip-rules ()
  "The rules of `kokoro-skip-rules' for this buffer."
  (cl-loop for (mode . rules) in kokoro-skip-rules
           when (derived-mode-p mode) append rules))

(defun kokoro--skip-at (pos limit rules)
  "If a rule of RULES starts at the line of POS, return (END . SAY)."
  (save-excursion
    (goto-char pos)
    (when (save-excursion (skip-chars-backward " \t") (bolp))
      (beginning-of-line)
      (let ((case-fold-search t))
        (cl-loop for (start end say) in rules
                 when (looking-at start)
                 return (cons (min limit
                                   (if end
                                       (progn (forward-line 1)
                                              (if (re-search-forward end limit t)
                                                  (line-end-position)
                                                limit))
                                     (while (and (< (point) limit) (looking-at start))
                                       (forward-line 1))
                                     (point)))
                              say))))))

(defun kokoro--next-skip (pos limit rules)
  "Where the next part RULES skip starts after POS, or LIMIT."
  (or (and rules
           (save-excursion
             (goto-char pos)
             (let ((case-fold-search t))
               (and (re-search-forward (mapconcat #'car rules "\\|") limit t)
                    (match-beginning 0)))))
      limit))

(defun kokoro--next-sentence (pos limit)
  "Return (BEG END SAY) of the next sentence with words in it, from POS to LIMIT.
SAY is nil, or what to say instead of the text, for a skipped part."
  (save-excursion
    (goto-char pos)
    (let ((rules (kokoro--skip-rules))
          found)
      (while (and (not found)
                  (progn (skip-chars-forward " \t\n\r\f" limit)
                         (< (point) limit)))
        (let* ((beg (point))
               (skip (and rules (kokoro--skip-at beg limit rules))))
          (if skip
              (progn (goto-char (max (1+ beg) (car skip)))
                     (when (cdr skip)
                       (setq found (list beg (point) (cdr skip)))))
            (let ((stop (kokoro--next-skip beg limit rules)))
              (kokoro--forward-sentence stop)
              (goto-char (max (1+ beg) (min (point) stop)))
              (when (> (- (point) beg) kokoro-max-chars)
                (goto-char (+ beg kokoro-max-chars))
                (skip-chars-backward "^ \t\n" (+ beg (/ kokoro-max-chars 2)))
                ;; Not between the halves of a word hyphenated over lines.
                (while (and (> (point) (+ beg (/ kokoro-max-chars 2)))
                            (save-excursion
                              (skip-chars-backward " \t\n")
                              (memq (char-before) '(?- ?\u00ad ?\u2010 ?\u2011 ?¬))))
                  (skip-chars-backward " \t\n")
                  (skip-chars-backward "^ \t\n" (+ beg (/ kokoro-max-chars 2)))))
              (skip-chars-backward " \t\n" (1+ beg)) ; e.g. before a skipped part
              (when (string-match-p "[[:alnum:]]" (buffer-substring-no-properties beg (point)))
                (setq found (list beg (point) nil)))))))
      found)))

(defun kokoro--last-sentence-start (beg end)
  "Where the last sentence between BEG and END begins, or BEG."
  (let ((pos beg) last span)
    (while (setq span (kokoro--next-sentence pos end))
      (setq last (car span)
            pos (nth 1 span)))
    (or last beg)))

(defun kokoro--sentence-start ()
  "Position where the sentence at point begins."
  (let ((sentence-end-double-space nil))
    (save-excursion
      (skip-chars-forward " \t\n")
      (unless (eobp)
        (forward-char 1)
        (forward-sentence)
        (backward-sentence))
      (point))))

;;;; Text

(defun kokoro--text (text)
  "Run TEXT through `kokoro-text-functions'."
  (dolist (fn kokoro-text-functions text)
    (setq text (funcall fn text))))

(defun kokoro-text-remove (text)
  "Remove from TEXT what `kokoro-remove-regexps' and the file's own patterns match."
  (let ((buf (kokoro--settings-buffer)))
    (dolist (re (append (buffer-local-value 'kokoro-remove-regexps buf)
                        (buffer-local-value 'kokoro--file-removals buf))
                text)
      (setq text (replace-regexp-in-string re "" text t t)))))

(defun kokoro-text-links (text)
  "Say the description of Org and Markdown links in TEXT, and \"link\" for URLs."
  (thread-last
    text
    (replace-regexp-in-string "\\[\\[[^]]*\\]\\[\\([^]]*\\)\\]\\]" "\\1")
    (replace-regexp-in-string "\\[\\[\\([^]]*\\)\\]\\]" "\\1")
    (replace-regexp-in-string "\\[\\([^]]*\\)\\]([^)]*)" "\\1")
    (replace-regexp-in-string "https?://[^ \t\n]+" "link")))

(defconst kokoro--superscripts "⁰¹²³⁴⁵⁶⁷⁸⁹⁻⁺"
  "Superscript characters; the same position in \"0123456789-+\" is what they are.")

(defconst kokoro--subscripts "₀₁₂₃₄₅₆₇₈₉₋₊"
  "Subscript characters, like `kokoro--superscripts'.")

(defun kokoro--unsuperscript (string &optional chars)
  "STRING with the superscripts (or CHARS) in it made plain digits and signs."
  (apply #'string (mapcar (lambda (c)
                            (if-let* ((i (seq-position (or chars kokoro--superscripts) c)))
                                (aref "0123456789-+" i)
                              c))
                          string)))

(defun kokoro-text-symbols (text)
  "Say the symbols, powers, ranges and comparisons in TEXT in words.
\"×10⁹/L\" becomes \"times 10 to the 9 per liter\", \"5–10\" \"5 to 10\",
\"> 140\" \"greater than 140\" and \"m²\" \"square meters\".  Superscript
numbers after a word, mostly references, are left out.  Other symbols
are said as `kokoro-symbols' says."
  (let ((case-fold-search nil)
        (sup (concat "[" kokoro--superscripts "]+")))
    (cl-flet ((sub (regexp rep &optional subexp)
                (setq text (replace-regexp-in-string regexp rep text t nil subexp))))
      ;; The Greek mu typed for the micro sign, before units.
      (sub "μ\\(g\\|L\\|l\\|m\\|mol\\|M\\)\\b" "µ\\1")
      ;; Powers: 10⁹, 10^9, 10^-3.
      (sub (concat "\\b10\\(" sup "\\)")
           (lambda (m) (concat "10 to the " (kokoro--unsuperscript (match-string 1 m)))))
      (sub "\\b10\\^\\([-+]?[0-9]+\\)" "10 to the \\1")
      ;; Areas and volumes.
      (sub "\\b\\(k?m\\|[cmµ]m\\)\\([²³]\\)"
           (lambda (m)
             (concat (if (equal (match-string 2 m) "²") "square " "cubic ")
                     (pcase (match-string 1 m)
                       ("m" "meters") ("km" "kilometers") ("cm" "centimeters")
                       ("mm" "millimeters") ("µm" "micrometers")))))
      ;; Superscripts left after a word or a closing mark: references.
      (sub (concat "\\([[:alpha:].,;:)]\\)" sup "\\(?:[,–-]" sup "\\)*") "\\1")
      ;; Per unit of time or volume: "beats/min", "×10⁹/L".
      (sub "\\([[:alnum:]]\\)/\\(L\\|min\\|h\\|hr\\|day\\|d\\|wk\\|kg\\|s\\)\\b"
           (lambda (m)
             (concat (match-string 1 m) " per "
                     (pcase (match-string 2 m)
                       ("L" "liter") ("min" "minute") ((or "h" "hr") "hour")
                       ((or "day" "d") "day") ("wk" "week") ("kg" "kilogram")
                       ("s" "second")))))
      ;; Ranges of numbers, but not dates like 2026-10-27.
      (sub "\\(?:^\\|[^-–0-9.]\\)[0-9]+\\(?:\\.[0-9]+\\)?\\([–-]\\)[0-9]+\\(?:\\.[0-9]+\\)?\\(?:$\\|[^-–0-9]\\)"
           " to " 1)
      ;; Comparisons, not quotes or arrows: "> 140", "(<0.5)".
      (sub "\\(?:^\\|[ (]\\)\\(>=?\\|<=?\\)[ \t]*[0-9.]"
           (lambda (m)
             (pcase (match-string 1 m)
               (">" "greater than ") ("<" "less than ")
               (">=" "greater than or equal to ") ("<=" "less than or equal to ")))
           1)
      ;; Subscripts: "α₁" is "alpha 1", "CO₂" "CO 2".
      (sub (concat "[" kokoro--subscripts "]+")
           (lambda (m) (concat " " (kokoro--unsuperscript m kokoro--subscripts))))
      (sub " = " " equals ")
      (kokoro--say-symbols text))))

(defun kokoro--say-symbols (text)
  "Replace the symbols of `kokoro-symbols' in TEXT.
A space is put between the words and a letter or number next to them."
  (with-temp-buffer
    (insert text)
    (pcase-dolist (`(,symbol . ,spoken) kokoro-symbols)
      (goto-char (point-min))
      (while (search-forward symbol nil t)
        (replace-match spoken t t)
        (let ((end (point)))
          (when (and (char-after) (string-match-p "[[:alnum:]]" (string (char-after))))
            (insert " "))
          (goto-char (- end (length spoken)))
          (when (and (char-before) (string-match-p "[[:alnum:]]" (string (char-before))))
            (insert " "))
          (goto-char end))))
    (buffer-string)))

(defun kokoro-text-markup (text)
  "Remove markup characters from TEXT."
  (replace-regexp-in-string "[*=~`#|>]+" " " text))

(defun kokoro-text-pronounce (text)
  "Replace words in TEXT as `kokoro-pronunciations' says."
  (let ((case-fold-search nil))
    (dolist (entry kokoro-pronunciations text)
      (setq text (replace-regexp-in-string
                  (concat "\\(?:^\\|[^[:alnum:]]\\)\\(" (regexp-quote (car entry))
                          "\\)\\(?:[^[:alnum:]]\\|$\\)")
                  (cdr entry) text t t 1)))))

(defconst kokoro--line-hyphen
  "\\([[:alpha:]]\\)[-\u00ad\u2010\u2011¬][ \t\r]*\n[ \t]*\\([[:alpha:]]\\)"
  "Regexp matching a word hyphenated over two lines, around the break.
The hyphen can be a soft or Unicode one, as PDFs often have, and spaces
may come before or after the line break.")

(defun kokoro-text-whitespace (text)
  "Join words hyphenated over lines in TEXT and put it on one line.
\"Liber-\" at the end of a line and \"ation\" on the next are read
\"Liberation\".  Soft hyphens elsewhere are dropped."
  (thread-last
    text
    (replace-regexp-in-string kokoro--line-hyphen "\\1\\2")
    (string-replace "\u00ad" "")
    (replace-regexp-in-string "[ \t\n\r\f]+" " ")
    (string-trim)))

;;;; Voice and speed

(defun kokoro--settings-buffer ()
  "Buffer whose voice and speed are used: the one being read, or this one."
  (let ((buf (plist-get kokoro--session :display)))
    (if (buffer-live-p buf) buf (current-buffer))))

(defun kokoro--voice () (buffer-local-value 'kokoro-voice (kokoro--settings-buffer)))
(defun kokoro--speed () (buffer-local-value 'kokoro-speed (kokoro--settings-buffer)))

(defun kokoro--set (var value local)
  "Set VAR to VALUE in the buffer being read, or everywhere.
It is set in the buffer, and remembered for its file, if LOCAL is
non-nil or the buffer has its own value."
  (with-current-buffer (kokoro--settings-buffer)
    (if (or local (local-variable-p var))
        (progn (set (make-local-variable var) value)
               (kokoro--remember var value))
      (set-default var value))))

;;;; Remembered sources

(defvar kokoro--sources 'unread
  "Alist (FILE . PLIST) of the settings remembered per file, or `unread'.
PLIST may have :voice, :speed and :remove (a list of regexps).")

(defvar-local kokoro--file-removals nil
  "Regexps of text not read in this buffer's file, besides `kokoro-remove-regexps'.")

(defun kokoro--source-key ()
  "The name the current buffer's file is remembered under, or nil."
  ;; nov.el leaves its EPUB buffers without `buffer-file-name'.
  (when-let* ((file (or buffer-file-name (bound-and-true-p nov-file-name))))
    (abbreviate-file-name (expand-file-name file))))

(defun kokoro--sources ()
  "The remembered settings, read from `kokoro-sources-file' the first time."
  (when (eq kokoro--sources 'unread)
    (setq kokoro--sources
          (and kokoro-sources-file
               (file-readable-p kokoro-sources-file)
               (condition-case err
                   (with-temp-buffer
                     (insert-file-contents kokoro-sources-file)
                     (read (current-buffer)))
                 (error (message "Kokoro: cannot read %s: %s" kokoro-sources-file
                                 (error-message-string err))
                        nil)))))
  kokoro--sources)

(defun kokoro--save-sources ()
  (when kokoro-sources-file
    (let ((print-length nil)
          (print-level nil))
      (with-temp-file kokoro-sources-file
        (insert ";;; Voice and speed per file, for kokoro.el  -*- lisp-data -*-\n")
        (pp kokoro--sources (current-buffer))))))

(defun kokoro--remember (var value)
  "Remember VALUE of VAR for the current buffer's file."
  (when-let* ((key (and kokoro-sources-file (kokoro--source-key)))
              (prop (pcase var
                      ('kokoro-voice :voice)
                      ('kokoro-speed :speed)
                      ('kokoro--file-removals :remove)
                      ('kokoro-pdf-margins :margins))))
    (kokoro--put-source key prop value)
    (kokoro--save-sources)))

(defun kokoro--put-source (key prop value)
  "Set PROP to VALUE in the settings remembered for KEY, without saving them."
  (let ((entry (assoc key (kokoro--sources))))
    (if entry
        (setcdr entry (plist-put (cdr entry) prop value))
      (push (list key prop value) kokoro--sources))))

(defun kokoro--apply-source (buf)
  "Give BUF the voice and speed remembered for its file."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when-let* ((key (and kokoro-sources-file (kokoro--source-key)))
                  (settings (cdr (assoc key (kokoro--sources)))))
        (when-let* ((voice (plist-get settings :voice)))
          (setq-local kokoro-voice voice))
        (when-let* ((speed (plist-get settings :speed)))
          (setq-local kokoro-speed speed))
        (when-let* ((margins (plist-get settings :margins)))
          (setq-local kokoro-pdf-margins margins))
        (setq kokoro--file-removals (plist-get settings :remove))))))

;;;###autoload
(defun kokoro-set-pdf-margins (top bottom)
  "Leave out the TOP and BOTTOM percent of each page of this PDF.
This is remembered for the PDF; `kokoro-pdf-margins' is used for others.
The part that is read is shaded on the page until it is redrawn."
  (interactive
   (progn
     (unless (derived-mode-p 'pdf-view-mode)
       (user-error "Kokoro: not a PDF"))
     (kokoro--apply-source (current-buffer))
     (let ((now (or kokoro-pdf-margins '(0 . 0))))
       (list (read-number "Leave out the top (% of page height): "
                          (round (* 100 (car now))))
             (read-number "Leave out the bottom (% of page height): "
                          (round (* 100 (cdr now))))))))
  (unless (and (<= 0 top) (<= 0 bottom) (< (+ top bottom) 100))
    (user-error "Kokoro: the margins must leave part of the page"))
  (let ((margins (cons (/ top 100.0) (/ bottom 100.0)))
        (pdf (current-buffer)))
    (setq-local kokoro-pdf-margins margins)
    (kokoro--remember 'kokoro-pdf-margins margins)
    ;; Show what is read now.
    (dolist (win (get-buffer-window-list pdf nil t))
      (with-selected-window win
        (ignore-errors
          (pdf-view-display-region
           (list (image-mode-window-get 'page win)
                 (list 0 (car margins) 1 (- 1 (cdr margins))))
           t))))
    (message "Kokoro: reading this PDF from %s%% to %s%% of the page height (shaded)"
             top (- 100 bottom))
    ;; Read the page again with the new margins.
    (when-let* ((page (and (eq (plist-get kokoro--session :display) pdf)
                           (plist-get kokoro--session :page))))
      (kokoro--read-pdf-page pdf page))))

(defun kokoro--check-regexp (regexp)
  "Signal a `user-error' unless REGEXP is a valid regexp matching some text."
  (condition-case err
      (when (string-match-p regexp "")
        (user-error "Kokoro: \"%s\" matches empty text; it would remove nothing" regexp))
    (invalid-regexp (user-error "Kokoro: not a valid regexp: %s" (cadr err)))))

;;;###autoload
(defun kokoro-skip-text (regexp)
  "Do not read text matching REGEXP in this file (remembered for it).
For example {[0-9.]+} leaves out references like {1.42}."
  (interactive (list (read-regexp "Leave out text matching regexp: ")))
  (kokoro--check-regexp regexp)
  (with-current-buffer (kokoro--settings-buffer)
    (kokoro--apply-source (current-buffer))
    (unless (member regexp kokoro--file-removals)
      (setq kokoro--file-removals (append kokoro--file-removals (list regexp)))
      (kokoro--remember 'kokoro--file-removals kokoro--file-removals))
    (let ((count (unless (derived-mode-p 'pdf-view-mode)
                   (how-many regexp (point-min) (point-max)))))
      (message "Kokoro: leaving out \"%s\" in %s%s%s" regexp
               (if (kokoro--source-key) "this file" "this buffer")
               (if count (format " (%d match%s here)" count (if (= count 1) "" "es")) "")
               (if (kokoro--source-key) "" ", until it is closed"))))
  (kokoro--again))

(defun kokoro-unskip-text (regexp)
  "Read text matching REGEXP in this file again."
  (interactive
   (let ((removals (buffer-local-value 'kokoro--file-removals
                                       (progn (kokoro--apply-source (kokoro--settings-buffer))
                                              (kokoro--settings-buffer)))))
     (unless removals
       (user-error "Kokoro: this file leaves nothing out"))
     (list (completing-read "Read again: " removals nil t))))
  (with-current-buffer (kokoro--settings-buffer)
    (setq kokoro--file-removals (delete regexp (copy-sequence kokoro--file-removals)))
    (kokoro--remember 'kokoro--file-removals kokoro--file-removals)
    (message "Kokoro: reading \"%s\" again" regexp))
  (kokoro--again))

(defun kokoro-forget-source ()
  "Forget the voice, speed, left-out text and place remembered for this file."
  (interactive)
  (with-current-buffer (kokoro--settings-buffer)
    (let ((key (kokoro--source-key)))
      (kill-local-variable 'kokoro-voice)
      (kill-local-variable 'kokoro-speed)
      (kill-local-variable 'kokoro-pdf-margins)
      (setq kokoro--file-removals nil)
      (when (and key (assoc key (kokoro--sources)))
        (setq kokoro--sources (assoc-delete-all key kokoro--sources))
        (kokoro--save-sources))
      (message "Kokoro: %s reads with %s at %.1f again"
               (if key (file-name-nondirectory key) (buffer-name))
               kokoro-voice kokoro-speed)))
  (kokoro--again))

(defconst kokoro--languages
  '((?a . "American English") (?b . "British English") (?e . "Spanish") (?f . "French")
    (?h . "Hindi") (?i . "Italian") (?j . "Japanese") (?p . "Brazilian Portuguese")
    (?z . "Mandarin Chinese")))

(defun kokoro--voice-language (voice)
  (or (alist-get (aref voice 0) kokoro--languages) "Other"))

(defun kokoro--voice-description (voice)
  "E.g. \"American English, female\" for VOICE af_heart."
  (concat (kokoro--voice-language voice)
          (pcase (and (> (length voice) 1) (aref voice 1))
            (?f ", female") (?m ", male") (_ ""))))

(defun kokoro--read-voice ()
  "Ask for a voice, showing its accent and whether it is female or male."
  (let* ((width (apply #'max (mapcar #'length kokoro-voices)))
         (annotate (lambda (voice)
                     (concat (make-string (max 1 (- (+ width 2) (length voice))) ?\s)
                             (propertize (kokoro--voice-description voice)
                                         'face 'completions-annotations))))
         (group (lambda (voice transform)
                  (if transform voice (kokoro--voice-language voice))))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata (category . kokoro-voice)
                                 (annotation-function . ,annotate)
                                 (group-function . ,group))
                    (complete-with-action action kokoro-voices string pred)))))
    (completing-read (format "Voice (now %s): " (kokoro--voice))
                     table nil t nil nil (kokoro--voice))))

;;;; Reading

(defun kokoro--clear ()
  "Forget what is being read and silence the server."
  (kokoro--send '(:cmd "stop"))
  (kokoro--save-place)
  (dolist (e kokoro--pending)
    (set-marker (nth 1 e) nil)
    (set-marker (nth 2 e) nil))
  (when kokoro--session
    (set-marker (plist-get kokoro--session :pos) nil)
    (set-marker (plist-get kokoro--session :end) nil))
  (setq kokoro--session nil
        kokoro--pending nil
        kokoro--current nil
        kokoro--paused nil)
  (when kokoro--overlay
    (delete-overlay kokoro--overlay)))

(defun kokoro--read (beg end &optional props)
  "Read the current buffer from BEG to END.
PROPS may give :next, :display and :progress; see `kokoro--session'."
  (kokoro--clear)
  (kokoro--start)
  (setq kokoro--session (append (list :buffer (current-buffer)
                                      :pos (copy-marker beg)
                                      :end (copy-marker end t)
                                      :display (or (plist-get props :display) (current-buffer)))
                                props))
  (kokoro--apply-source (plist-get kokoro--session :display))
  (kokoro--ui-start (plist-get kokoro--session :display))
  (kokoro--feed))

(defun kokoro--feed ()
  "Hand the server sentences until `kokoro-lookahead' are waiting."
  (when (and kokoro--ready kokoro--session)
    (while (and (< (length kokoro--pending) kokoro-lookahead)
                (kokoro--send-next)))
    (unless kokoro--pending
      (kokoro--finish))))

(defun kokoro--send-next ()
  "Send the next sentence of the session; return nil when there is none."
  (let ((buf (plist-get kokoro--session :buffer))
        (pos (plist-get kokoro--session :pos))
        (voice (kokoro--voice))
        (speed (float (kokoro--speed))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when-let* ((span (kokoro--next-sentence pos (plist-get kokoro--session :end))))
          (let ((id (cl-incf kokoro--next-id)))
            (set-marker pos (nth 1 span))
            (setq kokoro--pending
                  (append kokoro--pending
                          (list (list id (copy-marker (nth 0 span)) (copy-marker (nth 1 span))))))
            (kokoro--send
             (list :cmd "speak" :id id :voice voice :speed speed
                   :text (or (nth 2 span)
                             (kokoro--text (buffer-substring-no-properties
                                            (nth 0 span) (nth 1 span))))))
            t))))))

(defun kokoro--finish (&optional skip)
  "End of the session: go on to the next page or chapter, or stop.
When SKIP is non-nil, go on even if `kokoro-continue' is nil."
  (let ((next (plist-get kokoro--session :next)))
    (kokoro--clear)
    (unless (and next (or skip kokoro-continue) (funcall next))
      (kokoro--ui-end)
      (message "Kokoro: done"))))

(defun kokoro--go-back (from)
  "Read the page or chapter before, FROM its start (nil) or `last' sentence.
Return nil, reading on as before, when there is none."
  (when-let* ((prev (plist-get kokoro--session :prev)))
    (kokoro--clear)
    (funcall prev from)
    t))

(defun kokoro--at-first-sentence-p (entry)
  "Non-nil if no sentence comes before ENTRY's in the text being read."
  (with-current-buffer (marker-buffer (nth 1 entry))
    (not (kokoro--next-sentence (point-min) (nth 1 entry)))))

(defun kokoro--show (entry)
  "Highlight the sentence of ENTRY and keep it in view."
  (let* ((beg (nth 1 entry))
         (end (nth 2 entry))
         (buf (marker-buffer beg))
         (display (plist-get kokoro--session :display)))
    (when (buffer-live-p buf)
      (unless kokoro--overlay
        (setq kokoro--overlay (make-overlay beg end buf))
        (overlay-put kokoro--overlay 'face 'kokoro-sentence)
        (overlay-put kokoro--overlay 'priority 100))
      (move-overlay kokoro--overlay beg end buf)
      (cond
       ((and (buffer-live-p display)
             (with-current-buffer display (derived-mode-p 'pdf-view-mode)))
        (when kokoro-pdf-highlight
          (kokoro--pdf-highlight display beg end)))
       (kokoro-follow
        (dolist (win (get-buffer-window-list buf nil t))
          (unless (and (pos-visible-in-window-p beg win)
                       (pos-visible-in-window-p end win))
            (set-window-point win beg)
            (with-selected-window win (recenter 3))))))
      (force-mode-line-update t))))

(defun kokoro--restart (move)
  "Read on from where MOVE goes, called with the entry being spoken."
  (let ((entry kokoro--current)
        (s kokoro--session))
    (unless (and entry s)
      (user-error "Kokoro is not reading"))
    (let* ((buf (plist-get s :buffer))
           (end (marker-position (plist-get s :end)))
           (props (cl-loop for (key value) on s by #'cddr
                           unless (memq key '(:buffer :pos :end))
                           append (list key value)))
           (start (with-current-buffer buf
                    (save-excursion (funcall move entry) (point)))))
      (with-current-buffer buf
        (kokoro--read start end props)))))

;;;; Where reading got to

(defvar kokoro--place-unsaved nil
  "Time a place was noted that `kokoro-sources-file' does not have yet, or nil.")

(defun kokoro--place-of (entry)
  "Where the sentence of ENTRY is, as a plist `kokoro-resume' can go back to.
It is (:page N :offset CHARS) in a PDF, (:chapter N :pos POS) in an EPUB
and (:pos POS) elsewhere; nil for text that is not in the file, such as
text selected on a PDF page."
  (let ((display (plist-get kokoro--session :display))
        (beg (nth 1 entry)))
    (cond
     ((plist-get kokoro--session :page)
      (list :page (plist-get kokoro--session :page)
            :offset (+ (or (plist-get kokoro--session :skip) 0)
                       (with-current-buffer (marker-buffer beg)
                         (- beg (point-min))))))
     ((not (eq (marker-buffer beg) display)) nil)
     (t
      (with-current-buffer display
        (append (and (derived-mode-p 'nov-mode) (list :chapter nov-documents-index))
                (list :pos (marker-position beg)
                      :percent (/ (* 100 (- beg (point-min)))
                                  (max 1 (- (point-max) (point-min)))))))))))

(defun kokoro--note-place (entry)
  "Remember that the sentence of ENTRY is being read, for `kokoro-resume'.
The sources file is written when reading stops, or once a minute."
  (when-let* ((kokoro-remember-place)
              (kokoro-sources-file)
              (display (plist-get kokoro--session :display))
              ((buffer-live-p display))
              (key (with-current-buffer display (kokoro--source-key)))
              (place (kokoro--place-of entry)))
    (kokoro--put-source key :place (append place (list :time (float-time))))
    (unless kokoro--place-unsaved
      (setq kokoro--place-unsaved (float-time)))
    (when (> (- (float-time) kokoro--place-unsaved) 60)
      (kokoro--save-place))))

(defun kokoro--save-place ()
  "Write the places noted since the sources file was last written."
  (when kokoro--place-unsaved
    (setq kokoro--place-unsaved nil)
    (kokoro--save-sources)))

(add-hook 'kill-emacs-hook #'kokoro--save-place)

(defun kokoro--describe-place (place)
  "E.g. \"page 12\" or \"chapter 3, 40%\" for PLACE, and when it was read."
  (concat (string-join
           (delq nil (list (and (plist-get place :page) (format "page %d" (plist-get place :page)))
                           (and (plist-get place :chapter)
                                (format "chapter %d" (1+ (plist-get place :chapter))))
                           (and (plist-get place :percent)
                                (format "%d%%" (plist-get place :percent)))))
           ", ")
          (when-let* ((time (plist-get place :time)))
            (format-time-string ", %Y-%m-%d %H:%M" time))))

(defun kokoro--choose-place ()
  "Ask for one of the files with a remembered place, the last read first."
  (let* ((files (mapcar #'car
                        (sort (cl-remove-if-not (lambda (e) (plist-get (cdr e) :place))
                                                (copy-sequence (kokoro--sources)))
                              (lambda (a b)
                                (> (or (plist-get (plist-get (cdr a) :place) :time) 0)
                                   (or (plist-get (plist-get (cdr b) :place) :time) 0))))))
         (width (if files (apply #'max (mapcar (lambda (f) (length (file-name-nondirectory f)))
                                               files))
                  0))
         (annotate (lambda (file)
                     (concat (make-string (max 1 (- (+ width 2)
                                                    (length (file-name-nondirectory file))))
                                          ?\s)
                             (propertize (kokoro--describe-place
                                          (plist-get (cdr (assoc file (kokoro--sources))) :place))
                                         'face 'completions-annotations)
                             "  "
                             (propertize (abbreviate-file-name (file-name-directory file))
                                         'face 'shadow))))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata (category . kokoro-place)
                                 (annotation-function . ,annotate)
                                 (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action files string pred)))))
    (unless files
      (user-error "Kokoro: no file has a place to resume yet"))
    (completing-read "Resume reading: " table nil t)))

(defun kokoro--resume-at (place)
  "Read the current buffer on from PLACE, made by `kokoro--place-of'."
  (cond
   ((plist-get place :page)
    (unless (derived-mode-p 'pdf-view-mode)
      (user-error "Kokoro: the place is a PDF page, but this is not a PDF"))
    (let ((page (min (plist-get place :page) (pdf-info-number-of-pages))))
      (pdf-view-goto-page page)
      (kokoro--read-pdf-page (current-buffer) page (plist-get place :offset))))
   (t
    (when-let* ((chapter (plist-get place :chapter))
                ((derived-mode-p 'nov-mode))
                ((< chapter (length nov-documents)))
                ((/= chapter nov-documents-index)))
      (nov-goto-document chapter))
    (goto-char (min (plist-get place :pos) (point-max)))
    (kokoro--read (point) (point-max) (kokoro--book-props)))))

;;;###autoload
(defun kokoro-resume (&optional choose)
  "Read on from where reading got to in this file.
In a buffer without a remembered place, or with a prefix argument
(CHOOSE), choose one of the files read before, the last one first, and
open it there."
  (interactive "P")
  (let* ((key (kokoro--source-key))
         (place (and key (not choose)
                     (plist-get (cdr (assoc key (kokoro--sources))) :place))))
    (unless place
      (let ((file (kokoro--choose-place)))
        (find-file file)
        (setq place (plist-get (cdr (assoc file (kokoro--sources))) :place))))
    (message "Kokoro: reading on from %s" (kokoro--describe-place place))
    (kokoro--resume-at place)))

;;;; Books

(defun kokoro--book-props ()
  "In an EPUB buffer, what `kokoro--read' needs to go on chapter by chapter."
  (when (derived-mode-p 'nov-mode)
    (let ((buf (current-buffer)))
      (list :next (lambda () (kokoro--nov-next buf))
            :prev (and (> nov-documents-index 0)
                       (lambda (from) (kokoro--nov-previous buf from)))
            :progress (lambda ()
                        (with-current-buffer buf
                          (format "chapter %d/%d" (1+ nov-documents-index)
                                  (length nov-documents))))))))

(defun kokoro--nov-next (buf)
  (when (and (buffer-live-p buf)
             (with-current-buffer buf
               (< (1+ nov-documents-index) (length nov-documents))))
    (if-let* ((win (get-buffer-window buf t)))
        (with-selected-window win (nov-next-document))
      (with-current-buffer buf (nov-next-document)))
    (with-current-buffer buf
      (kokoro--read (point-min) (point-max) (kokoro--book-props)))
    t))

(defun kokoro--nov-previous (buf from)
  "Read the chapter before the one in BUF, FROM its start or `last' sentence."
  (when (buffer-live-p buf)
    (if-let* ((win (get-buffer-window buf t)))
        (with-selected-window win (nov-previous-document))
      (with-current-buffer buf (nov-previous-document)))
    (with-current-buffer buf
      (kokoro--read (if (eq from 'last)
                        (kokoro--last-sentence-start (point-min) (point-max))
                      (point-min))
                    (point-max) (kokoro--book-props)))))

;;;; PDF

(defun kokoro--pdf-insert-page (pdf page)
  "Insert the text of PAGE of the PDF buffer PDF at point.
The margins of `kokoro-pdf-margins' and lines with only a page number
are left out.  Each character keeps its place on the page in the text
property `kokoro-pdf', as (PAGE LEFT TOP RIGHT BOTTOM)."
  (let* ((margins (buffer-local-value 'kokoro-pdf-margins pdf))
         (top (or (car margins) 0))
         (bottom (- 1 (or (cdr margins) 0)))
         (start (point)))
    (pcase-dolist (`(,char ,edges) (with-current-buffer pdf (pdf-info-charlayout page)))
      (when (or (memq char '(?\s ?\t ?\n))
                (and (>= (nth 1 edges) top) (<= (nth 3 edges) bottom)))
        (insert (propertize (char-to-string char) 'kokoro-pdf (cons page edges)))))
    (let ((end (point-marker))
          (case-fold-search t))
      (goto-char start)
      (while (re-search-forward
              "^[ \t]*\\(?:page[ \t]+\\)?[0-9]+\\(?:[ \t]*\\(?:/\\|of\\)[ \t]*[0-9]+\\)?[ \t]*\\(?:\n\\|\\'\\)"
              end t)
        (replace-match ""))
      (goto-char end)
      (set-marker end nil))))

(defun kokoro--ends-sentence-p ()
  "Non-nil if the buffer's text ends a sentence (or is empty)."
  (save-excursion
    (goto-char (point-max))
    (skip-chars-backward " \t\n")
    (or (bobp)
        (looking-back "[.!?:;][\"'”’)]*" (max (point-min) (- (point) 4))))))

(defun kokoro--read-pdf-page (pdf page &optional skip from)
  "Read PAGE of the PDF buffer PDF, then the pages after it.
SKIP characters at the start of the page were read with the page before.
When FROM is `last', start at the page's last sentence.
A sentence running onto the next page is finished before turning it."
  (kokoro--apply-source pdf)            ; its own margins, before reading the page
  (let ((pages (with-current-buffer pdf (pdf-info-number-of-pages)))
        carry)
    (with-current-buffer (get-buffer-create " *kokoro-pdf*")
      (erase-buffer)
      (kokoro--pdf-insert-page pdf page)
      (when skip
        (delete-region (point-min) (min (point-max) (+ (point-min) skip))))
      (when (and (< page pages) (not (kokoro--ends-sentence-p)))
        (goto-char (point-max))
        (skip-chars-backward " \t\n")
        (delete-region (point) (point-max))
        (if (looking-back "[[:alpha:]][-\u00ad\u2010\u2011¬]" (max (point-min) (- (point) 2)))
            (delete-char -1)               ; word hyphenated over the pages
          (insert " "))
        (let ((joined (point)))
          (kokoro--pdf-insert-page pdf (1+ page))
          (goto-char joined)
          (kokoro--forward-sentence (point-max))
          (if (> (- (point) joined) kokoro-max-chars)
              (delete-region joined (point-max)) ; no sentence end near: don't carry
            (setq carry (- (point) joined))
            (delete-region (point) (point-max)))))
      (message "Kokoro: page %d" page)
      (kokoro--read (if (eq from 'last)
                        (kokoro--last-sentence-start (point-min) (point-max))
                      (point-min))
                    (point-max)
                    (list :display pdf
                          :page page
                          :skip (or skip 0)
                          :next (lambda () (kokoro--pdf-next pdf page carry))
                          :prev (and (> page 1)
                                     (lambda (from) (kokoro--pdf-previous pdf page from)))
                          :progress (lambda () (format "page %d/%d" page pages)))))))

(defun kokoro--pdf-next (pdf page carry)
  (when (and (buffer-live-p pdf)
             (< page (with-current-buffer pdf (pdf-info-number-of-pages))))
    (when-let* ((win (get-buffer-window pdf t)))
      (with-selected-window win (pdf-view-goto-page (1+ page) win)))
    (kokoro--read-pdf-page pdf (1+ page) carry)
    t))

(defun kokoro--pdf-previous (pdf page from)
  "Read the page before PAGE of PDF, FROM its start or `last' sentence."
  (when (buffer-live-p pdf)
    (when-let* ((win (get-buffer-window pdf t)))
      (with-selected-window win (pdf-view-goto-page (1- page) win)))
    (kokoro--read-pdf-page pdf (1- page) nil from)))

(defun kokoro--pdf-boxes (beg end)
  "Boxes covering the text from BEG to END on its PDF pages.
Return an alist (PAGE . BOXES), one box (LEFT TOP RIGHT BOTTOM) per line."
  (let (lines line)
    (cl-loop for pos from beg below end
             for place = (get-text-property pos 'kokoro-pdf)
             unless (or (null place) (memq (char-after pos) '(?\s ?\t ?\n)))
             do (pcase-let ((`(,page ,l ,top ,r ,bottom) place))
                  (if (and line (= page (car line))
                           (< (nth 2 line) (/ (+ top bottom) 2) (nth 4 line)))
                      (setq line (list page (min l (nth 1 line)) (min top (nth 2 line))
                                       (max r (nth 3 line)) (max bottom (nth 4 line))))
                    (when line (push line lines))
                    (setq line (list page l top r bottom)))))
    (when line (push line lines))
    (let (pages)
      (dolist (box (nreverse lines))
        (push (cdr box) (alist-get (car box) pages)))
      (mapcar (lambda (p) (cons (car p) (nreverse (cdr p)))) pages))))

(defun kokoro--pdf-marks (boxes)
  "The rectangles to draw for BOXES, by `kokoro-pdf-highlight-style'."
  (if (eq kokoro-pdf-highlight-style 'underline)
      (mapcar (pcase-lambda (`(,left ,top ,right ,bottom))
                ;; A thin bar just under the line, a tenth of its height.
                (let ((thick (max 0.002 (* 0.1 (- bottom top)))))
                  (list left bottom right (+ bottom thick))))
              boxes)
    boxes))

(defun kokoro--pdf-blend (color opacity)
  "COLOR as it looks at OPACITY over the page, white (or black at night)."
  (let ((paper (if (bound-and-true-p pdf-view-midnight-minor-mode) 0.0 1.0)))
    (apply #'format "#%02x%02x%02x"
           (mapcar (lambda (c) (round (* 255 (+ (* c opacity) (* paper (- 1 opacity))))))
                   (if (string-match "\\`#\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\([[:xdigit:]]\\{2\\}\\)\\'" color)
                       (mapcar (lambda (i) (/ (string-to-number (match-string i color) 16) 255.0))
                               '(1 2 3))
                     (color-name-to-rgb color))))))

(defun kokoro--pdf-text-color ()
  "Color of the words on the page: black, or the night color."
  (if (and (bound-and-true-p pdf-view-midnight-minor-mode)
           (consp (bound-and-true-p pdf-view-midnight-colors)))
      (car pdf-view-midnight-colors)
    "black"))

(defun kokoro--pdf-show-boxes (page boxes)
  "Show PAGE in the selected window with BOXES highlighted."
  (let* ((width (car (pdf-view-image-size)))
         (underline (eq kokoro-pdf-highlight-style 'underline))
         (opacity (min 1.0 (if underline
                               (* 2 kokoro-pdf-highlight-opacity)
                             kokoro-pdf-highlight-opacity)))
         (color (kokoro--pdf-blend kokoro-pdf-highlight-color opacity)))
    (pdf-view-display-image
     (pdf-view-create-image
         (if underline
             (pdf-info-renderpage-highlight
              page width nil
              `(,color ,color 1.0 ,@(kokoro--pdf-marks boxes)))
           ;; Like a text selection, with the words drawn again on top in
           ;; their own color: a pale marker, with no outline.  (pdf-tools
           ;; draws a solid outline around see-through boxes.)
           (pdf-info-renderpage-text-regions
            page width t 'glyph nil
            `(,(kokoro--pdf-text-color) ,color ,@boxes)))
       :width width)
     (and (bound-and-true-p pdf-view-roll-minor-mode) page))))

(defun kokoro--pdf-highlight (pdf beg end)
  "Highlight the text from BEG to END on the pages of PDF on screen."
  (let ((boxes (with-current-buffer (marker-buffer beg) (kokoro--pdf-boxes beg end))))
    (dolist (win (get-buffer-window-list pdf nil t))
      (with-selected-window win
        (condition-case err
            (let* ((page (image-mode-window-get 'page win))
                   (here (alist-get page boxes)))
              (if here
                  (kokoro--pdf-show-boxes page here)
                (pdf-view-redisplay win)))
          (error (message "Kokoro: cannot highlight the page: %s"
                          (error-message-string err))))))))

;;;; Header line

(defconst kokoro--header '(:eval (kokoro--header-line))
  "The part of `header-line-format' that shows the controls.")

(defvar-local kokoro--saved-header nil
  "(LOCAL . FORMAT): the header line before `kokoro-mode', and whether it was local.")
(defvar-local kokoro--auto-mode nil
  "Non-nil if `kokoro-mode' was turned on by reading, to be turned off after.")

(defun kokoro--header-installed-p ()
  (and (consp header-line-format) (eq (car header-line-format) kokoro--header)))

(defun kokoro--install-header ()
  "Show the controls in place of the buffer's header line, unless there.
The header line it had (e.g. the book and chapter title) comes back after."
  (unless (kokoro--header-installed-p)
    (setq kokoro--saved-header (cons (local-variable-p 'header-line-format) header-line-format))
    (setq-local header-line-format (list kokoro--header))))

;;;###autoload
(define-minor-mode kokoro-mode
  "Show Kokoro reading controls in the header line.
It is turned on in the buffer being read, unless `kokoro-header-line' is nil."
  :lighter nil
  (if kokoro-mode
      (kokoro--install-header)
    (when kokoro--saved-header
      (if (car kokoro--saved-header)
          (setq-local header-line-format (cdr kokoro--saved-header))
        (kill-local-variable 'header-line-format))
      (setq kokoro--saved-header nil))))

(defun kokoro--ui-start (buf)
  "Show the controls in BUF, which is about to be read."
  (unless (eq buf kokoro--ui-buffer)
    (kokoro--ui-end))
  (setq kokoro--ui-buffer buf)
  (when (and kokoro-header-line (buffer-live-p buf))
    (with-current-buffer buf
      (if kokoro-mode
          (kokoro--install-header)      ; nov replaces it at each chapter
        (kokoro-mode 1)
        (setq kokoro--auto-mode t)))))

(defun kokoro--ui-end ()
  "Take the controls and the PDF highlight away once reading is over."
  (let ((buf kokoro--ui-buffer))
    (setq kokoro--ui-buffer nil)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when kokoro--auto-mode
          (kokoro-mode -1)
          (setq kokoro--auto-mode nil))
        (when (derived-mode-p 'pdf-view-mode)
          (dolist (win (get-buffer-window-list buf nil t))
            (ignore-errors (pdf-view-redisplay win))))))
    (force-mode-line-update t)))

(defun kokoro--button (label command help)
  "A header-line button showing LABEL that runs COMMAND when clicked."
  (propertize label
              'mouse-face 'mode-line-highlight
              'help-echo help
              'local-map (let ((map (make-sparse-keymap)))
                           (keymap-set map "<header-line> <mouse-1>"
                                       (lambda (event)
                                         (interactive "e")
                                         (with-selected-window (posn-window (event-start event))
                                           (call-interactively command))))
                           map)))

(defun kokoro--progress ()
  "Where the reading is, e.g. \"page 3/12\" or \"chapter 2/9, 41%\"."
  (let* ((s kokoro--session)
         (where (and (plist-get s :progress) (funcall (plist-get s :progress))))
         (entry kokoro--current)
         (buf (and entry (marker-buffer (nth 1 entry))))
         (percent (and buf (eq buf (plist-get s :display))
                       (with-current-buffer buf
                         (format "%d%%" (/ (* 100 (- (nth 1 entry) (point-min)))
                                           (max 1 (- (point-max) (point-min)))))))))
    (string-join (delq nil (list where percent)) ", ")))

(defun kokoro--header-line ()
  "The controls shown by `kokoro-mode'."
  (let ((reading (and kokoro--session (eq (current-buffer) kokoro--ui-buffer))))
    (string-replace
     "%" "%%"
     (concat
      (propertize " Kokoro " 'face 'bold)
      (if reading
          (concat (kokoro--button "[Prev]" #'kokoro-previous "Go back one sentence") " "
                  (if kokoro--paused
                      (kokoro--button "[Resume]" #'kokoro-pause "Resume reading")
                    (kokoro--button "[Pause]" #'kokoro-pause "Pause reading"))
                  " "
                  (kokoro--button "[Next]" #'kokoro-next "Skip to the next sentence") " "
                  (kokoro--button "[Stop]" #'kokoro-stop "Stop reading"))
        (concat (kokoro--button "[Read from here]" #'kokoro-read-dwim
                                "Read the region, or from point on")
                " "
                (kokoro--button "[Read all]" #'kokoro-read-buffer "Read the whole buffer")))
      "  "
      (kokoro--button (format "[Voice: %s]" (kokoro--voice)) #'kokoro-select-voice
                      "Choose the voice (C-u: for this file only)")
      " "
      (kokoro--button (format "[Speed: %.1f]" (kokoro--speed)) #'kokoro-set-speed
                      "Set the speed (C-u: for this file only)")
      (when reading
        (concat "  " (if kokoro--ready (kokoro--progress) "loading the voice...")))))))

;;;; Commands

;;;###autoload
(defun kokoro-read-region (beg end)
  "Read the text between BEG and END aloud."
  (interactive "r")
  (kokoro--read beg end))

;;;###autoload
(defun kokoro-read-from-point ()
  "Read from the sentence at point to the end of the buffer (or book)."
  (interactive)
  (kokoro--read (kokoro--sentence-start) (point-max) (kokoro--book-props)))

;;;###autoload
(defun kokoro-read-buffer ()
  "Read the whole buffer, book or PDF aloud."
  (interactive)
  (if (derived-mode-p 'pdf-view-mode)
      (progn (pdf-view-goto-page 1)
             (kokoro--read-pdf-page (current-buffer) 1))
    (kokoro--read (point-min) (point-max) (kokoro--book-props))))

;;;###autoload
(defun kokoro-read-paragraph ()
  "Read the paragraph at point aloud."
  (interactive)
  (let ((bounds (or (bounds-of-thing-at-point 'paragraph)
                    (user-error "No paragraph here"))))
    (kokoro--read (car bounds) (cdr bounds))))

;;;###autoload
(defun kokoro-read-string (string &optional display)
  "Read STRING aloud.
DISPLAY is the buffer to show the controls in."
  (interactive "sRead aloud: ")
  (with-current-buffer (get-buffer-create " *kokoro-text*")
    (erase-buffer)
    (insert string)
    (kokoro--read (point-min) (point-max) (and display (list :display display)))))

;;;###autoload
(defun kokoro-read-dwim ()
  "Read the region aloud; without one, read from point on.
In a PDF, read the selected text, or the pages from the current one on."
  (interactive)
  (cond
   ((derived-mode-p 'pdf-view-mode)
    (if (pdf-view-active-region-p)
        (kokoro-read-string (string-join (pdf-view-active-region-text) "\n")
                            (current-buffer))
      ;; `pdf-view-current-page' is a macro, so it cannot be called from
      ;; code compiled without pdf-tools; this is what it expands to.
      (kokoro--read-pdf-page (current-buffer) (image-mode-window-get 'page))))
   ((use-region-p)
    (deactivate-mark)
    (kokoro-read-region (region-beginning) (region-end)))
   (t (kokoro-read-from-point))))

(defun kokoro-stop ()
  "Stop reading."
  (interactive)
  (kokoro--clear)
  (kokoro--ui-end)
  (message "Kokoro: stopped"))

(defun kokoro-pause ()
  "Pause reading, or resume it."
  (interactive)
  (unless kokoro--session
    (user-error "Kokoro is not reading"))
  (setq kokoro--paused (not kokoro--paused))
  (kokoro--send (list :cmd (if kokoro--paused "pause" "resume")))
  (force-mode-line-update t)
  (message "Kokoro: %s" (if kokoro--paused "paused" "reading")))

(defun kokoro-next ()
  "Skip to the next sentence."
  (interactive)
  (kokoro--restart (lambda (e) (goto-char (nth 2 e)))))

(defun kokoro-previous ()
  "Go back to the sentence before the one being read.
At the start of a PDF page or EPUB chapter, go back to the last
sentence of the one before."
  (interactive)
  (unless (and kokoro--current
               (kokoro--at-first-sentence-p kokoro--current)
               (kokoro--go-back 'last))
    (kokoro--restart (lambda (e)
                       (goto-char (nth 1 e))
                       (let ((sentence-end-double-space nil))
                         (backward-sentence))))))

(defun kokoro-repeat ()
  "Read the sentence being read again."
  (interactive)
  (unless kokoro--current
    (user-error "Kokoro is not reading"))
  (kokoro--again))

(defun kokoro-next-paragraph ()
  "Skip to the next paragraph.  In a PDF, skip to the next page."
  (interactive)
  (let ((entry kokoro--current)
        (s kokoro--session))
    (unless (and entry s)
      (user-error "Kokoro is not reading"))
    (if (plist-get s :page)
        (kokoro--finish t)
      (let ((start (with-current-buffer (marker-buffer (nth 2 entry))
                     (save-excursion
                       (goto-char (nth 2 entry))
                       (forward-paragraph)
                       (point)))))
        (if (kokoro--next-sentence start (plist-get s :end))
            (kokoro--restart (lambda (_) (goto-char start)))
          (kokoro--finish t))))))

(defun kokoro-previous-paragraph ()
  "Go back to the start of the paragraph, or of the one before at its start.
In a PDF, go back to the start of the page, or of the page before."
  (interactive)
  (let ((entry kokoro--current)
        (s kokoro--session))
    (unless (and entry s)
      (user-error "Kokoro is not reading"))
    (cond
     ((and (kokoro--at-first-sentence-p entry) (kokoro--go-back nil)))
     ((plist-get s :page)
      (kokoro--restart (lambda (_) (goto-char (point-min)))))
     (t
      (kokoro--restart
       (lambda (e)
         (goto-char (nth 1 e))
         (backward-paragraph)
         (unless (kokoro--next-sentence (point) (nth 1 e)) ; it was at the start
           (backward-paragraph))))))))

(defun kokoro--again ()
  "Read the current sentence again, e.g. with a new voice or speed."
  (when kokoro--current
    (kokoro--restart (lambda (e) (goto-char (nth 1 e))))))

;;;###autoload
(defun kokoro-select-voice (voice &optional local)
  "Read with VOICE from now on.
With a prefix argument (LOCAL), only in the buffer being read (or this one)."
  (interactive (list (kokoro--read-voice) current-prefix-arg))
  (kokoro--set 'kokoro-voice voice local)
  (message "Kokoro: voice %s%s" voice (if local " for this buffer" ""))
  (kokoro--again))

;;;###autoload
(defun kokoro-set-speed (speed &optional local)
  "Read at SPEED (0.5 to 2.0) from now on.
With a prefix argument (LOCAL), only in the buffer being read (or this one)."
  (interactive (list (read-number "Speed (0.5 to 2.0): " (kokoro--speed))
                     current-prefix-arg))
  (setq speed (max 0.5 (min 2.0 speed)))
  (kokoro--set 'kokoro-speed speed local)
  (message "Kokoro: speed %.1f%s" speed (if local " for this buffer" ""))
  (kokoro--again))

(defun kokoro-faster (&optional step)
  "Read faster by STEP (default 0.1)."
  (interactive)
  (kokoro-set-speed (+ (kokoro--speed) (or step 0.1))))

(defun kokoro-slower ()
  "Read slower by 0.1."
  (interactive)
  (kokoro-faster -0.1))

;;;; Saving audio

(defcustom kokoro-audio-format (if (executable-find "ffmpeg") "mp3" "wav")
  "Kind of audio file \\[kokoro-save-audio] makes, by its extension.
\"wav\", or \"mp3\", \"opus\", \"m4a\" or \"flac\", which need ffmpeg.
Opus files are the smallest; MP3 plays everywhere."
  :type '(choice (const "mp3") (const "opus") (const "m4a") (const "flac") (const "wav")
                 string))

(defvar kokoro--narrations nil
  "Narrations running in the background: lists (PROCESS NAME DONE TOTAL).")

(defun kokoro--narrations-mode-line ()
  "E.g. \" Narrating book.mp3 41%\" while audio is being saved."
  (mapconcat (lambda (n)
               (format " Narrating %s %d%%" (nth 1 n)
                       (/ (* 100 (nth 2 n)) (max 1 (nth 3 n)))))
             kokoro--narrations ""))

(defconst kokoro--narrations-entry '(:eval (kokoro--narrations-mode-line)))

(defun kokoro--export-sentences (beg end)
  "The current buffer's text from BEG to END as it is read aloud.
One sentence a line, as spoken, and an empty line after each paragraph."
  (let ((pos beg) span lines)
    (while (setq span (kokoro--next-sentence pos end))
      (when (and lines
                 (string-match-p "\n[ \t\r\f]*\n"
                                 (buffer-substring-no-properties pos (nth 0 span))))
        (push "" lines))
      (let ((text (or (nth 2 span)
                      (kokoro--text (buffer-substring-no-properties (nth 0 span) (nth 1 span))))))
        (unless (string-empty-p text)
          (push text lines)))
      (setq pos (nth 1 span)))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun kokoro--export-text (buf &optional beg end)
  "BUF's text (or from BEG to END) as `kokoro--export-sentences' gives it.
In a PDF, every page without its margins; in an EPUB, every chapter."
  (kokoro--apply-source buf)
  (let ((kokoro--session (list :display buf))) ; its own left-out text
    (with-current-buffer buf
      (cond
       ((derived-mode-p 'pdf-view-mode)
        (with-temp-buffer
          (dotimes (i (with-current-buffer buf (pdf-info-number-of-pages)))
            (kokoro--pdf-insert-page buf (1+ i))
            (insert "\n"))
          (kokoro--export-sentences (point-min) (point-max))))
       ((and (derived-mode-p 'nov-mode) (not beg))
        (let ((index nov-documents-index)
              (here (point))
              chapters)
          (unwind-protect
              (dotimes (i (length nov-documents))
                (message "Kokoro: preparing chapter %d/%d..." (1+ i) (length nov-documents))
                (nov-goto-document i)
                (push (kokoro--export-sentences (point-min) (point-max)) chapters))
            (nov-goto-document index)
            (goto-char here))
          (mapconcat #'identity (nreverse (delete "" chapters)) "\n\n")))
       (t (kokoro--export-sentences (or beg (point-min)) (or end (point-max))))))))

(defun kokoro--audio-name (name)
  "NAME with the extension of `kokoro-audio-format'."
  (concat (file-name-sans-extension name) "." kokoro-audio-format))

(defun kokoro--narrate (args output voice speed &optional delete)
  "Run the narrate script with ARGS into OUTPUT, with VOICE and SPEED.
DELETE is a file to delete once it is done."
  (let* ((process-environment (cons "PYTHONIOENCODING=utf-8" process-environment))
         (name (file-name-nondirectory output))
         (buffer (get-buffer-create "*kokoro-narrate*"))
         (proc
          (make-process
           :name "kokoro-narrate"
           :buffer buffer
           :command (append (list kokoro-python kokoro-narrate-script) args
                            (list "-o" output "-v" voice "-s" (number-to-string speed)))
           :noquery t
           :filter (lambda (proc string)
                     (when (buffer-live-p (process-buffer proc))
                       (with-current-buffer (process-buffer proc)
                         (goto-char (point-max))
                         (insert string)))
                     (when-let* ((entry (assq proc kokoro--narrations))
                                 ((string-match "\\(?:.*\n\\)*\\[\\([0-9]+\\)/\\([0-9]+\\)\\]"
                                                string)))
                       (setf (nth 2 entry) (string-to-number (match-string 1 string))
                             (nth 3 entry) (string-to-number (match-string 2 string)))
                       (force-mode-line-update t)))
           :sentinel (lambda (proc _event)
                       (unless (process-live-p proc)
                         (setq kokoro--narrations (assq-delete-all proc kokoro--narrations))
                         (force-mode-line-update t)
                         (when delete
                           (ignore-errors (delete-file delete)))
                         (if (zerop (process-exit-status proc))
                             (message "Kokoro: saved %s" output)
                           (message "Kokoro: saving %s failed; see *kokoro-narrate*"
                                    name)))))))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert (format "\n--- %s, %s ---\n" output (format-time-string "%F %T"))))
    (push (list proc name 0 1) kokoro--narrations)
    (unless (member kokoro--narrations-entry global-mode-string)
      (setq global-mode-string (append (or global-mode-string '("")) (list kokoro--narrations-entry))))
    (message "Kokoro: saving %s in the background (progress in the mode line)..." name)
    proc))

(defun kokoro--narrate-text (text output voice speed)
  "Narrate TEXT, prepared by `kokoro--export-text', into OUTPUT."
  (when (string-blank-p text)
    (user-error "Kokoro: there is nothing to read here"))
  (let ((lines (make-temp-file "kokoro-" nil ".txt")))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region text nil lines nil 'silent))
    (kokoro--narrate (list "--lines" lines) output voice speed lines)))

(defun kokoro--file-buffer (file)
  "A buffer showing FILE the way Emacs reads it, and whether it was made for this.
Return (BUFFER . NEW)."
  (let ((key (abbreviate-file-name (expand-file-name file))))
    (or (cl-loop for buf in (buffer-list)
                 when (equal (with-current-buffer buf (kokoro--source-key)) key)
                 return (cons buf nil))
        (cons (find-file-noselect file) t))))

;;;###autoload
(defun kokoro-save-audio (file output)
  "Narrate FILE into the audio file OUTPUT, in the background.
The text is cleaned the way it is read aloud: `kokoro-pronunciations',
left-out text, PDF margins, skipped code blocks and so on, and read with
the voice and speed of the file.  FILE can be any text file, an EPUB
(with nov.el) or a PDF (with pdf-tools); Word files are read by the
script.  The kind of audio file is OUTPUT's extension; see
`kokoro-audio-format'."
  (interactive
   (let* ((file (read-file-name "Narrate file: " nil nil t
                                (when-let* ((key (kokoro--source-key)))
                                  (file-name-nondirectory key))))
          (output (read-file-name "Save audio as: " (file-name-directory file) nil nil
                                  (kokoro--audio-name (file-name-nondirectory file)))))
     (list (expand-file-name file) (expand-file-name output))))
  (let* ((ext (downcase (or (file-name-extension file) "")))
         (opened (unless (equal ext "docx") (kokoro--file-buffer file)))
         (buf (car opened)))
    (unwind-protect
        (cond
         ((or (null buf)
              (and (equal ext "pdf")
                   (not (with-current-buffer buf (derived-mode-p 'pdf-view-mode)))))
          ;; Word, or a PDF without pdf-tools: the script reads it.
          (let ((remembered (cdr (assoc (abbreviate-file-name (expand-file-name file))
                                        (and kokoro-sources-file (kokoro--sources))))))
            (kokoro--narrate (list file) output
                             (or (plist-get remembered :voice) kokoro-voice)
                             (float (or (plist-get remembered :speed) kokoro-speed)))))
         ((and (equal ext "epub") (not (with-current-buffer buf (derived-mode-p 'nov-mode))))
          (user-error "Kokoro: saving an EPUB needs nov.el"))
         (t
          (let ((text (kokoro--export-text buf)))
            (kokoro--narrate-text text output
                                  (buffer-local-value 'kokoro-voice buf)
                                  (float (buffer-local-value 'kokoro-speed buf))))))
      (when (cdr opened)
        (kill-buffer buf)))))

;;;###autoload
(defun kokoro-save-region-audio (beg end output)
  "Narrate the text between BEG and END into the audio file OUTPUT.
In a PDF, narrate the selected text."
  (interactive
   (progn
     (unless (or (use-region-p)
                 (and (derived-mode-p 'pdf-view-mode) (pdf-view-active-region-p)))
       (user-error "Kokoro: select the text to save first"))
     (list (and (use-region-p) (region-beginning)) (and (use-region-p) (region-end))
           (expand-file-name
            (read-file-name "Save audio as: " nil nil nil
                            (kokoro--audio-name
                             (file-name-nondirectory
                              (or (kokoro--source-key) (buffer-name)))))))))
  (kokoro--apply-source (current-buffer))
  (let* ((buf (current-buffer))
         (text (if beg
                   (kokoro--export-text buf beg end)
                 (with-temp-buffer
                   (insert (string-join (with-current-buffer buf (pdf-view-active-region-text))
                                        "\n"))
                   (let ((kokoro--session (list :display buf)))
                     (kokoro--export-sentences (point-min) (point-max)))))))
    (kokoro--narrate-text text output (buffer-local-value 'kokoro-voice buf)
                          (float (buffer-local-value 'kokoro-speed buf)))))

(defun kokoro-quit ()
  "Shut the speech server down."
  (interactive)
  (kokoro--clear)
  (kokoro--ui-end)
  (when (process-live-p kokoro--process)
    (kokoro--send '(:cmd "quit"))
    (delete-process kokoro--process))
  (message "Kokoro: server shut down"))

;;;###autoload (autoload 'kokoro-command-map "kokoro" nil t 'keymap)
(defvar-keymap kokoro-command-map
  :doc "Keys for reading aloud with Kokoro."
  "t" #'kokoro-read-dwim
  "r" #'kokoro-read-region
  "a" #'kokoro-read-buffer
  "." #'kokoro-read-paragraph
  "c" #'kokoro-resume
  "SPC" #'kokoro-pause
  "s" #'kokoro-stop
  "n" #'kokoro-next
  "p" #'kokoro-previous
  "," #'kokoro-repeat
  "]" #'kokoro-next-paragraph
  "[" #'kokoro-previous-paragraph
  "v" #'kokoro-select-voice
  "S" #'kokoro-set-speed
  "+" #'kokoro-faster
  "-" #'kokoro-slower
  "w" #'kokoro-save-audio
  "W" #'kokoro-save-region-audio
  "f" #'kokoro-forget-source
  "m" #'kokoro-set-pdf-margins
  "x" #'kokoro-skip-text
  "X" #'kokoro-unskip-text
  "h" #'kokoro-mode
  "q" #'kokoro-quit)
(fset 'kokoro-command-map kokoro-command-map)

(provide 'kokoro)
;;; kokoro.el ends here
