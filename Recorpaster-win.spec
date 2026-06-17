# -*- mode: python ; coding: utf-8 -*-
# PyInstaller 打包规格：Windows x64 系统托盘听写 app（faster-whisper · CPU · 无 torch/mlx）。
# 产物为 onedir（dist/Recorpaster/，含 Recorpaster.exe + _internal）。模型首次运行下载，不打进包。
import os
from PyInstaller.utils.hooks import collect_all

ROOT = os.path.abspath(os.getcwd())

datas, binaries, hiddenimports = [], [], []

# —— 整包收集这些库（含其数据/原生 DLL/子模块）——
# faster_whisper→ctranslate2/tokenizers/av(ffmpeg)；onnxruntime(silero VAD)；
# webview(WebView2Loader.dll + 后端)；pystray/PIL(托盘)；pynput(全局热键)；sounddevice(PortAudio)。
for pkg in (
    "faster_whisper", "ctranslate2", "tokenizers", "av",
    "onnxruntime", "huggingface_hub",
    "sounddevice", "pynput", "pyperclip",
    "webview", "pystray", "PIL",
    "pythonnet", "clr_loader",   # pywebview EdgeChromium 后端需要 pythonnet(clr)
):
    try:
        d, b, h = collect_all(pkg)
        datas += d
        binaries += b
        hiddenimports += h
    except Exception as e:
        print(f"[spec] collect_all({pkg}) 跳过: {e}")

# —— 自带资源：前端 + silero onnx ——
datas += [("web", "web"), ("assets", "assets")]

# —— 显式补齐易漏的 Windows 后端子模块 ——
hiddenimports += [
    "clr",
    "webview.platforms.winforms",
    "webview.platforms.edgechromium",
    "pynput.keyboard._win32",
    "pynput.mouse._win32",
    "pystray._win32",
    "numpy",
]

# —— 排除：mac 专属 + 体积/无关大件（轻量化）——
excludes = [
    # macOS 原生（本仓已不含，双保险）
    "AppKit", "Foundation", "objc", "PyObjCTools", "WebKit", "Quartz",
    "mlx", "mlx_whisper",
    # 不用 torch 路径（VAD 走 onnx）
    "torch", "torchaudio", "torchvision", "silero_vad",
    # 体积大且无关（mac 构建时被误拉进来过，这里显式排除）
    "pyarrow", "datasets", "pygame", "scipy", "numba", "llvmlite",
    "matplotlib", "pandas", "IPython", "jupyter", "notebook",
    "tensorflow", "transformers", "sympy", "tkinter",
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
    console=False,            # 托盘 app，无终端窗口（日志写入 %APPDATA%\Recorpaster\Recorpaster.log）
    icon=None,
)
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="Recorpaster")
