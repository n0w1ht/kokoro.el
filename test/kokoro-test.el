;;; kokoro-test.el --- Tests for kokoro -*- lexical-binding: t; -*-

;; Run with:
;;   emacs -Q --batch -L .. -l kokoro-test.el -f ert-run-tests-batch-and-exit
;;
;; The speech server is replaced by a fake that records what is sent, so
;; neither Python nor a sound card is needed.  pdf-tools is not needed
;; either: PDF text is imitated with the text property it would carry.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'kokoro)

(defun kokoro-test--spans (text &optional mode)
  "The sentences of TEXT in MODE, as (STRING SAY)."
  (with-temp-buffer
    (insert text)
    (when mode (funcall mode))
    (let ((pos (point-min)) span out)
      (while (setq span (kokoro--next-sentence pos (point-max)))
        (push (list (buffer-substring-no-properties (nth 0 span) (nth 1 span)) (nth 2 span)) out)
        (setq pos (nth 1 span)))
      (nreverse out))))

(defun kokoro-test--sentences (text &optional mode)
  (mapcar #'car (kokoro-test--spans text mode)))

;;;; Sentences

(ert-deftest kokoro-test-sentences ()
  ;; A blank line ends a sentence; a single newline does not.
  (should (equal (kokoro-test--sentences "One here. Two there!  Three?\n\nHeading\n\nLast\nline")
                 '("One here." "Two there!" "Three?" "Heading" "Last\nline")))
  ;; Pieces without words are skipped.
  (should (equal (kokoro-test--sentences "-----\n\nWords. ...") '("Words.")))
  (should-not (kokoro-test--sentences "  \n\n  ")))

(ert-deftest kokoro-test-abbreviations ()
  (should (equal (kokoro-test--sentences
                  "Dr. Smith et al. found it, e.g. in Fig. 3. Then it ended.")
                 '("Dr. Smith et al. found it, e.g. in Fig. 3." "Then it ended.")))
  ;; Only the listed words, and with their case.
  (should (equal (kokoro-test--sentences "We saw dr. Who. Fine.")
                 '("We saw dr." "Who." "Fine."))))

(ert-deftest kokoro-test-long-sentence-is-cut ()
  (let* ((kokoro-max-chars 40)
         (parts (kokoro-test--sentences (mapconcat #'identity (make-list 30 "word") " "))))
    (should (> (length parts) 1))
    (should (cl-every (lambda (p) (<= (length p) 40)) parts))))

;;;; Skipping

(ert-deftest kokoro-test-skip-org ()
  (let ((spans (kokoro-test--spans
                (concat "#+title: Notes\n"
                        "* Heading\n"
                        ":PROPERTIES:\n:ID: 123\n:END:\n"
                        "Before the code.\n"
                        "#+begin_src python\nprint('hi. there.')\n#+end_src\n"
                        "| a | b |\n|---+---|\n| 1 | 2 |\n"
                        "# a comment\n"
                        "After the table.\n")
                #'org-mode)))
    (should (equal spans '(("* Heading" nil)
                           ("Before the code." nil)
                           ("#+begin_src python\nprint('hi. there.')\n#+end_src" "Code block.")
                           ("| a | b |\n|---+---|\n| 1 | 2 |\n" "Table.")
                           ("After the table." nil))))))

(ert-deftest kokoro-test-skip-markdown ()
  ;; markdown-mode is not loaded here: pretend text-mode is it.
  (let ((kokoro-skip-rules `((text-mode ,@(alist-get 'markdown-mode kokoro-skip-rules)))))
    (should (equal (kokoro-test--spans "Run this:\n```sh\nls -la. Done.\n```\nThat lists files.\n"
                                       #'text-mode)
                   '(("Run this:" nil)
                     ("```sh\nls -la. Done.\n```" "Code block.")
                     ("That lists files." nil))))))

(ert-deftest kokoro-test-no-skipping-elsewhere ()
  (should (equal (kokoro-test--sentences "| a | b |") '("| a | b |"))))

;;;; Text

(ert-deftest kokoro-test-text ()
  (should (equal (kokoro--text "See [[https://x.org][the site]] and [docs](http://a.b).")
                 "See the site and docs."))
  (should (equal (kokoro--text "A *bold* and =code= hyphen-\nated\nline.")
                 "A bold and code hyphenated line."))
  (should (equal (kokoro--text "Go to https://example.com/x now") "Go to link now")))

(ert-deftest kokoro-test-symbols ()
  (should (equal (kokoro--text "WBC 11×10⁹/L, platelets 150–400 ×10^9/L.")
                 "WBC 11 times 10 to the 9 per liter, platelets 150 to 400 times 10 to the 9 per liter."))
  (should (equal (kokoro--text "HR 72 beats/min; 38.5 °C; BP > 140/90, K+ <3.5.")
                 "HR 72 beats per minute; 38.5 degrees Celsius; BP greater than 140/90, K+ less than 3.5."))
  ;; References in superscript are left out; Greek letters and subscripts said.
  (should (equal (kokoro--text "β-blockers cut mortality¹²,¹³ and α₁ tone.²")
                 "beta-blockers cut mortality and alpha 1 tone."))
  (should (equal (kokoro--text "2 m² and 5 μg, ↑ TSH → ↓ T4, pH = 7.4 ± 0.1, HbA1c ≥ 6.5%.")
                 "2 square meters and 5 micrograms, increased TSH leads to decreased T4, pH equals 7.4 plus or minus 0.1, HbA1c greater than or equal to 6.5%."))
  ;; Dates are not ranges; a quote mark is not a comparison.
  (should (equal (kokoro--text "On 2026-10-27, read 5-10.") "On 2026-10-27, read 5 to 10."))
  (should (equal (kokoro--text "> Quoted line") "Quoted line")))

(ert-deftest kokoro-test-pronunciations ()
  (should (equal (kokoro--text "Give 5 mg p.o. b.i.d., e.g. with food.")
                 "Give 5 milligrams by mouth twice a day, for example with food."))
  (should (equal (kokoro--text "Glucose 90 mg/dL (vs. 110 mg/dL).")
                 "Glucose 90 milligrams per deciliter (versus 110 milligrams per deciliter)."))
  ;; Whole words only, with case.
  (should (equal (kokoro--text "The kgb and MG cars.") "The kgb and MG cars."))
  (let ((kokoro-pronunciations '(("PSA" . "P S A"))))
    (should (equal (kokoro--text "PSA rose.") "P S A rose."))))

(ert-deftest kokoro-test-text-functions-are-used ()
  (let ((kokoro-text-functions (list #'upcase)))
    (should (equal (kokoro--text "loud") "LOUD"))))

;;;; Reading with a fake server

(defmacro kokoro-test--with-fake-server (&rest body)
  "Run BODY with the server replaced; `sent' holds the messages sent."
  (declare (indent 0))
  `(let ((sent nil)
         (kokoro--ready t)
         (kokoro--session nil)
         (kokoro--pending nil)
         (kokoro--current nil)
         (kokoro--ui-buffer nil)
         (kokoro-lookahead 2))
     (cl-letf (((symbol-function 'kokoro--start) #'ignore)
               ((symbol-function 'kokoro--send) (lambda (msg) (push msg sent))))
       ,@body)))

(defun kokoro-test--speaks (sent)
  (cl-remove-if-not (lambda (m) (equal (plist-get m :cmd) "speak")) (reverse sent)))

(defun kokoro-test--spoken (sent)
  (mapcar (lambda (m) (plist-get m :text)) (kokoro-test--speaks sent)))

(defun kokoro-test--play (id)
  (kokoro--handle (list :event "start" :id id)))

(defun kokoro-test--finish-all ()
  (while kokoro--pending
    (kokoro--handle (list :event "end" :id (car (car kokoro--pending))))))

(ert-deftest kokoro-test-reading-flow ()
  (kokoro-test--with-fake-server
    (with-temp-buffer
      (insert "First one. Second one. Third one. Fourth one.")
      (kokoro-read-buffer)
      ;; Only `kokoro-lookahead' sentences go out at first.
      (should (equal (kokoro-test--spoken sent) '("First one." "Second one.")))
      (let ((id (car (car kokoro--pending))))
        (kokoro-test--play id)
        (should (equal (buffer-substring (overlay-start kokoro--overlay) (overlay-end kokoro--overlay))
                       "First one."))
        (kokoro--handle (list :event "end" :id id)))
      (should (equal (kokoro-test--spoken sent) '("First one." "Second one." "Third one.")))
      ;; Skipping ahead stops the server and reads on after the sentence playing.
      (kokoro-test--play (car (car kokoro--pending)))
      (setq sent nil)
      (kokoro-next)
      (should (equal (plist-get (car (last sent)) :cmd) "stop"))
      (should (equal (kokoro-test--spoken sent) '("Third one." "Fourth one.")))
      (kokoro-test--finish-all)
      (should-not kokoro--session))))

(ert-deftest kokoro-test-skipped-part-is-announced ()
  (kokoro-test--with-fake-server
    (with-temp-buffer
      (insert "Intro.\n#+begin_src elisp\n(car x)\n#+end_src\nOutro.\n")
      (org-mode)
      (let ((kokoro-lookahead 5))
        (kokoro-read-buffer))
      (should (equal (kokoro-test--spoken sent) '("Intro." "Code block." "Outro."))))))

(ert-deftest kokoro-test-read-from-point-starts-at-sentence ()
  (kokoro-test--with-fake-server
    (with-temp-buffer
      (insert "Alpha beta. Gamma delta epsilon. Zeta.")
      (goto-char (point-min))
      (search-forward "delta")
      (kokoro-read-from-point)
      (should (equal (car (kokoro-test--spoken sent)) "Gamma delta epsilon.")))))

(ert-deftest kokoro-test-continues-to-next-part ()
  (kokoro-test--with-fake-server
    (let ((parts 0))
      (with-temp-buffer
        (insert "Only sentence.")
        (kokoro--read (point-min) (point-max)
                      (list :next (lambda () (cl-incf parts) nil)))
        (kokoro-test--finish-all)
        (should (= parts 1))
        (should-not kokoro--session)))))

;;;; Voice and speed

(ert-deftest kokoro-test-buffer-local-voice ()
  (kokoro-test--with-fake-server
    (let ((kokoro-voice "af_heart")
          (kokoro-speed 1.0))
      (with-temp-buffer
        (insert "One. Two. Three.")
        (kokoro-read-buffer)
        (kokoro-test--play (car (car kokoro--pending)))
        (setq sent nil)
        (kokoro-select-voice "bm_george" t)
        ;; Only this buffer changed, and the sentence is read again with it.
        (should (equal kokoro-voice "bm_george"))
        (should (equal (default-value 'kokoro-voice) "af_heart"))
        (should (equal (plist-get (car (kokoro-test--speaks sent)) :voice) "bm_george"))
        (should (equal (plist-get (car (kokoro-test--speaks sent)) :text) "One."))
        ;; Speed changes keep to the buffer that has its own value.
        (setq-local kokoro-speed 1.2)
        (kokoro-faster)
        (should (= kokoro-speed 1.3))
        (should (= (default-value 'kokoro-speed) 1.0))
        (kokoro-set-speed 9)
        (should (= kokoro-speed 2.0))))))

(defmacro kokoro-test--with-sources (&rest body)
  "Run BODY with an empty sources file, bound to `sources-file'."
  (declare (indent 0))
  `(let* ((sources-file (make-temp-file "kokoro-sources-" nil ".eld"))
          (kokoro-sources-file sources-file)
          (kokoro--sources 'unread)
          (kokoro-voice "af_heart")
          (kokoro-speed 1.0)
          (book (make-temp-file "kokoro-book-" nil ".txt" "One. Two. Three.")))
     (delete-file sources-file)
     (unwind-protect (progn ,@body)
       (dolist (f (list sources-file book))
         (when (file-exists-p f) (delete-file f))))))

(ert-deftest kokoro-test-sources-remembered ()
  (kokoro-test--with-fake-server
    (kokoro-test--with-sources
      ;; Choose a voice and speed for the file...
      (with-current-buffer (find-file-noselect book)
        (kokoro-read-buffer)
        (kokoro-select-voice "bm_george" t)
        (kokoro-set-speed 0.8 t)
        (kokoro-stop)
        (kill-buffer))
      (should (file-exists-p sources-file))
      ;; ...and they come back, also after Emacs forgets everything.
      (setq kokoro--sources 'unread)
      (with-current-buffer (find-file-noselect book)
        (should (equal kokoro-voice "af_heart")) ; not before reading
        (setq sent nil)
        (kokoro-read-buffer)
        (should (equal kokoro-voice "bm_george"))
        (should (= kokoro-speed 0.8))
        (should (equal (plist-get (car (kokoro-test--speaks sent)) :voice) "bm_george"))
        (should (= (plist-get (car (kokoro-test--speaks sent)) :speed) 0.8))
        ;; The usual voice is untouched.
        (should (equal (default-value 'kokoro-voice) "af_heart"))
        ;; Forgetting goes back to it, in the buffer and in the file.
        (kokoro-forget-source)
        (should (equal kokoro-voice "af_heart"))
        (kokoro-stop)
        (kill-buffer))
      (setq kokoro--sources 'unread)
      (should-not (kokoro--sources)))))

(ert-deftest kokoro-test-skip-text-per-file ()
  (kokoro-test--with-fake-server
    (kokoro-test--with-sources
      (with-temp-file book
        (insert "Emmaus,{1.42} situated near Jerusalem [3]. They talked."))
      (let ((kokoro-remove-regexps '("\\[[0-9]+\\]")))  ; for every file
        (with-current-buffer (find-file-noselect book)
          (kokoro-skip-text "{[0-9.]+}")
          (setq sent nil)
          (let ((kokoro-lookahead 5)) (kokoro-read-buffer))
          (should (equal (kokoro-test--spoken sent)
                         '("Emmaus, situated near Jerusalem ." "They talked.")))
          (kokoro-stop)
          (kill-buffer))
        ;; Remembered for the file, and only for it.
        (setq kokoro--sources 'unread)
        (with-current-buffer (find-file-noselect book)
          (setq sent nil)
          (kokoro-read-buffer)
          (should (equal (car (kokoro-test--spoken sent)) "Emmaus, situated near Jerusalem ."))
          ;; Reading it again starts over at the sentence playing.
          (kokoro-test--play (car (car kokoro--pending)))
          (setq sent nil)
          (kokoro-unskip-text "{[0-9.]+}")
          (should (equal (car (kokoro-test--spoken sent))
                         "Emmaus,{1.42} situated near Jerusalem ."))
          (kokoro-stop)
          (kill-buffer))
        (with-temp-buffer
          (insert "Other {2.1} text.")
          (setq sent nil)
          (kokoro-read-buffer)
          (should (equal (kokoro-test--spoken sent) '("Other {2.1} text.")))
          (kokoro-stop))))))

(ert-deftest kokoro-test-skip-text-checks-regexp ()
  (should-error (kokoro--check-regexp "[0-9") :type 'user-error)
  (should-error (kokoro--check-regexp "x*") :type 'user-error)
  (should-not (kokoro--check-regexp "{[0-9.]+}")))

(ert-deftest kokoro-test-sources-not-for-plain-buffers ()
  (kokoro-test--with-fake-server
    (kokoro-test--with-sources
      (with-temp-buffer
        (insert "No file.")
        (kokoro-read-buffer)
        (kokoro-select-voice "bf_emma" t)
        (should (equal kokoro-voice "bf_emma"))
        (kokoro-stop))
      (should-not (file-exists-p sources-file)))))

;;;; Resuming

(ert-deftest kokoro-test-resume-text-file ()
  (kokoro-test--with-fake-server
    (kokoro-test--with-sources
      (with-current-buffer (find-file-noselect book)
        (kokoro-read-buffer)
        (kokoro-test--play (car (car kokoro--pending)))
        (kokoro--handle (list :event "end" :id (car (car kokoro--pending))))
        (kokoro-test--play (car (car kokoro--pending))) ; "Two."
        (kokoro-stop)
        (kill-buffer))
      ;; Written when reading stopped, and found after a restart.
      (setq kokoro--sources 'unread)
      (with-current-buffer (find-file-noselect book)
        (setq sent nil)
        (kokoro-resume)
        (should (equal (kokoro-test--spoken sent) '("Two." "Three.")))
        (kokoro-stop)
        (kill-buffer))
      ;; Elsewhere it asks which file, and opens it there.
      (with-temp-buffer
        (setq sent nil)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt table &rest _)
                     (car (all-completions "" table)))))
          (kokoro-resume))
        (should (equal (buffer-file-name) (expand-file-name book)))
        (should (equal (car (kokoro-test--spoken sent)) "Two."))
        (kokoro-stop)
        (kill-buffer (find-buffer-visiting book))))))

(ert-deftest kokoro-test-resume-not-remembered ()
  (kokoro-test--with-fake-server
    (kokoro-test--with-sources
      ;; Plain buffers, and kokoro-remember-place nil, keep no place.
      (with-temp-buffer
        (insert "One. Two.")
        (kokoro-read-buffer)
        (kokoro-test--play (car (car kokoro--pending)))
        (kokoro-stop))
      (let ((kokoro-remember-place nil))
        (with-current-buffer (find-file-noselect book)
          (kokoro-read-buffer)
          (kokoro-test--play (car (car kokoro--pending)))
          (kokoro-stop)
          (kill-buffer)))
      (should-not (kokoro--sources))
      (should-error (kokoro-resume) :type 'user-error))))

(ert-deftest kokoro-test-resume-epub-uses-nov-file-name ()
  (kokoro-test--with-fake-server
    (kokoro-test--with-sources
      (let ((chapters ["Chapter one. Ends here." "Chapter two. Middle part. Last part."])
            (gone-to nil))
        (with-temp-buffer
          ;; Imitate nov: no buffer-file-name, the EPUB in nov-file-name.
          (setq-local nov-file-name book)
          (setq-local nov-documents (vector 'a 'b))
          (setq-local nov-documents-index 1)
          (insert (aref chapters 1))
          (cl-letf (((symbol-function 'derived-mode-p)
                     (lambda (&rest modes) (memq 'nov-mode modes)))
                    ((symbol-function 'nov-goto-document)
                     (lambda (i)
                       (setq gone-to i nov-documents-index i)
                       (erase-buffer)
                       (insert (aref chapters i)))))
            (kokoro-read-buffer)
            (kokoro--handle (list :event "end" :id (car (car kokoro--pending))))
            (kokoro-test--play (car (car kokoro--pending))) ; "Middle part."
            (kokoro-stop)
            (should (equal (plist-get (plist-get (cdr (assoc (abbreviate-file-name book)
                                                              (kokoro--sources)))
                                                  :place)
                                      :chapter)
                           1))
            ;; Reopened at another chapter: it goes back to chapter two.
            (nov-goto-document 0)
            (setq sent nil)
            (kokoro-resume)
            (should (= gone-to 1))
            (should (equal (car (kokoro-test--spoken sent)) "Middle part."))
            (kokoro-stop)))))))

(ert-deftest kokoro-test-resume-pdf-page ()
  (kokoro-test--with-fake-server
    (kokoro-test--with-sources
      (let ((pages '((1 . "Page one.") (2 . "Start of two. Then more. End.")))
            (shown nil))
        (cl-letf (((symbol-function 'pdf-info-number-of-pages) (lambda () 2))
                  ((symbol-function 'pdf-view-goto-page) (lambda (p &rest _) (setq shown p)))
                  ((symbol-function 'pdf-info-charlayout)
                   (lambda (page)
                     (mapcar (lambda (c) (list c '(0.1 0.5 0.2 0.52))) (alist-get page pages)))))
          (with-current-buffer (find-file-noselect book)
            (cl-letf (((symbol-function 'derived-mode-p)
                       (lambda (&rest modes) (memq 'pdf-view-mode modes))))
              (kokoro--read-pdf-page (current-buffer) 2)
              (kokoro--handle (list :event "end" :id (car (car kokoro--pending))))
              (kokoro-test--play (car (car kokoro--pending))) ; "Then more."
              (kokoro-stop)
              (setq kokoro--sources 'unread)
              (setq sent nil)
              (kokoro-resume)
              (should (= shown 2))
              (should (equal (kokoro-test--spoken sent) '("Then more." "End.")))
              ;; Going on from the resumed place notes the right offset.
              (kokoro--handle (list :event "end" :id (car (car kokoro--pending))))
              (kokoro-test--play (car (car kokoro--pending))) ; "End."
              (kokoro-stop)
              (setq sent nil)
              (kokoro-resume)
              (should (equal (kokoro-test--spoken sent) '("End.")))
              (kokoro-stop))
            (kill-buffer)))))))

;;;; Moving about

(ert-deftest kokoro-test-repeat-and-paragraphs ()
  (kokoro-test--with-fake-server
    (with-temp-buffer
      (insert "One a. One b.\n\nTwo a. Two b.\n\nThree a.")
      (kokoro-read-buffer)
      (kokoro-test--play (car (car kokoro--pending)))           ; One a.
      (setq sent nil)
      (kokoro-repeat)
      (should (equal (car (kokoro-test--spoken sent)) "One a."))
      (kokoro-test--play (car (car kokoro--pending)))
      (setq sent nil)
      (kokoro-next-paragraph)
      (should (equal (car (kokoro-test--spoken sent)) "Two a."))
      (kokoro--handle (list :event "end" :id (car (car kokoro--pending))))
      (kokoro-test--play (car (car kokoro--pending)))           ; Two b.
      ;; Back to the start of this paragraph, then to the one before.
      (setq sent nil)
      (kokoro-previous-paragraph)
      (should (equal (car (kokoro-test--spoken sent)) "Two a."))
      (kokoro-test--play (car (car kokoro--pending)))
      (setq sent nil)
      (kokoro-previous-paragraph)
      (should (equal (car (kokoro-test--spoken sent)) "One a."))
      ;; From the last paragraph, skipping on ends the reading.
      (kokoro-stop)
      (goto-char (point-max))
      (kokoro-read-paragraph)
      (kokoro-test--play (car (car kokoro--pending)))
      (kokoro-next-paragraph)
      (should-not kokoro--session))
    (should-error (kokoro-repeat) :type 'user-error)))

(ert-deftest kokoro-test-pdf-back-and-forth-across-pages ()
  (kokoro-test--with-fake-server
    (let ((pages '((1 . "First page. Its end.") (2 . "Second page. More here.")))
          (pdf (generate-new-buffer "pdf")))
      (cl-letf (((symbol-function 'pdf-info-number-of-pages) (lambda () 2))
                ((symbol-function 'pdf-info-charlayout)
                 (lambda (page)
                   (mapcar (lambda (c) (list c '(0.1 0.5 0.2 0.52))) (alist-get page pages)))))
        (unwind-protect
            (progn
              (kokoro--read-pdf-page pdf 2)
              (kokoro-test--play (car (car kokoro--pending)))   ; Second page.
              ;; Previous at the top of a page: last sentence of the one before.
              (setq sent nil)
              (kokoro-previous)
              (should (= (plist-get kokoro--session :page) 1))
              (should (equal (kokoro-test--spoken sent) '("Its end.")))
              (kokoro-test--play (car (car kokoro--pending)))
              ;; ] turns the page; [ at its top goes to the start of the one before.
              (setq sent nil)
              (kokoro-next-paragraph)
              (should (= (plist-get kokoro--session :page) 2))
              (kokoro-test--play (car (car kokoro--pending)))
              (setq sent nil)
              (kokoro-previous-paragraph)
              (should (= (plist-get kokoro--session :page) 1))
              (should (equal (car (kokoro-test--spoken sent)) "First page."))
              ;; On page 1 there is nothing before: previous stays on it.
              (kokoro-test--play (car (car kokoro--pending)))
              (kokoro-previous)
              (should (= (plist-get kokoro--session :page) 1)))
          (kokoro-stop)
          (kill-buffer pdf))))))

(ert-deftest kokoro-test-epub-previous-chapter ()
  (kokoro-test--with-fake-server
    (let ((chapters ["One first. One last." "Two first. Two last."]))
      (with-temp-buffer
        (setq-local nov-documents (vector 'a 'b))
        (setq-local nov-documents-index 1)
        (insert (aref chapters 1))
        (cl-letf (((symbol-function 'derived-mode-p)
                   (lambda (&rest modes) (memq 'nov-mode modes)))
                  ((symbol-function 'nov-previous-document)
                   (lambda ()
                     (setq nov-documents-index (1- nov-documents-index))
                     (erase-buffer)
                     (insert (aref chapters nov-documents-index)))))
          (kokoro-read-buffer)
          (kokoro-test--play (car (car kokoro--pending)))
          (setq sent nil)
          (kokoro-previous)
          (should (= nov-documents-index 0))
          (should (equal (kokoro-test--spoken sent) '("One last.")))
          ;; Chapter one has none before it.
          (should-not (plist-get kokoro--session :prev))
          (kokoro-stop))))))

;;;; Voice description

(ert-deftest kokoro-test-voice-description ()
  (should (equal (kokoro--voice-description "af_heart") "American English, female"))
  (should (equal (kokoro--voice-description "bm_george") "British English, male"))
  (should (equal (kokoro--voice-description "xx") "Other")))

;;;; Header line

(ert-deftest kokoro-test-header-line ()
  (kokoro-test--with-fake-server
    (with-temp-buffer
      (setq-local header-line-format "Chapter title")
      (insert "One sentence. Another one.")
      (kokoro-read-buffer)
      (should kokoro-mode)
      ;; The controls take the place of the header line the buffer had.
      (should (equal header-line-format (list kokoro--header)))
      (kokoro-test--play (car (car kokoro--pending)))
      (let ((line (kokoro--header-line)))
        (should (string-match-p "\\[Pause\\]" line))
        (should (string-match-p "Voice: af_heart" line))
        ;; Progress comes last, escaped for the header line.
        (should (string-match-p "\\[Speed: 1\\.0\\]  0%%\\'" line))
        (should (get-text-property (string-search "[Stop]" line) 'local-map line)))
      (kokoro-pause)
      (should (string-match-p "\\[Resume\\]" (kokoro--header-line)))
      (kokoro-stop)
      (should-not kokoro-mode)
      (should (equal header-line-format "Chapter title")))))

;;;; PDF

(defun kokoro-test--pdf-text (lines page)
  "Insert LINES as PDF text of PAGE: line N sits at height N/10."
  (cl-loop for line in lines
           for n from 1
           do (cl-loop for ch across (concat line "\n")
                       for x from 0
                       do (insert (propertize (char-to-string ch) 'kokoro-pdf
                                              (list page (* x 0.01) (* n 0.1)
                                                    (* (1+ x) 0.01) (+ (* n 0.1) 0.05)))))))

(ert-deftest kokoro-test-pdf-boxes ()
  (with-temp-buffer
    (kokoro-test--pdf-text '("Abc def" "ghi.") 4)
    ;; One box per line, around the characters that are not spaces.
    (should (equal (kokoro-test--round (kokoro--pdf-boxes (point-min) (point-max)))
                   '((4 (0.0 0.1 0.07 0.15) (0.0 0.2 0.04 0.25)))))
    ;; Part of a line.
    (should (equal (kokoro-test--round (kokoro--pdf-boxes 5 8)) '((4 (0.04 0.1 0.07 0.15)))))))

(defun kokoro-test--round (boxes)
  (mapcar (lambda (page)
            (cons (car page)
                  (mapcar (lambda (box) (mapcar (lambda (x) (/ (fround (* x 100)) 100)) box))
                          (cdr page))))
          boxes))

(ert-deftest kokoro-test-pdf-page-margins-and-numbers ()
  (let ((kokoro-pdf-margins '(0.1 . 0.1))
        (layout (lambda (_page)
                  ;; A header at the top, a page number at the bottom.
                  (append (mapcar (lambda (c) (list c '(0.1 0.02 0.2 0.04))) "Running header")
                          (list (list ?\n '(0.2 0.02 0.2 0.04)))
                          (mapcar (lambda (c) (list c '(0.1 0.5 0.2 0.52))) "Body text.")
                          (list (list ?\n '(0.2 0.5 0.2 0.52)))
                          (mapcar (lambda (c) (list c '(0.5 0.85 0.6 0.87))) "12")))))
    (cl-letf (((symbol-function 'pdf-info-charlayout) layout))
      (with-temp-buffer
        (kokoro--pdf-insert-page (current-buffer) 1)
        (should (equal (string-trim (buffer-string)) "Body text."))
        (goto-char (point-min))
        (search-forward "B")
        (should (equal (get-text-property (1- (point)) 'kokoro-pdf) '(1 0.1 0.5 0.2 0.52)))))))

(ert-deftest kokoro-test-pdf-margins-per-file ()
  (kokoro-test--with-fake-server
    (kokoro-test--with-sources
      (let ((kokoro-pdf-margins '(0.06 . 0.06))
            (other (make-temp-file "kokoro-other-" nil ".pdf")))
        (cl-letf (((symbol-function 'pdf-info-number-of-pages) (lambda () 1))
                  ((symbol-function 'pdf-info-charlayout)
                   (lambda (_page)
                     ;; "Header." at 10% of the height, "Body." at 50%.
                     (append (mapcar (lambda (c) (list c '(0.1 0.10 0.2 0.12))) "Header. ")
                             (mapcar (lambda (c) (list c '(0.1 0.50 0.2 0.52))) "Body.")))))
          (unwind-protect
              (progn
                ;; With the usual margins the header is read.
                (with-current-buffer (find-file-noselect book)
                  (setq sent nil)
                  (kokoro--read-pdf-page (current-buffer) 1)
                  (should (equal (kokoro-test--spoken sent) '("Header." "Body.")))
                  ;; This PDF leaves out its top 15%.
                  (kokoro-set-pdf-margins 15 5)
                  (should (equal kokoro-pdf-margins '(0.15 . 0.05)))
                  (kokoro-stop)
                  (kill-buffer))
                ;; Remembered: a new buffer of it, after a restart, leaves it out.
                (setq kokoro--sources 'unread)
                (with-current-buffer (find-file-noselect book)
                  (setq sent nil)
                  (kokoro--read-pdf-page (current-buffer) 1)
                  (should (equal (kokoro-test--spoken sent) '("Body.")))
                  (kokoro-stop)
                  (kill-buffer))
                ;; Other PDFs keep the usual margins.
                (with-current-buffer (find-file-noselect other)
                  (setq sent nil)
                  (kokoro--read-pdf-page (current-buffer) 1)
                  (should (equal (kokoro-test--spoken sent) '("Header." "Body.")))
                  (kokoro-stop)
                  (kill-buffer)))
            (delete-file other)))
        (should-error (kokoro-set-pdf-margins 60 50) :type 'user-error)))))

(ert-deftest kokoro-test-pdf-sentence-carried-over ()
  (kokoro-test--with-fake-server
    (let ((pages '((1 . "First page starts. It runs on-") (2 . "to the next page. Second page.")))
          (pdf (generate-new-buffer "pdf")))
      (cl-letf (((symbol-function 'pdf-info-number-of-pages) (lambda () 2))
                ((symbol-function 'pdf-info-charlayout)
                 (lambda (page)
                   (mapcar (lambda (c) (list c '(0.1 0.5 0.2 0.52))) (alist-get page pages)))))
        (unwind-protect
            (let ((kokoro-lookahead 5))
              (kokoro--read-pdf-page pdf 1)
              (should (equal (kokoro-test--spoken sent)
                             '("First page starts." "It runs onto the next page.")))
              (should (equal (funcall (plist-get kokoro--session :progress)) "page 1/2"))
              (setq sent nil)
              ;; Finishing page 1 turns to page 2, which starts after the
              ;; part already read.
              (dolist (e kokoro--pending)
                (kokoro--handle (list :event "end" :id (car e))))
              (should (equal (kokoro-test--spoken sent) '("Second page.")))
              (should (equal (funcall (plist-get kokoro--session :progress)) "page 2/2")))
          (kill-buffer pdf))))))

;;; kokoro-test.el ends here
