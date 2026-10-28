# kokoro.el

Read buffers, EPUB books (nov.el) and PDFs (pdf-tools) aloud in Emacs with the
[Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) text-to-speech model.

- The sentence being spoken is highlighted, on the PDF page too.
- While reading, the header line has Prev / Pause / Next / Stop buttons, the
  voice and speed, and how far along you are ("page 3/12", "chapter 2/9, 41%").
- At the end of a PDF page or EPUB chapter, reading goes on to the next one. A
  sentence running over a page break is read in one piece before the page turns.
- PDF headers, footers and page numbers are left out (`kokoro-pdf-margins`).
- Org and Markdown code blocks and tables are passed over, saying "Code block."
  or "Table." instead; drawers, keywords and comments are passed over silently
  (`kokoro-skip-rules`).
- Abbreviations such as "Dr.", "e.g.", "Fig." and "et al." do not end a
  sentence (`kokoro-abbreviations`).
- Symbols and numbers in medical and science text are said in words: "×10⁹/L"
  as "times 10 to the 9 per liter", "150–400" as "150 to 400", "≥", "±", "→",
  "°C", Greek letters and subscripts; superscript reference numbers are left
  out (`kokoro-symbols`, `kokoro-text-symbols`).
- A word hyphenated over two lines ("Liber-" / "ation") is read as one word,
  also with the soft and Unicode hyphens PDFs often have.
- Words the voice gets wrong can be given a pronunciation
  (`kokoro-pronunciations`, which comes with common medical units and dosing
  abbreviations), and any function can be added to `kokoro-text-functions`.
- The voice and speed can be set for one buffer only, with `C-u`.
- Each file remembers where you stopped, and `C-c t c` reads on from there.

## How it works

`kokoro_server.py` runs once in the background and keeps the model loaded.
Emacs sends it one sentence at a time, a few ahead of playback, so speech is
continuous and stop, pause and skip respond within a fraction of a second.
The first reading after starting Emacs waits a few seconds for the model to load.

## Requirements

- Emacs 29.1 or later
- Python 3.10 to 3.12, with the packages in `requirements.txt`
- Optional: pdf-tools for PDFs, nov.el for EPUBs

Kokoro runs on the CPU; a GPU is not needed. The model (about 330 MB) is
downloaded from Hugging Face the first time it is used.

## Install

Clone the repository, and make a Python environment for it, e.g. in
`~/kokoro-tts` (the default place `kokoro-python` looks):

```sh
git clone https://github.com/n0w1ht/kokoro.el ~/.emacs.d/plugins/kokoro
python3 -m venv ~/kokoro-tts/.venv
# Windows: ~/kokoro-tts/.venv/Scripts/python.exe; elsewhere: ~/kokoro-tts/.venv/bin/python
~/kokoro-tts/.venv/bin/python -m pip install -r ~/.emacs.d/plugins/kokoro/requirements.txt
```

Without an NVIDIA GPU, installing the CPU build of PyTorch first saves a large
download: `pip install torch --index-url https://download.pytorch.org/whl/cpu`.

Then in your init file:

```elisp
(use-package kokoro
  :load-path "~/.emacs.d/plugins/kokoro"
  :bind-keymap ("C-c t" . kokoro-command-map)
  :custom
  (kokoro-python "~/kokoro-tts/.venv/Scripts/python.exe") ; if not the default
  (kokoro-voice "af_heart"))
```

## Keys

| Key         | Command                     | What it does                                              |
|-------------|-----------------------------|-----------------------------------------------------------|
| `C-c t t`   | `kokoro-read-dwim`          | Region; else from point on; in a PDF, selection or pages  |
| `C-c t r`   | `kokoro-read-region`        | Read the region                                           |
| `C-c t a`   | `kokoro-read-buffer`        | Read the whole buffer                                     |
| `C-c t .`   | `kokoro-read-paragraph`     | Read the paragraph at point                               |
| `C-c t c`   | `kokoro-resume`             | Read on from where you stopped in this file; `C-u`: pick a file |
| `C-c t SPC` | `kokoro-pause`              | Pause or resume                                           |
| `C-c t s`   | `kokoro-stop`               | Stop                                                      |
| `C-c t n/p` | `kokoro-next/previous`      | Skip to the next or previous sentence, also across pages and chapters |
| `C-c t ]/[` | `kokoro-next/previous-paragraph` | Skip to the next or previous paragraph; in a PDF, page |
| `C-c t ,`   | `kokoro-repeat`             | Read the sentence again                                   |
| `C-c t v`   | `kokoro-select-voice`       | Choose a voice (applies from the current sentence)        |
| `C-c t S`   | `kokoro-set-speed`          | Set the speed, 0.5 to 2.0                                 |
| `C-c t +/-` | `kokoro-faster/slower`      | Change speed by 0.1                                       |
| `C-c t w`   | `kokoro-save-audio`         | Save a file (text, Org, Markdown, EPUB, PDF, Word) as MP3/Opus/WAV, in the background |
| `C-c t W`   | `kokoro-save-region-audio`  | Save the region (in a PDF, the selection) as audio        |
| `C-c t m`   | `kokoro-set-pdf-margins`    | Set how much of the top and bottom of this PDF is left out |
| `C-c t x`   | `kokoro-skip-text`          | Leave out text matching a regexp, in this file            |
| `C-c t X`   | `kokoro-unskip-text`        | Read text matching one of this file's regexps again       |
| `C-c t f`   | `kokoro-forget-source`      | Forget the voice, speed and left-out text for this file   |
| `C-c t h`   | `kokoro-mode`               | Show or hide the controls in the header line              |
| `C-c t q`   | `kokoro-quit`               | Shut the server down and free its memory                  |

With `C-u`, `C-c t v` and `C-c t S` change only the file being read, e.g. a
British voice for one book. This is remembered in `~/.emacs.d/kokoro-sources.eld`
(see `kokoro-sources-file`), so the book is read that way next time too, after
restarting Emacs, and by `C-c t w`. Once a file has its own speed, `C-c t +/-`
change it for that file. `C-c t f` (`kokoro-forget-source`) forgets the file's
voice and speed. Buffers without a file only keep them until they are closed.

## Reading on where you stopped

Each file remembers the sentence you were on: the page in a PDF, the chapter
in an EPUB. `C-c t c` (`kokoro-resume`) reads on from there, also after
restarting Emacs. Pressed in a buffer that has no place, or with `C-u`, it
lists the files you have read, the last one first, and opens the one you pick
where you stopped. Places are kept in `kokoro-sources-file`; set
`kokoro-remember-place` to nil to keep none.

## Saving audio

`C-c t w` saves a whole file as audio to listen to elsewhere, e.g. on your
phone; `C-c t W` saves the region. The text is cleaned exactly as when it is
read aloud (pronunciations, symbols, left-out text, PDF margins, skipped code
blocks), with the file's own voice and speed. EPUBs need nov.el, and PDFs are
read through pdf-tools when it is installed (otherwise by `pypdf`); Word files
are read by the script.

It saves MP3 when ffmpeg is on PATH (`winget install Gyan.FFmpeg`), otherwise
WAV; set `kokoro-audio-format` to `"opus"` for the smallest files. It runs in
the background with its progress in the mode line ("Narrating book.mp3 41%"),
and the details go to the `*kokoro-narrate*` buffer. A whole book takes a while
on the CPU, so it is best started before a break.

## PDF margins

Running headers, footers and page numbers are left out by skipping the top and
bottom 6% of each page. When a PDF needs more or less, open it and press
`C-c t m`: it asks for the top and bottom, in percent of the page height,
shades the part that will be read, and remembers them for that PDF in
`kokoro-sources.eld`. If you are reading it, the page is read again with them.
`C-c t f` forgets them along with the PDF's voice and speed.

## Leaving out text

`C-c t x` asks for a regexp and leaves out matching text in this file from then
on, also remembered in `kokoro-sources.eld`. It tells you how many matches the
buffer has, so you can check the regexp. For example:

| To leave out              | Regexp                     |
|---------------------------|----------------------------|
| `{1.42}`, `{12}`          | `{[0-9.]+}`                |
| `[3]`, `[3,4]`, `[3-5]`   | `\[[0-9,–-]+\]`            |
| `(Smith 2020)`            | `([A-Z][a-z]+,? [0-9]\{4\})` |
| anything in braces        | `{[^}]*}`                  |

(Typed at the prompt, as above; in Lisp strings each `\` is doubled.)

For every file, set `kokoro-remove-regexps`; a file's own regexps are used as
well:

```elisp
(setq kokoro-remove-regexps '("{[0-9.]+}"))
```

The text stays in the buffer and in the highlight; it is only not spoken.
Saved audio (`C-c t w`) leaves it out too. Voices starting with `a` are American English and
with `b` British English; the voice list shows which are female and male.

## Options

| Option                  | What it does                                               |
|-------------------------|------------------------------------------------------------|
| `kokoro-voice`, `kokoro-speed` | Voice and speed (can be set per file)              |
| `kokoro-sources-file`   | Where per-file voice and speed are kept (nil: nowhere)     |
| `kokoro-remember-place` | Remember where reading got to in each file (`C-c t c`)     |
| `kokoro-remove-regexps` | Regexps of text left out in every file                     |
| `kokoro-pronunciations` | `("mg" . "milligrams")` pairs, matched as whole words      |
| `kokoro-symbols`        | `("≥" . "greater than or equal to")` pairs, matched anywhere |
| `kokoro-text-functions` | Functions a sentence passes through before it is spoken    |
| `kokoro-abbreviations`  | Words ending in "." that do not end a sentence             |
| `kokoro-skip-rules`     | Parts not read, per major mode                             |
| `kokoro-pdf-margins`    | Top and bottom of a PDF page left out, `(0.06 . 0.06)`; each PDF can have its own (`C-c t m`) |
| `kokoro-pdf-highlight`  | Highlight the sentence on the PDF page                     |
| `kokoro-pdf-highlight-style` | `marker` (pale color behind the words, the default) or `underline` |
| `kokoro-pdf-highlight-color`, `kokoro-pdf-highlight-opacity` | Its color, and how deep it is (0.3; lower is paler) |
| `kokoro-header-line`    | Show the controls in the header line while reading         |
| `kokoro-follow`         | Keep the sentence in view                                  |
| `kokoro-continue`       | Go on to the next page or chapter                          |
| `kokoro-audio-format`   | Kind of file `C-c t w` saves: "mp3", "opus", "m4a", "flac", "wav" |
| `kokoro-lookahead`, `kokoro-max-chars` | How far ahead to synthesize; longest piece  |

The face `kokoro-sentence` is used for the highlight in text buffers.

Example: add your own words.

```elisp
(with-eval-after-load 'kokoro
  (add-to-list 'kokoro-pronunciations '("PSA" . "P S A"))
  (add-to-list 'kokoro-pronunciations '("Gleason" . "Glee-son")))
```

## Files

- `kokoro.el`: the package
- `kokoro_server.py`: the speech server Emacs starts
- `narrate.py`: turns text into an audio file (`C-c t w`); it also works on its
  own: `python narrate.py book.pdf -v bm_george -o book.mp3`

## License

GPL-3.0 or later; see `LICENSE`.

## Tests

```
cd test
emacs -Q --batch -L .. -l kokoro-test.el -f ert-run-tests-batch-and-exit
emacs -Q --batch -L .. -l kokoro-live-check.el    # speaks two sentences
```
