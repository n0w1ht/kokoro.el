"""Narrate a document (or text) with Kokoro-82M.

Usage:
  narrate.py <file.txt|.md|.pdf|.docx> [-o out.wav] [-v af_heart] [-s 1.0]
  narrate.py --text "Hello there" [-o out.wav]

Voices (American): af_heart, af_bella, af_nicole, am_michael, am_fenrir ...
Voices (British):  bf_emma, bf_isabella, bm_george, bm_fable ...
The first letter of the voice picks the language: a=US English, b=UK English.
"""
import argparse
import re
from pathlib import Path

import numpy as np
import soundfile as sf

SAMPLE_RATE = 24000


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
    text = re.sub(r"-\n(\w)", r"\1", text)       # re-join hyphenated line breaks
    text = re.sub(r"(?<!\n)\n(?!\n)", " ", text)  # single newlines -> spaces
    text = re.sub(r"[ \t]+", " ", text)
    return text.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", nargs="?", type=Path)
    ap.add_argument("--text")
    ap.add_argument("-o", "--output", type=Path)
    ap.add_argument("-v", "--voice", default="af_heart")
    ap.add_argument("-s", "--speed", type=float, default=1.0)
    args = ap.parse_args()

    if args.text:
        text = args.text
    elif args.file:
        text = read_document(args.file)
    else:
        ap.error("give a file or --text")
    text = clean(text)
    out = args.output or (args.file.with_suffix(".wav") if args.file else Path("narration.wav"))

    from kokoro import KPipeline
    pipeline = KPipeline(lang_code=args.voice[0], repo_id="hexgrad/Kokoro-82M")

    chunks = []
    for i, (graphemes, _, audio) in enumerate(pipeline(text, voice=args.voice, speed=args.speed, split_pattern=r"\n\n+")):
        print(f"[{i + 1}] {graphemes[:70]}...")
        chunks.append(audio.numpy() if hasattr(audio, "numpy") else audio)
        chunks.append(np.zeros(int(SAMPLE_RATE * 0.3), dtype=np.float32))  # short pause between chunks

    sf.write(out, np.concatenate(chunks), SAMPLE_RATE)
    print(f"Saved {out}")


if __name__ == "__main__":
    main()
