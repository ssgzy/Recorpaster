#!/usr/bin/env python3
"""
配置读写层（UI 无关）
- 跨平台持久化到用户配置目录下的 config.json（Windows=%APPDATA%\\Recorpaster），启动时读取。
- build_config() 把这里的设置映射成 engine.Config（改配置 = 重建 engine）。

只用到一小部分（hotkey / hotkey_mode / output_mode）即可跑核心闭环，其余字段给好默认值，
设置面板直接往这上面接即可，不必再改结构。
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

APP_NAME = "Recorpaster"


def _config_dir() -> Path:
    """跨平台用户配置目录。Windows=%APPDATA%\\App；macOS/Linux 用各自约定。"""
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or str(Path.home())
        return Path(base) / APP_NAME
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_NAME
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / APP_NAME


CONFIG_DIR = _config_dir()
CONFIG_PATH = CONFIG_DIR / "config.json"

# —— 模型下拉项 → 两个引擎各自的真实标识 ——
# faster-whisper 用 model 名；mlx 用 HuggingFace 仓库名（命名不统一，逐个核对，别瞎拼）。
# mlx 仓库名已逐个核对存在且含 mlx 权重（2026-06，HF API + siblings 校验）：
#   whisper-tiny-mlx / whisper-base-mlx / whisper-small-mlx 均含 weights.npz；
#   whisper-large-v3-turbo 含 weights.safetensors（mlx_whisper 同样支持）。
#   注意：whisper-base / whisper-small（无 -mlx 后缀）不存在（404/401），别用。
MODEL_MAP = {
    # 下拉值          (faster-whisper model,   mlx_repo)
    "tiny":           ("tiny",                 "mlx-community/whisper-tiny-mlx"),
    "base":           ("base",                 "mlx-community/whisper-base-mlx"),
    "small":          ("small",                "mlx-community/whisper-small-mlx"),
    "large-v3-turbo": ("large-v3-turbo",       "mlx-community/whisper-large-v3-turbo"),
}

DEFAULTS = {
    # —— 核心闭环实际使用 ——
    # 默认热键按平台选：Windows 用 F8（布局中立——右 Alt 在欧洲键盘=AltGr，长按会污染输入/上屏）；
    # macOS 仍用右 Alt。可在设置面板里改。
    "hotkey": "f8" if sys.platform == "win32" else "alt_r",
    "hotkey_mode": "hold",      # "hold"(长按推杆) | "toggle"(按一下开/再按关)
    "output_mode": "paste",     # "paste"(剪贴板+Ctrl+V 上屏) | "copy"(仅复制到剪贴板)

    # —— 引擎相关（映射到 engine.Config；Phase 2 设置面板用）——
    "engine": "auto",           # "auto"(default_engine()) | "mlx" | "faster-whisper"
    "model": "large-v3-turbo",  # 见 MODEL_MAP
    "language": "zh",           # None/"" = 自动检测
    "min_silence_ms": 300,      # 断句灵敏度：大=更完整，小=更快出字
    "vad_threshold": 0.5,       # 环境灵敏度：嘈杂调高
    "quality_mode": False,      # False=速度优先 / True=质量优先（藏在“质量模式”后，不暴露 beam）
    # 标点风格引导（本身带标点的中文；Whisper 跟随其标点风格，非指令）。置空可关闭。
    "initial_prompt": "以下是普通话的句子，请加上标点。",
    # VAD 后端：app 默认 'onnx'（纯 onnxruntime，不依赖 torch，打包轻量）。'torch' 为 silero 官方包。
    "vad_backend": "onnx",

    # —— Phase 3 AI 润色（默认关闭，缺 key 优雅降级）——
    "polish_enabled": False,
    "polish_endpoint": "",
    "polish_key": "",
    "polish_model": "",
    "polish_prompt": "你是中文听写润色助手：把口语转成通顺书面语，纠正同音/术语错误，不要增删信息，只输出结果。",
}


def load() -> dict:
    """读配置；缺文件 / 缺字段都用默认值补齐（向前兼容新增字段）。"""
    data = dict(DEFAULTS)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data.update(json.load(f))
    except FileNotFoundError:
        pass
    except Exception as e:  # 配置损坏不致命：退回默认
        print(f"[settings] 读取失败，使用默认配置：{e}")
    # 补齐 DEFAULTS 里有、文件里没有的字段
    for k, v in DEFAULTS.items():
        data.setdefault(k, v)
    return data


def save(data: dict) -> None:
    """原子写入，避免写一半损坏。"""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_PATH.with_suffix(".json.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG_PATH)


def build_config(s: dict):
    """把设置 dict 映射成 engine.Config（改配置 = 重建 engine 时调用）。"""
    from engine import Config, default_engine

    eng = s.get("engine", "auto")
    if eng == "auto":
        eng = default_engine()
    # 安全网：非 Apple Silicon 上 mlx 不可用，回退到 faster-whisper（即便配置里残留 mlx）
    if eng == "mlx" and default_engine() != "mlx":
        eng = "faster-whisper"

    model_key = s.get("model", "large-v3-turbo")
    fw_model, mlx_repo = MODEL_MAP.get(model_key, MODEL_MAP["large-v3-turbo"])

    lang = s.get("language") or None  # "" -> None(自动检测)

    return Config(
        engine=eng,
        model=fw_model,
        mlx_repo=mlx_repo,
        language=lang,
        min_silence_ms=int(s.get("min_silence_ms", 300)),
        vad_threshold=float(s.get("vad_threshold", 0.5)),
        quality_mode=bool(s.get("quality_mode", False)),
        initial_prompt=s.get("initial_prompt", DEFAULTS["initial_prompt"]),
        vad_backend=s.get("vad_backend", DEFAULTS["vad_backend"]),
    )


if __name__ == "__main__":
    s = load()
    print(f"配置文件：{CONFIG_PATH}")
    print(json.dumps(s, ensure_ascii=False, indent=2))
    print("→ engine.Config:", build_config(s))
