"""Supertonic 3 voices, in 31 languages, e.g. st-en-F1 or st-hu-M2.

A voice named st-LANG-STYLE is spoken by Supertonic 3 instead of Kokoro:
LANG is the language of the text (en, hu, de, ...) and STYLE one of the
voices that come with the model, F1-F5 (female) and M1-M5 (male).  The
model (about 400 MB) is downloaded the first time it is used, into
SUPERTONIC_CACHE_DIR (default ~/.cache/supertonic3).
"""
import re

import numpy as np

NAME = re.compile(r"^st-([a-z]{2})-(\w+)$")


def is_supertonic(voice):
    return bool(NAME.match(voice))


def resample(audio, rate, new_rate):
    """AUDIO from RATE to NEW_RATE, leaving out what NEW_RATE cannot carry."""
    if rate == new_rate or not len(audio):
        return audio
    n = round(len(audio) * new_rate / rate)
    spectrum = np.fft.rfft(audio)[:n // 2 + 1]
    return (np.fft.irfft(spectrum, n) * (n / len(audio))).astype(np.float32)


class Voices:
    """Supertonic 3, speaking at SAMPLE_RATE like Kokoro."""

    def __init__(self, sample_rate):
        self.sample_rate = sample_rate
        self.tts = None
        self.styles = {}

    def style(self, name):
        if self.tts is None:
            from supertonic import TTS
            self.tts = TTS(model="supertonic-3", auto_download=True)
        if name not in self.styles:
            self.styles[name] = self.tts.get_voice_style(name)
        return self.styles[name]

    def speak(self, text, voice, speed=1.0):
        """Audio of TEXT as float32 at the sample rate, in one array."""
        from supertonic.config import DEFAULT_SPEED
        lang, name = NAME.match(voice).groups()
        style = self.style(name)
        # Characters the model cannot say are left out, rather than the sentence.
        _, unsupported = self.tts.model.text_processor.validate_text(text)
        for char in unsupported:
            text = text.replace(char, " ")
        if not text.strip():
            return
        # Its normal speed is DEFAULT_SPEED (1.05), so 1.0 here means that.
        wav, _ = self.tts.synthesize(text, voice_style=style, lang=lang,
                                     speed=DEFAULT_SPEED * speed)
        yield resample(wav[0].astype(np.float32), self.tts.sample_rate, self.sample_rate)
