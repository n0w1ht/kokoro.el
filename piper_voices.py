"""Piper voices, for languages Kokoro does not speak, e.g. hu_HU-anna-medium.

A voice named like Piper's (language_REGION-name-quality) is spoken by
Piper instead of Kokoro.  Its files are looked for in KOKORO_PIPER_DIR
(default ~/.local/share/piper) and downloaded there when missing.
"""
import os
import re
from pathlib import Path

import numpy as np

NAME = re.compile(r"^[a-z]{2,3}_[A-Z]{2}-")


def is_piper(voice):
    return bool(NAME.match(voice))


def directory():
    return Path(os.environ.get("KOKORO_PIPER_DIR") or "~/.local/share/piper").expanduser()


class Voices:
    """Loaded Piper voices, each speaking at SAMPLE_RATE like Kokoro."""

    def __init__(self, sample_rate):
        self.sample_rate = sample_rate
        self.loaded = {}

    def voice(self, name):
        if name not in self.loaded:
            from piper import PiperVoice
            folder = directory()
            model = folder / f"{name}.onnx"
            if not model.exists() or not model.with_suffix(".onnx.json").exists():
                from piper.download_voices import download_voice
                folder.mkdir(parents=True, exist_ok=True)
                download_voice(name, folder)
            self.loaded[name] = PiperVoice.load(model)
        return self.loaded[name]

    def speak(self, text, name, speed=1.0):
        """Audio of TEXT as float32 at the sample rate, one array per sentence."""
        from piper import SynthesisConfig
        voice = self.voice(name)
        config = SynthesisConfig(length_scale=voice.config.length_scale / speed)
        for chunk in voice.synthesize(text, syn_config=config):
            audio = chunk.audio_float_array.astype(np.float32)
            if chunk.sample_rate != self.sample_rate and len(audio):
                n = round(len(audio) * self.sample_rate / chunk.sample_rate)
                audio = np.interp(np.linspace(0, len(audio) - 1, n),
                                  np.arange(len(audio)), audio).astype(np.float32)
            yield audio
