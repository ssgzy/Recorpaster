from faster_whisper import WhisperModel

# Mac 上 CTranslate2 用不了 M4 的 GPU,但 CPU + int8 已经很快了
model = WhisperModel("large-v3-turbo", device="cpu", compute_type="int8")

segments, info = model.transcribe("New Recording.m4a", language="zh")
print(f"识别语言: {info.language} (置信度 {info.language_probability:.2f})")
for seg in segments:
    print(f"[{seg.start:.1f}s -> {seg.end:.1f}s] {seg.text}")