"""Speech server for kokoro.el: keeps Kokoro-82M loaded and plays sentences.

Reads one JSON command per line on stdin:
  {"cmd": "speak", "id": 3, "text": "...", "voice": "af_heart", "speed": 1.0}
  {"cmd": "stop"}      drop everything queued or playing
  {"cmd": "pause"} / {"cmd": "resume"}
  {"cmd": "quit"}

Writes one JSON event per line on stdout:
  {"event": "ready"}, {"event": "start", "id": 3}, {"event": "end", "id": 3},
  {"event": "error", "id": 3, "msg": "..."}

Sentences are synthesized one or two ahead of playback, so there is no gap
between them.
"""
import json
import queue
import sys
import threading

import numpy as np

SAMPLE_RATE = 24000
BLOCK = SAMPLE_RATE // 20  # 50 ms: how quickly stop and pause take effect

sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8")
out_lock = threading.Lock()


def emit(**event):
    with out_lock:
        sys.stdout.write(json.dumps(event) + "\n")
        sys.stdout.flush()


class Server:
    def __init__(self):
        from kokoro import KModel, KPipeline
        self.KPipeline = KPipeline
        self.model = KModel(repo_id="hexgrad/Kokoro-82M").eval()
        self.pipelines = {}
        self.epoch = 0           # bumped by "stop"; older work is discarded
        self.paused = threading.Event()
        self.todo = queue.Queue()
        self.ready = queue.Queue(maxsize=2)

    def pipeline(self, voice):
        lang = voice[0]
        if lang not in self.pipelines:
            self.pipelines[lang] = self.KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M",
                                                  model=self.model)
        return self.pipelines[lang]

    def synthesize_loop(self):
        while True:
            epoch, item = self.todo.get()
            if epoch != self.epoch:
                continue
            try:
                voice = item.get("voice", "af_heart")
                parts = [audio.numpy() if hasattr(audio, "numpy") else audio
                         for _, _, audio in self.pipeline(voice)(
                             item["text"], voice=voice, speed=float(item.get("speed", 1.0)))
                         if audio is not None]
                audio = np.concatenate(parts) if parts else np.zeros(0, np.float32)
            except Exception as err:  # keep serving after a bad sentence
                emit(event="error", id=item.get("id"), msg=str(err))
                audio = np.zeros(0, np.float32)
            while epoch == self.epoch:
                try:
                    self.ready.put((epoch, item["id"], audio.astype(np.float32)), timeout=0.1)
                    break
                except queue.Full:
                    pass

    def play_loop(self):
        import sounddevice as sd
        with sd.OutputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32") as stream:
            while True:
                epoch, ident, audio = self.ready.get()
                if epoch != self.epoch:
                    continue
                emit(event="start", id=ident)
                pos = 0
                while pos < len(audio) and epoch == self.epoch:
                    if self.paused.is_set():
                        stream.write(np.zeros(BLOCK, np.float32))
                        continue
                    stream.write(audio[pos:pos + BLOCK])
                    pos += BLOCK
                if epoch == self.epoch:
                    emit(event="end", id=ident)

    def clear(self):
        self.epoch += 1
        self.paused.clear()
        for q in (self.todo, self.ready):
            while True:
                try:
                    q.get_nowait()
                except queue.Empty:
                    break

    def run(self):
        threading.Thread(target=self.synthesize_loop, daemon=True).start()
        threading.Thread(target=self.play_loop, daemon=True).start()
        emit(event="ready")
        for line in sys.stdin:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            cmd = msg.get("cmd")
            if cmd == "speak":
                self.todo.put((self.epoch, msg))
            elif cmd == "stop":
                self.clear()
            elif cmd == "pause":
                self.paused.set()
            elif cmd == "resume":
                self.paused.clear()
            elif cmd == "quit":
                break


if __name__ == "__main__":
    Server().run()
