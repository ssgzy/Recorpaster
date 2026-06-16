#!/usr/bin/env python3
"""
语音听写引擎层（UI 无关）
- 统一封装 faster-whisper(CPU) / mlx-whisper(Apple Silicon GPU)
- 麦克风流 + Silero VAD 切句 + 识别，结果通过回调吐出
- 所有可调项集中在 Config，UI 层只改 Config + 接回调即可

供任意 UI（pywebview / Tauri sidecar / PySide6 / CLI）复用：
    cfg = Config()
    eng = DictationEngine(cfg, on_result=lambda r: print(r.text))
    eng.start()      # 开始听写
    ...
    eng.stop()       # 停止

依赖：
    pip install sounddevice silero-vad
    pip install faster-whisper       # 引擎之一
    pip install mlx-whisper          # 引擎之二（仅 Apple Silicon）
"""

from __future__ import annotations

import platform
import queue
import threading
import time
from dataclasses import dataclass, field
from typing import Callable, Optional

import numpy as np
import sounddevice as sd
import torch
from silero_vad import load_silero_vad, VADIterator

SAMPLE_RATE = 16000
CHUNK = 512   # Silero 在 16kHz 下每帧必须 512 样本


def default_engine() -> str:
    """Apple Silicon 默认 mlx(吃 GPU)，其它平台用 faster-whisper(CPU)。"""
    if platform.system() == "Darwin" and platform.machine() == "arm64":
        return "mlx"
    return "faster-whisper"


@dataclass
class Config:
    # —— 建议做进 UI 的旋钮 ——
    engine: str = field(default_factory=default_engine)   # "mlx" | "faster-whisper"
    model: str = "large-v3-turbo"          # faster-whisper 模型名
    mlx_repo: str = "mlx-community/whisper-large-v3-turbo"  # mlx 的 HF 仓库（命名不统一，故单列）
    language: Optional[str] = "zh"         # None = 自动检测
    min_silence_ms: int = 300              # 断句灵敏度：大=更完整，小=更快出字
    vad_threshold: float = 0.5             # 环境灵敏度：嘈杂调高
    quality_mode: bool = False             # False=速度优先(关温度回退，延迟稳定) / True=质量优先
    # 标点风格引导：一段“本身带标点”的中文，让 Whisper 跟随该风格输出标点（非指令）。
    # 向后兼容新增字段，默认非空即生效；置空字符串可关闭。
    initial_prompt: Optional[str] = "以下是普通话的句子，请加上标点。"
    # —— 一般不用动 ——
    lookback_chunks: int = 10              # 句首回看，避免吞字（约 320ms）
    min_utter_sec: float = 0.3             # 短于此时长丢弃，过滤噪声


@dataclass
class Result:
    text: str
    audio_sec: float
    cost_sec: float

    @property
    def rtf(self) -> float:
        return self.cost_sec / self.audio_sec if self.audio_sec else 0.0


class DictationEngine:
    def __init__(self, cfg: Config,
                 on_result: Callable[[Result], None],
                 on_status: Optional[Callable[[str], None]] = None):
        self.cfg = cfg
        self.on_result = on_result
        self.on_status = on_status or (lambda s: None)
        self._audio_q: queue.Queue = queue.Queue()
        self._utter_q: queue.Queue = queue.Queue()
        self._stop = threading.Event()
        self._flush_req = threading.Event()   # 松开热键收尾：强制把当前缓冲送识别
        self._asr_thread: Optional[threading.Thread] = None
        self._vad_thread: Optional[threading.Thread] = None
        self._vad = VADIterator(load_silero_vad(), threshold=cfg.vad_threshold,
                                sampling_rate=SAMPLE_RATE,
                                min_silence_duration_ms=cfg.min_silence_ms)
        self._transcribe = self._build_engine()   # -> Callable[[np.ndarray], str]

    # ---- 引擎构建：返回 transcribe(audio_np) -> str ----
    def _build_engine(self) -> Callable[[np.ndarray], str]:
        cfg = self.cfg
        if cfg.engine == "faster-whisper":
            from faster_whisper import WhisperModel
            self.on_status(f"加载 faster-whisper · CPU · {cfg.model}")
            model = WhisperModel(cfg.model, device="cpu", compute_type="int8")
            beam = 5 if cfg.quality_mode else 1
            temp = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] if cfg.quality_mode else 0.0
            prompt = cfg.initial_prompt or None

            def run(audio):
                segs, _ = model.transcribe(audio, language=cfg.language,
                                           beam_size=beam, temperature=temp,
                                           initial_prompt=prompt)
                return "".join(s.text for s in segs).strip()
            return run

        if cfg.engine == "mlx":
            import mlx_whisper
            self.on_status(f"加载 mlx-whisper · GPU · {cfg.mlx_repo}（首次会下载模型）")
            temp = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0) if cfg.quality_mode else 0.0
            prompt = cfg.initial_prompt or None
            mlx_whisper.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32),
                                   path_or_hf_repo=cfg.mlx_repo, language=cfg.language)  # 预热

            def run(audio):
                r = mlx_whisper.transcribe(audio, path_or_hf_repo=cfg.mlx_repo,
                                           language=cfg.language, temperature=temp,
                                           initial_prompt=prompt)
                return r["text"].strip()
            return run

        raise ValueError(f"未知 engine: {cfg.engine!r}")

    # ---- 音频回调（独立音频线程，只做最轻的事）----
    def _on_audio(self, indata, frames, time_info, status):
        self._audio_q.put(indata[:, 0].copy())

    # ---- 单句识别（识别线程与收尾排空共用）----
    def _process(self, audio):
        dur = len(audio) / SAMPLE_RATE
        if dur < self.cfg.min_utter_sec:
            return
        t0 = time.perf_counter()
        text = self._transcribe(audio)
        cost = time.perf_counter() - t0
        if text:
            self.on_result(Result(text=text, audio_sec=dur, cost_sec=cost))

    # ---- 识别线程 ----
    def _asr_loop(self):
        while not self._stop.is_set():
            try:
                audio = self._utter_q.get(timeout=0.2)
            except queue.Empty:
                continue
            self._process(audio)
        # stop() 之后排空：处理松开 flush / VAD 收尾时入队但尚未识别的尾句，
        # 避免丢掉最后半句。只要还有整句陆续到达就把空闲窗口顺延，空闲一小段才收工。
        idle_deadline = time.perf_counter() + 0.5
        while time.perf_counter() < idle_deadline:
            try:
                audio = self._utter_q.get(timeout=0.1)
            except queue.Empty:
                continue
            self._process(audio)
            idle_deadline = time.perf_counter() + 0.5

    # ---- VAD 主循环 ----
    def _vad_loop(self):
        speech, lookback, collecting = [], [], False
        with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                            blocksize=CHUNK, callback=self._on_audio):
            self.on_status("listening")
            while not self._stop.is_set():
                # flush：把当前正在收集的语音立即送识别（热键松开收尾用）
                if self._flush_req.is_set():
                    self._flush_req.clear()
                    if speech:
                        self._utter_q.put(np.concatenate(speech))
                    speech, collecting = [], False
                    self._vad.reset_states()
                try:
                    chunk = self._audio_q.get(timeout=0.2)
                except queue.Empty:
                    continue
                lookback.append(chunk)
                if len(lookback) > self.cfg.lookback_chunks:
                    lookback.pop(0)
                event = self._vad(torch.from_numpy(chunk), return_seconds=False)
                if event and "start" in event:
                    collecting = True
                    speech = list(lookback)
                elif collecting:
                    speech.append(chunk)
                if event and "end" in event and collecting:
                    collecting = False
                    self._utter_q.put(np.concatenate(speech))
                    speech = []
            # 退出兜底：stop() 时若还在收集，把尾句送出（即便 app 未显式 flush）
            if speech:
                self._utter_q.put(np.concatenate(speech))

    # ---- 内部：清空残留队列 ----
    @staticmethod
    def _drain(q: queue.Queue):
        try:
            while True:
                q.get_nowait()
        except queue.Empty:
            pass

    # ---- 对外接口 ----
    def start(self):
        # 重启健壮性（首次启动时下面几步都是空操作，与原行为一致）：
        # 1) 先确保上一轮的 vad/asr 线程都退干净，避免双 InputStream / 共享 _vad、
        #    并发推理（hold-to-talk 快速松开又按下时会发生）。
        self._stop.set()
        for t in (self._vad_thread, self._asr_thread):
            if t is not None and t.is_alive() and t is not threading.current_thread():
                t.join(timeout=2.0)
        # 2) 丢掉上一段残留在队列里的音频/整句，别带进新会话。
        self._drain(self._audio_q)
        self._drain(self._utter_q)
        # 3) 复位状态并起新线程。
        self._stop.clear()
        self._flush_req.clear()
        self._vad.reset_states()
        self._asr_thread = threading.Thread(target=self._asr_loop, daemon=True)
        self._vad_thread = threading.Thread(target=self._vad_loop, daemon=True)
        self._asr_thread.start()
        self._vad_thread.start()

    def stop(self):
        self._stop.set()

    def flush(self):
        """立即把当前正在收集的语音送去识别（向后兼容新增方法）。

        用于热键松开收尾：松开瞬间最后半句可能还没被 VAD 判定结束，
        调用本方法可强制断句送识别，避免丢字。可在 stop() 前调用。
        """
        self._flush_req.set()


# 直接跑这个文件 = CLI 自测
if __name__ == "__main__":
    cfg = Config()

    def show(r: Result):
        print(f"📝 {r.text}")
        print(f"   ⏱  音频 {r.audio_sec:.1f}s | 识别 {r.cost_sec:.2f}s | RTF {r.rtf:.2f} "
              f"| 说完到出字≈{r.cost_sec + cfg.min_silence_ms / 1000:.2f}s")

    print(f"引擎={cfg.engine} | 模型={cfg.model if cfg.engine == 'faster-whisper' else cfg.mlx_repo} "
          f"| 质量模式={cfg.quality_mode}")
    eng = DictationEngine(cfg, on_result=show, on_status=lambda s: print(f"[{s}]"))
    eng.start()
    print("\n🎤 开始说话（Ctrl+C 退出）...\n")
    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        eng.stop()
        print("\n已退出。")
