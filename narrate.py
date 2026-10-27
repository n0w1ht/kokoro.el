"""Narrate a document (or text) with Kokoro-82M.

Usage:
  narrate.py <file.txt|.md|.pdf|.docx> [-o out.wav] [-v af_heart] [-s 1.0]
  narrate.py --text "Hello there" [-o out.wav]
  narrate.py --lines prepared.txt [-o out.mp3]

With --lines, each line of the file is spoken as one piece and an empty
line is a paragraph break; kokoro.el prepares such files, already cleaned
the way it reads aloud.

The output can be .wav, or .mp3, .opus, .ogg, .m4a or .flac when ffmpeg
is on PATH.

Voices (American): af_heart, af_bella, af_nicole, am_michael, am_fenrir ...
Voices (British):  bf_emma, bf_isabella, bm_george, bm_fable ...
The first letter of the voice picks the language: a=US English, b=UK English.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

SAMPLE_RATE = 24000
SENTENCE_PAUSE = 0.12   # seconds of silence after a sentence
PARAGRAPH_PAUSE = 0.6   # ... and after a paragraph

ENCODERS = {
    ".mp3": ["-c:a", "libmp3lame", "-b:a", "64k"],
    ".opus": ["-c:a", "libopus", "-b:a", "32k"],
    ".ogg": ["-c:a", "libopus", "-b:a", "32k"],
    ".m4a": ["-c:a", "aac", "-b:a", "64k"],
    ".flac": ["-c:a", "flac"],
}


def read_document(path: Path) -> str:
    ext = path.suffix.lower()
    if ext == ".pdf":
        from pypdf import PdfReader
        return "\n\n".join(page.extract_text() or "" for page in PdfReader(path).pages)
    if ext == ".docx":
        import docx
        return "\n\n".join(p.text for p in docx.Document(path).paragraphs)
    text = path.read_text(encoding="utf-8", errors="ignore")
    if ext == ".md":
        text = re.sub(r"```.*?```", "", text, flags=re.S)  # drop code blocks
        text = re.sub(r"[#*_`>|]", "", text)
        text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)  # keep link text
    return text


def clean(text: str) -> str:
    # re-join words hyphenated over lines ("liber-" / "ation"), also with
    # soft or Unicode hyphens and spaces around the line break
    text = re.sub(r"([^\W\d_])[-\u00ad\u2010\u2011\u00ac][ \t\r]*\n[ \t]*([^\W\d_])", r"\1\2", text)
    text = text.replace("\u00ad", "")
    text = re.sub(r"(?<!\n)\n(?!\n)", " ", text)  # single newlines -> spaces
    text = re.sub(r"[ \t]+", " ", text)
    return text.strip()


def pieces_of_lines(path: Path):
    """(text, pause) for each line of a prepared file."""
    lines = path.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        if line.strip():
            last = i + 1 >= len(lines) or not lines[i + 1].strip()
            yield line.strip(), PARAGRAPH_PAUSE if last else SENTENCE_PAUSE


def pieces_of_text(text: str):
    for paragraph in re.split(r"\n\n+", text):
        if paragraph.strip():
            yield paragraph.strip(), PARAGRAPH_PAUSE


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", type=Path)
    ap.add_argument("--text")
    ap.add_argument("--lines", type=Path, help="prepared file: one sentence per line")
    ap.add_argument("-o", "--output", type=Path)
    ap.add_argument("-v", "--voice", default="af_heart")
    ap.add_argument("-s", "--speed", type=float, default=1.0)
    args = ap.parse_args()

    if args.lines:
        pieces = list(pieces_of_lines(args.lines))
    elif args.text:
        pieces = list(pieces_of_text(clean(args.text)))
    elif args.file:
        pieces = list(pieces_of_text(clean(read_document(args.file))))
    else:
        ap.error("give a file, --text or --lines")
    out = args.output or (args.file.with_suffix(".wav") if args.file else Path("narration.wav"))
    ext = out.suffix.lower()
    if ext != ".wav":
        if ext not in ENCODERS:
            sys.exit(f"Cannot save {ext} files; use .wav, " + ", ".join(ENCODERS))
        if not shutil.which("ffmpeg"):
            sys.exit(f"Saving {ext} needs ffmpeg on PATH (winget install Gyan.FFmpeg), or save .wav")

    from kokoro import KPipeline
    pipeline = KPipeline(lang_code=args.voice[0], repo_id="hexgrad/Kokoro-82M")

    # Written as it goes, so a whole book never has to fit in memory.
    fd, wav = tempfile.mkstemp(suffix=".wav", dir=out.parent) if ext != ".wav" else (None, out)
    if fd is not None:
        os.close(fd)
    try:
        with sf.SoundFile(wav, "w", samplerate=SAMPLE_RATE, channels=1, subtype="PCM_16") as f:
            for i, (text, pause) in enumerate(pieces):
                print(f"[{i + 1}/{len(pieces)}] {text[:70]}", flush=True)
                for _, _, audio in pipeline(text, voice=args.voice, speed=args.speed,
                                            split_pattern=None if args.lines else r"\n+"):
                    if audio is not None:
                        f.write(audio.numpy() if hasattr(audio, "numpy") else audio)
                f.write(np.zeros(int(SAMPLE_RATE * pause), dtype=np.float32))
        if ext != ".wav":
            print(f"Encoding {out.name}...", flush=True)
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-ac", "1",
                            *ENCODERS[ext], str(out)], check=True)
    finally:
        if wav != out and os.path.exists(wav):
            os.remove(wav)
    print(f"Saved {out}", flush=True)


if __name__ == "__main__":
    main()
