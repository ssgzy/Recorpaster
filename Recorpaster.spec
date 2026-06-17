# -*- mode: python ; coding: utf-8 -*-
# PyInstaller 打包规格：macOS arm64 菜单栏听写 app（无 torch，mlx + onnxruntime）。
import os
from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs, collect_submodules

ROOT = os.path.abspath(os.getcwd())

# —— 数据文件 ——
datas = []
datas += collect_data_files("mlx")           # 含 mlx.metallib(120M·GPU 必需) + 头文件
datas += collect_data_files("mlx_whisper")   # tokenizer(.tiktoken) + mel_filters.npz
datas += collect_data_files("onnxruntime")
datas += [("web", "web"), ("assets", "assets")]  # 悬浮窗/设置前端 + silero onnx

# —— 动态库 ——
binaries = []
binaries += collect_dynamic_libs("mlx")          # libmlx / libjaccl
binaries += collect_dynamic_libs("onnxruntime")  # libonnxruntime

# —— 隐藏依赖 ——
hiddenimports = []
hiddenimports += collect_submodules("mlx")
hiddenimports += collect_submodules("mlx_whisper")
hiddenimports += collect_submodules("webview")        # pywebview cocoa 后端
hiddenimports += [
    # pyobjc 框架（菜单栏托盘 / WKWebView / 权限 / 主线程调度）
    "objc", "Foundation", "AppKit", "WebKit", "Quartz", "CoreText",
    "ApplicationServices", "PyObjCTools", "PyObjCTools.AppHelper",
    # 输入/输出/音频
    "sounddevice", "pyperclip", "pynput", "pynput.keyboard", "pynput.mouse",
    # ASR / 下载 / 分词
    "numpy", "onnxruntime", "tiktoken", "tiktoken_ext", "huggingface_hub",
    "tqdm", "regex", "requests", "certifi",
    # mlx_whisper/timing.py 顶层 import（即便不取词级时间戳，import 也会触发）
    "scipy", "scipy.signal", "scipy.special", "numba", "llvmlite",
]

# —— 排除（轻量化关键：torch 系全部不打包）——
# 注意：不要排 scipy/numba/llvmlite —— mlx_whisper.timing 顶层依赖它们。
excludes = [
    "torch", "torchaudio", "torchvision", "silero_vad",
    "ctranslate2", "faster_whisper",
    "tkinter", "matplotlib", "pandas", "IPython", "jupyter",
    "notebook", "tensorflow", "transformers", "sympy",
]

a = Analysis(
    ["app.py"],
    pathex=[ROOT],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=excludes,
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="Recorpaster",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,            # 菜单栏 app，无终端窗口
    target_arch="arm64",
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="Recorpaster")

app = BUNDLE(
    coll,
    name="Recorpaster.app",
    icon=None,
    bundle_identifier="com.ssgzy.recorpaster",
    info_plist={
        "CFBundleName": "Recorpaster",
        "CFBundleDisplayName": "Recorpaster 听写",
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1.0.0",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
        # 菜单栏常驻工具：不占 Dock（与 Accessory 激活策略一致）
        "LSUIElement": True,
        # 缺这条麦克风授权会直接崩；弹窗会显示这段说明 + app 名
        "NSMicrophoneUsageDescription": "Recorpaster 需要使用麦克风进行本地语音听写；音频仅在内存转写，绝不上传或写盘。",
    },
)
