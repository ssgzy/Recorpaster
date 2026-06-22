#!/usr/bin/env python3
"""
轻量化本地语音听写工具（Windows 版）

长按热键（默认右 Alt）→ 唤出悬浮条 + 开始听写 → 实时把语音转文字
→ 剪贴板 + Ctrl+V 上屏（或仅复制）→ 松开停止、淡出。常驻系统托盘。

说明：macOS 原生版已改用 Swift 重做；本 Python 代码库从此只服务 Windows。
全部用跨平台库实现（pywebview / pystray / pynput / faster-whisper），不再含任何
macOS 原生（pyobjc/AppKit）或 TCC 权限代码——因此在 macOS/Linux 上也能跑起来便于
开发自测，但目标平台是 Windows。Windows 上热键/粘贴一般无需特殊授权。

架构要点：
  · pywebview 占主线程跑 GUI 事件循环（webview.start 阻塞主线程）。
  · 系统托盘用 pystray，跑在自己的线程；菜单回调里再甩到后台线程执行。
  · 全局热键用 pynput，监听器跑在自己的线程，创建一次并常驻（改键只换字段，不重建）。
  · 悬浮条用 focus=False 创建，不抢目标输入框焦点，Ctrl+V 才能落到正确的 App。

隐私：音频只在内存里转，转完即弃，绝不写盘。
"""

from __future__ import annotations

import json
import os
import platform
import queue
import re
import sys
import threading
import time

import webview

import settings
from engine import DictationEngine, Result, default_engine

# 系统托盘（跨平台：Windows=win32 / macOS=pyobjc / Linux=appindicator）。
# 惰性容错导入：缺失也不阻断启动（无托盘，核心功能不受影响），便于在未装 pystray 的
# 环境里只跑/测逻辑。打包时 spec 会显式收集 pystray + PIL。
try:
    import pystray
    from PIL import Image, ImageDraw
except Exception as _e:  # pragma: no cover
    pystray = None
    print(f"[warn] 未能导入 pystray/PIL（托盘将不可用）: {_e}")

# 输出（上屏 / 复制）
import pyperclip
from pynput import keyboard

IS_WINDOWS = sys.platform == "win32"
IS_MAC = sys.platform == "darwin"
# 上屏粘贴的修饰键：Windows/Linux=Ctrl+V，macOS=Cmd+V
PASTE_MOD = keyboard.Key.cmd if IS_MAC else keyboard.Key.ctrl

# 悬浮条尺寸（窗口本身即“面板”）
FLOAT_W, FLOAT_H = 480, 64
FLOAT_MARGIN_BOTTOM = 48        # 面板底边距屏幕可见区底部的距离

# 上屏后延迟还原剪贴板的等待秒数：给“慢读”目标（Office/Electron/RDP）足够时间读到我们
# 写入的文本，再放回用户原内容；放后台线程做，不拖住下一句上屏。
PASTE_RESTORE_DELAY = 0.6


# 轻量本地标点规整：仅当 ASCII 标点“两侧都是中日韩汉字”时转全角，
# 不动英文/数字/小数点（如 3,000 / v1.2 / OK,我）。跨平台一致。
_ASCII2FULL = {",": "，", ".": "。", "!": "！", "?": "？", ";": "；", ":": "："}
_CJK_PUNCT_RE = re.compile(r"(?<=[一-鿿㐀-䶿])([,.!?;:])(?=[一-鿿㐀-䶿])")


def normalize_cjk_punct(text: str) -> str:
    return _CJK_PUNCT_RE.sub(lambda m: _ASCII2FULL[m.group(1)], text)


def _user_data_dir(app: str = "Recorpaster") -> str:
    """跨平台用户数据目录（放日志）。Windows=%APPDATA%\\App，macOS/Linux 退回家目录约定。"""
    if IS_WINDOWS:
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
        return os.path.join(base, app)
    if IS_MAC:
        return os.path.expanduser(f"~/Library/Logs")
    return os.path.join(os.environ.get("XDG_STATE_HOME",
                                       os.path.expanduser("~/.local/state")), app)


class _Tee:
    """同时写多个流（控制台 + 日志文件），每行 flush。"""
    def __init__(self, *streams):
        self._streams = [s for s in streams if s is not None]

    def write(self, s):
        for st in self._streams:
            try:
                st.write(s)
                st.flush()
            except Exception:
                pass

    def flush(self):
        for st in self._streams:
            try:
                st.flush()
            except Exception:
                pass


def setup_logging():
    """打包后的 EXE 没有控制台，把 stdout/stderr 落到用户数据目录下的日志，便于排错。"""
    try:
        logdir = _user_data_dir()
        os.makedirs(logdir, exist_ok=True)
        f = open(os.path.join(logdir, "Recorpaster.log"), "a", buffering=1, encoding="utf-8")
        sys.stdout = _Tee(sys.__stdout__, f)
        sys.stderr = _Tee(sys.__stderr__, f)
        print(f"\n===== Recorpaster 启动 (pid {os.getpid()}) =====")
    except Exception as e:
        print(f"[warn] 日志文件初始化失败: {e}")


# 托盘图标的状态色（pystray 用 PIL 图像）
_TRAY_COLORS = {
    "idle":      (235, 235, 235, 255),
    "listening": (255, 80, 80, 255),
    "loading":   (150, 150, 150, 255),
    "warn":      (240, 200, 80, 255),
}


def _resource_dir() -> str:
    """资源根目录：PyInstaller 打包后用 sys._MEIPASS，否则用源码目录。"""
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        return sys._MEIPASS
    return os.path.dirname(os.path.abspath(__file__))


WEB_DIR = os.path.join(_resource_dir(), "web")
INDEX_HTML = os.path.join(WEB_DIR, "index.html")
SETTINGS_HTML = os.path.join(WEB_DIR, "settings.html")

# 改这些字段需要重建 engine（其余即时生效）
ENGINE_FIELDS = ("engine", "model", "language", "min_silence_ms", "vad_threshold", "quality_mode")


# ----------------------------------------------------------------------------
# 设置面板 ↔ Python 的桥（pywebview js_api：方法在 pywebview 工作线程上被调用）
# ----------------------------------------------------------------------------
class SettingsAPI:
    def __init__(self, app):
        self._app = app

    def get_settings(self):
        return self._app.cfg_dict

    def get_capabilities(self):
        return {
            "apple_silicon": IS_MAC and platform.machine() == "arm64",
            "auto_engine": default_engine(),
        }

    def save_settings(self, new):
        try:
            self._app.apply_settings(new or {})
            return {"ok": True}
        except Exception as e:
            print(f"[error] 应用设置失败: {e}")
            return {"ok": False, "error": str(e)}

    def close_settings(self):
        self._app.hide_settings()
        return {"ok": True}


# ----------------------------------------------------------------------------
# 主应用
# ----------------------------------------------------------------------------
class App:
    def __init__(self):
        self.cfg_dict = settings.load()
        self.hotkey_mode = self.cfg_dict.get("hotkey_mode", "hold")
        self.output_mode = self.cfg_dict.get("output_mode", "paste")

        self.window = None
        self.settings_window = None
        self.engine: DictationEngine | None = None
        self.engine_ready = threading.Event()
        self.web_ready = threading.Event()

        self._session_lock = threading.RLock()
        # 会话状态机，避免“松开还没停完又按下”导致重复开麦/双 InputStream：
        #   idle → (begin) → active → (end) → stopping → idle
        self._state = "idle"              # idle | active | stopping
        self._pending_begin = False       # stopping 期间又想开 → 停完立即重开
        self._key_down = False            # 热键去抖（过滤自动重复）

        # 悬浮条可见性控制器：与引擎收尾完全解耦，严格跟随热键状态。
        # _vis_epoch 每次切换自增，用于取消在途的延迟 hide（快速连按健壮）。
        self._vis_lock = threading.Lock()
        self._vis_visible = False
        self._vis_epoch = 0
        self._noactivate_done = False     # Windows 不抢焦点：只设一次

        self._kb = keyboard.Controller()
        self._hotkey = self._resolve_hotkey(self.cfg_dict.get("hotkey", "f8"))
        self._hotkey_vk = self._key_vk(self._hotkey)   # Windows 按键级抑制用（见 _win32_event_filter）
        self._listener = None

        # 输出队列：识别线程只管入队，单独线程顺序上屏/复制，避免阻塞下一句识别
        self._out_q: "queue.Queue[str]" = queue.Queue()

        # 上屏后还原剪贴板的状态（沿用本工程的 epoch 套路，见 _vis_epoch）：一串连续上屏只在
        # 开头记一次“用户真实原始内容”；每次上屏自增 epoch，只有最后一次的延迟还原（epoch 仍最新）
        # 才执行，避免唤醒顺序/计数器把上一句文本当成原始内容还原回去。
        self._clip_lock = threading.Lock()
        self._clip_original: str | None = None   # 一串开头用户真实的剪贴板
        self._clip_text: str | None = None       # 我们最近一次写入的文本（还原前比对用）
        self._clip_active = False                 # 是否处于一串上屏中（决定是否重采样 original）
        self._clip_epoch = 0                      # 每次上屏自增，唯一标识“最后一次”

        # 托盘
        self._tray = None
        self._tray_state = "loading"

    # ---------------- 启动序列 ----------------
    def run(self):
        """主线程入口：建窗 → webview.start 占主线程跑 GUI 事件循环。"""
        self.window = webview.create_window(
            "听写",
            url=INDEX_HTML,
            width=FLOAT_W,
            height=FLOAT_H,
            frameless=True,
            easy_drag=False,
            on_top=True,
            transparent=True,     # Windows 透明支持视版本而定；失败也有 CSS 深色底兜底
            focus=False,          # 关键：不抢目标输入框焦点，Ctrl+V 才能落到正确的 App
            hidden=True,          # 默认隐藏，唤起时再显示
            resizable=False,
            background_color="#0B0B0F",
        )
        self.window.events.loaded += self._on_web_loaded

        # 设置窗：普通有标题栏窗口，可获得焦点（要填表单）；默认隐藏，点菜单才显示。
        self.settings_window = webview.create_window(
            "听写设置",
            url=SETTINGS_HTML,
            js_api=SettingsAPI(self),
            width=470,
            height=620,
            resizable=False,
            hidden=True,
            focus=True,
            background_color="#1e1e22",
        )
        self.settings_window.events.closing += self._on_settings_closing

        # func 在 GUI 起来后由 pywebview 在独立线程调用。
        # Windows：强制 EdgeChromium(WebView2) 后端——绝不静默回退到 IE11/MSHTML
        # （那会让 backdrop-filter/flexbox/ES6 全废且不报错）。缺运行时则弹清晰提示。
        if IS_WINDOWS:
            try:
                webview.start(self._on_started, gui="edgechromium")
            except Exception as e:
                self._fatal_webview2(e)
                raise
        else:
            webview.start(self._on_started)

    def _fatal_webview2(self, e):
        """Windows 上 WebView2 运行时缺失/初始化失败时给清晰提示（打包后无控制台也能看到）。"""
        es = str(e).lower()
        looks_runtime = any(k in es for k in
                            ("webview2", "edgechromium", "edge", "runtime", "clr", ".net"))
        print(f"[fatal] WebView2/EdgeChromium 启动失败: {e}")
        # CI 冒烟模式不弹模态框（无人点击会卡住）；让异常向上抛出即可被探针判红。
        if not looks_runtime or os.environ.get("RECORPASTER_SMOKE") == "1":
            return
        msg = ("无法启动界面：缺少 Microsoft Edge WebView2 运行时。\n\n"
               "请运行随安装包附带的 MicrosoftEdgeWebview2Setup.exe，或从\n"
               "https://go.microsoft.com/fwlink/p/?LinkId=2124703 下载安装后重试。")
        try:
            import ctypes
            ctypes.windll.user32.MessageBoxW(0, msg, "Recorpaster", 0x10)  # MB_ICONERROR
        except Exception:
            pass

    def _on_settings_closing(self):
        self.settings_window.hide()
        return False

    def _on_web_loaded(self):
        self.web_ready.set()

    def _on_started(self):
        """在后台线程执行；耗时的模型加载放这里，避免卡住主线程出窗。"""
        self._build_tray()
        threading.Thread(target=self._output_worker, daemon=True).start()
        self._start_hotkey()
        self._ensure_noactivate()   # Windows：首次显示前就把悬浮条设成“不抢焦点”
        # 冒烟模式（CI 真启动探针）：只验证 GUI/托盘/热键/WebView2 能起来，
        # 跳过模型加载（否则会从 HuggingFace 拉 ~1.5GB，CI 不需要、也太慢）。
        if os.environ.get("RECORPASTER_SMOKE") == "1":
            print("[smoke] 跳过模型加载，仅验证 GUI/托盘/热键/WebView2 启动。")
            self._set_tray_state("idle", "smoke 模式")
            return
        self._build_engine()

    # ---------------- 系统托盘（pystray）----------------
    def _build_tray(self):
        if pystray is None:
            print("[warn] 未安装 pystray，托盘不可用（核心功能不受影响）。")
            return
        try:
            menu = pystray.Menu(
                pystray.MenuItem("开始 / 停止听写", self._on_tray_toggle),
                pystray.MenuItem("设置…", self._on_tray_settings),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("退出", self._on_tray_quit),
            )
            self._tray = pystray.Icon(
                "Recorpaster", self._tray_image("loading"), "听写：加载模型中…", menu)
            # 托盘自带消息循环，放后台线程跑（Windows 上每线程独立消息循环，OK）
            threading.Thread(target=self._tray.run, daemon=True).start()
        except Exception as e:
            print(f"[warn] 托盘启动失败（核心功能不受影响）: {e}")
            self._tray = None

    @staticmethod
    def _tray_image(state):
        """画一个简单的麦克风图标（不同状态不同颜色）。"""
        if pystray is None:
            return None
        size = 64
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        c = _TRAY_COLORS.get(state, _TRAY_COLORS["idle"])
        d.rounded_rectangle([24, 10, 40, 38], radius=8, fill=c)   # 麦克风身
        d.arc([18, 24, 46, 50], start=0, end=180, fill=c, width=4)  # 支架弧
        d.line([32, 50, 32, 56], fill=c, width=4)                  # 杆
        d.line([23, 56, 41, 56], fill=c, width=4)                  # 底座
        return img

    # 托盘菜单回调（pystray 线程触发）→ 甩到后台线程，避免阻塞托盘 / 与 GUI 线程冲突
    def _on_tray_toggle(self, icon=None, item=None):
        threading.Thread(target=self.toggle_session, daemon=True).start()

    def _on_tray_settings(self, icon=None, item=None):
        threading.Thread(target=self.open_settings, daemon=True).start()

    def _on_tray_quit(self, icon=None, item=None):
        self.quit()

    def _set_tray_state(self, state, tooltip):
        self._tray_state = state
        if self._tray is None:
            return
        try:
            self._tray.icon = self._tray_image(state)
            self._tray.title = tooltip   # 悬停提示
        except Exception:
            pass

    def _rest_tray(self):
        """非听写态的托盘图标：已就绪→idle，否则 loading。"""
        if self.engine_ready.is_set():
            self._set_tray_state("idle", "听写就绪 · 长按热键说话")
        else:
            self._set_tray_state("loading", "加载模型中…")

    # ---------------- 引擎 ----------------
    @staticmethod
    def _hf_hub_dir() -> str:
        """HuggingFace hub 缓存目录，遵循 HF_HUB_CACHE / HF_HOME（与 huggingface_hub / faster-whisper
        下载时实际使用的目录一致）。旧实现硬编码 ~/.cache/huggingface/hub，用户若设了 HF_HOME 会
        误判“模型不存在”而每次都弹首次下载提示。"""
        try:
            # huggingface_hub 已综合 HF_HUB_CACHE/HF_HOME/默认路径解析好这个常量
            from huggingface_hub.constants import HF_HUB_CACHE
            if HF_HUB_CACHE:
                return HF_HUB_CACHE
        except Exception:
            pass
        env = os.environ.get("HF_HUB_CACHE") or os.environ.get("HUGGINGFACE_HUB_CACHE")
        if env:
            return env
        hf_home = os.environ.get("HF_HOME")
        if hf_home:
            return os.path.join(hf_home, "hub")
        return os.path.expanduser("~/.cache/huggingface/hub")

    @staticmethod
    def _model_cached(cfg) -> bool:
        """模型是否已在本地 HuggingFace 缓存（决定首次运行是否需要下载提示）。"""
        try:
            hub = App._hf_hub_dir()
            if cfg.engine == "mlx":
                repo = cfg.mlx_repo.replace("/", "--")
                return os.path.isdir(os.path.join(hub, f"models--{repo}"))
            # faster-whisper：扫描缓存里是否有匹配该模型名的 faster-whisper 仓库
            if not os.path.isdir(hub):
                return False
            key = str(cfg.model).lower()
            for name in os.listdir(hub):
                n = name.lower()
                if n.startswith("models--") and "faster-whisper" in n and key in n:
                    return True
            return False
        except Exception:
            return True   # 检测失败就别误报“需要下载”

    @staticmethod
    def _download_error_msg(e) -> str:
        es = str(e).lower()
        net = ("connection", "network", "timeout", "resolve", "http", "ssl",
               "offline", "name or service", "getaddrinfo", "max retries", "temporarily")
        if any(k in es for k in net):
            return "模型下载失败，请检查网络后重启"
        return "模型加载失败，详见日志"

    def _build_engine(self):
        cfg = settings.build_config(self.cfg_dict)
        downloading = not self._model_cached(cfg)
        if downloading:
            # 首次运行：模型未打进包，需从 HuggingFace 下载（别白屏卡住）
            self._set_tray_state("loading", "首次运行：下载模型中（约 1.5GB，请保持联网）…")
            self._show_persist("首次运行 · 下载模型中…（约 1.5GB，请保持联网）")
        else:
            self._set_tray_state("loading", f"加载 {cfg.engine} 模型中…")
        try:
            self.engine = DictationEngine(
                cfg, on_result=self._on_result, on_status=self._on_status
            )
        except Exception as e:
            msg = self._download_error_msg(e)
            print(f"[error] 引擎加载失败: {e}")
            self._set_tray_state("warn", msg)
            if downloading:
                self._toast(msg, secs=6)
            return
        self.engine_ready.set()
        if downloading:
            self._set_window_visible(False)   # 下载完隐藏提示
        self._rest_tray()
        print("✅ 引擎就绪，长按热键开始说话。")

    def _show_persist(self, msg: str):
        """持续显示一句状态（不自动淡出；用于较长的首次下载）。"""
        with self._vis_lock:
            self._vis_visible = True
            self._vis_epoch += 1
        self._show_window()
        self.js(f"window.toast({json.dumps(msg)})")

    def _on_status(self, s: str):
        if s == "listening":
            self.js("window.setStatus('listening','聆听中…')")
        else:
            print(f"[engine] {s}")
            self._set_tray_state("loading", s)

    def _on_result(self, r: Result):
        # 回调在引擎后台线程触发。展示 + 入输出队列（输出走独立线程，不阻塞下一句）。
        text = normalize_cjk_punct(r.text)
        print(f"📝 {text}  (音频 {r.audio_sec:.1f}s · 识别 {r.cost_sec:.2f}s · RTF {r.rtf:.2f})")
        self.js(f"window.showText({json.dumps(text)})")
        if self.output_mode in ("paste", "copy"):
            self._out_q.put(text)

    # ---------------- 输出（上屏 / 复制）----------------
    def _output_worker(self):
        while True:
            text = self._out_q.get()
            if text is None:
                break
            try:
                if self.output_mode == "paste":
                    self._paste(text)
                else:  # copy
                    pyperclip.copy(text)
            except Exception as e:
                print(f"[warn] 输出失败: {e}")

    def _paste(self, text: str):
        """剪贴板 + 模拟 Ctrl+V（对中文最稳）；延迟且有条件地还原“用户真实的原始剪贴板”。

        两个坑都修了：
        1) 旧实现固定 sleep(0.12) 后立刻还原——Office/Electron/RDP 等“慢读”目标会在还原之后才去
           读剪贴板，于是粘到旧内容。→ 把还原甩到后台线程，等 PASTE_RESTORE_DELAY 再做。
        2) 连续听写一串句子时，每句都把“当前剪贴板”当原始内容采样，会导致最终还原成上一句的文本
           而非用户真正的原始内容。→ 一串上屏只在开头采样一次原始内容；每次上屏自增 epoch，只有
           最后一次（epoch 仍最新）的延迟还原才执行，且把“比对+还原”整体放在锁内，杜绝唤醒顺序
           不定、以及新一串在还原间隙把上一句当原始内容重采样的竞争。仍要求剪贴板仍是我们写入的
           （用户中途改了就不覆盖）。"""
        with self._clip_lock:
            if not self._clip_active:
                try:
                    self._clip_original = pyperclip.paste()   # 一串的开头：记真实原始剪贴板
                except Exception:
                    self._clip_original = None
                self._clip_active = True
            self._clip_text = text
            self._clip_epoch += 1
            epoch = self._clip_epoch

        pyperclip.copy(text)
        time.sleep(0.05)
        with self._kb.pressed(PASTE_MOD):
            self._kb.press("v")
            self._kb.release("v")

        def _restore():
            time.sleep(PASTE_RESTORE_DELAY)
            with self._clip_lock:
                if epoch != self._clip_epoch:
                    return   # 之后又有上屏 → 交给更晚那次的还原负责（保证整串只还原一次）
                original = self._clip_original
                expected = self._clip_text
                self._clip_active = False
                if original is None:
                    return
                # 比对+还原放在锁内：新一串要重采样 original 必须等本次还原彻底完成（含 copy），
                # 否则会把刚粘的本句文本误当成“原始内容”。
                try:
                    if pyperclip.paste() == expected:   # 仍是我们最后写入的 → 安全还原；改了就不覆盖
                        pyperclip.copy(original)
                except Exception:
                    pass

        threading.Thread(target=_restore, daemon=True).start()

    # ---------------- 会话开关 ----------------
    # 设计：悬浮条「可见性」与引擎「会话状态」彻底解耦。
    #   · 可见性严格跟随热键/会话意图，由 _set_window_visible 幂等控制。
    #   · 引擎收尾（flush/stop/排空尾句）在后台线程独立进行，不拖住窗口；
    #     松开后窗口立刻淡出，尾句识别好了照常上屏（_on_result 不再触碰可见性）。
    def begin_session(self):
        outcome = "go"   # go | not_ready | mic_error | show | begin
        with self._session_lock:
            if not self.engine_ready.is_set():
                outcome = "not_ready"
            elif self._state == "active":
                outcome = "show"             # 已在听，确保可见即可
            elif self._state == "stopping":
                self._pending_begin = True   # 上一段还在收尾，停完再开
                outcome = "begin"
            else:
                self._state = "active"
                try:
                    self.engine.start()      # 锁内启动：保证启动的就是当前引擎
                    outcome = "begin"
                except Exception as e:
                    self._state = "idle"
                    print(f"[error] 启动麦克风失败（可能缺少麦克风权限/设备）: {e}")
                    outcome = "mic_error"
        if outcome == "not_ready":
            self._toast("模型还在加载，请稍候…")
            return
        if outcome == "mic_error":
            self._toast("麦克风启动失败，请检查设备")
            return
        self._set_window_visible(True)
        if outcome == "begin":
            self.js("window.beginSession()")
            self._set_tray_state("listening", "听写中…")

    def end_session(self):
        # key-up：窗口立即淡出（与引擎收尾解耦），无论引擎处于什么状态。
        self._set_window_visible(False)
        with self._session_lock:
            if self._state == "stopping":
                # 上一段还在收尾时又松开：取消可能排着的“停完重开”，别让幻影会话复活
                self._pending_begin = False
                self._rest_tray()
                return
            if self._state != "active":
                return
            self._state = "stopping"
        self._rest_tray()
        eng = self.engine

        def finish():
            # 松开收尾：先 flush 把最后半句强制送识别，再优雅停（识别线程会排空尾句）。
            if eng is not None:
                eng.flush()
                time.sleep(0.35)      # 让 VAD 收尾把尾句送入识别
                eng.stop()
                time.sleep(0.25)      # 等旧 vad 循环退出、InputStream 释放后再允许重开
            with self._session_lock:
                self._state = "idle"
                restart = self._pending_begin
                self._pending_begin = False
            if restart:
                self.begin_session()  # 收尾期间用户又按下：无缝接上

        threading.Thread(target=finish, daemon=True).start()

    def toggle_session(self):
        with self._session_lock:
            state = self._state
            if state == "stopping":
                self._pending_begin = not self._pending_begin
                want_on = self._pending_begin
        if state == "stopping":
            if want_on:
                self._set_window_visible(True)
                self.js("window.beginSession()")
                self._set_tray_state("listening", "听写中…")
            else:
                self._set_window_visible(False)
                self._rest_tray()
            return
        if state == "active":
            self.end_session()
        else:
            self.begin_session()

    # ---------------- 悬浮条可见性（幂等 + 可取消，快速连按健壮）----------------
    def _set_window_visible(self, visible: bool):
        """立即把窗口切到目标可见态。

        每次调用自增 epoch；淡出后的 hide() 延迟执行，只有 epoch 未被后续事件覆盖时才真正
        隐藏——于是“淡出途中又按下”会取消这次隐藏。CSS 过渡可被新 class 打断。
        """
        with self._vis_lock:
            self._vis_visible = visible
            self._vis_epoch += 1
            epoch = self._vis_epoch

        if visible:
            self._show_window()
            self.js("window.showWidget()")
        else:
            self.js("window.hideWidget()")   # 立即去 .visible，CSS 播放淡出

            def _finalize():
                time.sleep(0.22)             # 等淡出动画
                # epoch 复检 + hide 必须原子：与并发的 _set_window_visible(True)（先在锁内自增
                # epoch）串行化，避免“显示恰好落在复检与 hide 之间”被这次过期 hide 覆盖、卡在隐藏态。
                with self._vis_lock:
                    if self._vis_epoch != epoch:
                        return               # 期间又切了态 → 放弃这次隐藏
                    try:
                        if self.window is not None:
                            self.window.hide()
                    except Exception as e:
                        print(f"[warn] 隐藏悬浮窗失败: {e}")

            threading.Thread(target=_finalize, daemon=True).start()

    def _show_window(self):
        """定位到主屏底部居中并显示（pywebview 方法可从任意线程调用，内部会 marshal）。"""
        win = self.window
        if win is None:
            return
        try:
            self._win_make_noactivate()      # 先设“不抢焦点”再显示（窗口创建即有 HWND）
            self._position_window(win)
            win.show()
        except Exception as e:
            print(f"[warn] 显示悬浮窗失败: {e}")

    @staticmethod
    def _cursor_screen():
        """返回鼠标所在的 pywebview Screen（其 x/y/width/height 为逻辑像素，与 win.move 同坐标系）。
        非 Windows / 取不到 / 落不到任何屏时返回 None，由调用方退回主屏。

        关键：全程只用 pywebview 的逻辑坐标——和原来能正确摆位的代码同一坐标系，只是换成
        光标所在那块屏。绝不混入物理像素（曾因把物理坐标喂给逻辑像素的 win.move 而在缩放屏错位）。"""
        if not IS_WINDOWS:
            return None
        screens = getattr(webview, "screens", None)
        if not screens:
            return None
        try:
            import ctypes
            from ctypes import wintypes
            pt = wintypes.POINT()
            # 系统级 DPI 感知下（pywebview 默认），GetCursorPos 与 Screen.x/y 同处一套逻辑坐标。
            if not ctypes.windll.user32.GetCursorPos(ctypes.byref(pt)):
                return None
            for s in screens:
                if s.x <= pt.x < s.x + s.width and s.y <= pt.y < s.y + s.height:
                    return s
        except Exception:
            return None
        return None

    def _position_window(self, win):
        try:
            scr = self._cursor_screen()
            if scr is None:
                screens = getattr(webview, "screens", None)
                scr = screens[0] if screens else None
            if scr is None:
                return
            # 用所在屏的逻辑原点 + 尺寸定位到底部居中（主屏 x=y=0 时与旧行为完全一致）。
            x = int(scr.x + (scr.width - FLOAT_W) / 2)
            y = int(scr.y + scr.height - FLOAT_H - FLOAT_MARGIN_BOTTOM)
            win.move(x, y)
        except Exception as e:
            print(f"[warn] 悬浮窗摆位失败: {e}")

    def _ensure_noactivate(self):
        """Windows：在首次显示前尽量把悬浮条设成“不抢焦点”。窗口创建即有 HWND，可在显示前
        就设好；短重试等待原生窗口就绪（本方法在后台线程执行，sleep 无碍）。"""
        if not IS_WINDOWS:
            return
        for _ in range(20):
            self._win_make_noactivate()
            if self._noactivate_done:
                return
            time.sleep(0.1)

    def _win_hwnd(self) -> int:
        """取悬浮窗的原生 HWND。优先 pywebview 的 window.native.Handle（winforms 后端，精确、
        不受窗口标题影响）；取不到再退回按标题查找。返回 0 表示尚不可用。

        旧实现只用全局 FindWindowW(None,"听写")：与“听写设置”同前缀标题可能撞车、或标题被
        本地化/改名后静默失效。用 native.Handle 直接锁定本窗口，根除该脆弱耦合。"""
        win = self.window
        native = getattr(win, "native", None) if win is not None else None
        if native is not None:
            try:
                return int(native.Handle.ToInt32())   # winforms Form 的 HWND
            except Exception:
                pass
        try:
            import ctypes
            return int(ctypes.windll.user32.FindWindowW(None, "听写") or 0)
        except Exception:
            return 0

    def _win_make_noactivate(self):
        """把悬浮条设为「不激活 + 工具窗」，避免抢走目标 App 的键盘焦点。
        最佳努力：找不到窗口就不置 done（下次再试）；仅在成功设置后置 done（幂等）。"""
        if not IS_WINDOWS or self._noactivate_done:
            return
        try:
            import ctypes
            u = ctypes.windll.user32
            hwnd = self._win_hwnd()
            if not hwnd:
                return   # 原生窗口还没就绪，下次再试（不置 done）
            GWL_EXSTYLE = -20
            WS_EX_NOACTIVATE = 0x08000000
            WS_EX_TOOLWINDOW = 0x00000080
            ex = u.GetWindowLongW(hwnd, GWL_EXSTYLE)
            u.SetWindowLongW(hwnd, GWL_EXSTYLE, ex | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW)
            self._noactivate_done = True
        except Exception as e:
            self._noactivate_done = True   # 出错就别每次显示都重试报错
            print(f"[warn] 设置悬浮窗不抢焦点失败: {e}")

    def _toast(self, msg: str, secs: float = 1.8):
        """临时在悬浮条里提示一句；到点自动淡出（可被新事件取消）。"""
        with self._vis_lock:
            self._vis_visible = True
            self._vis_epoch += 1
            epoch = self._vis_epoch
        self._show_window()
        self.js(f"window.toast({json.dumps(msg)})")
        self.js("window.showWidget()")

        def _close():
            time.sleep(secs)
            with self._vis_lock:
                if self._vis_epoch != epoch:
                    return               # 期间有新的显隐事件 → 让它接管
            self._set_window_visible(False)

        threading.Thread(target=_close, daemon=True).start()

    # ---------------- 前端调用 ----------------
    def js(self, script: str):
        if not self.web_ready.is_set() or self.window is None:
            return
        try:
            self.window.evaluate_js(script)
        except Exception as e:
            print(f"[warn] evaluate_js 失败: {e}")

    # ---------------- 热键 ----------------
    @staticmethod
    def _resolve_hotkey(name: str):
        try:
            return getattr(keyboard.Key, name)
        except AttributeError:
            return keyboard.KeyCode.from_char(name)

    @staticmethod
    def _key_vk(key):
        """取热键对应的 Windows 虚拟键码（按键级抑制用）；取不到返回 None。"""
        vk = getattr(key, "vk", None)                  # KeyCode（如 from_char）
        if vk is None:
            val = getattr(key, "value", None)          # Key 枚举 → 其内部 KeyCode
            vk = getattr(val, "vk", None)
        return vk

    def _win32_event_filter(self, msg, data):
        """Windows：只抑制“听写热键”这一个键，使其不漏给前台程序——hold 模式下长按
        修饰键（如右 Alt=AltGr）不会污染目标输入/上屏——但仍照常触发本监听器的
        on_press/on_release。其余按键一律放行（绝不全局抑制）。"""
        try:
            if self._hotkey_vk is not None and data.vkCode == self._hotkey_vk:
                self._listener.suppress_event()
        except Exception:
            pass

    def _start_hotkey(self):
        def on_press(key):
            if not self._key_match(key) or self._key_down:
                return
            self._key_down = True
            if self.hotkey_mode == "hold":
                self.begin_session()
            else:  # toggle：按一下切换
                self.toggle_session()

        def on_release(key):
            if not self._key_match(key):
                return
            self._key_down = False
            if self.hotkey_mode == "hold":
                self.end_session()

        try:
            kwargs = {}
            if IS_WINDOWS:
                # 按键级抑制：只拦“听写热键”，回调照常触发（见 _win32_event_filter）。
                kwargs["win32_event_filter"] = self._win32_event_filter
            self._listener = keyboard.Listener(on_press=on_press, on_release=on_release, **kwargs)
            self._listener.start()
        except Exception as e:
            print(f"[warn] 全局热键监听启动失败: {e}")
            return
        mode = "长按推杆" if self.hotkey_mode == "hold" else "按一下切换"
        print(f"🎹 热键监听已启动（{self.cfg_dict.get('hotkey','f8')} · {mode}）。")

    def _key_match(self, key) -> bool:
        return key == self._hotkey

    # ---------------- 设置面板 ----------------
    def open_settings(self):
        if self.settings_window is not None:
            self.settings_window.show()
            try:
                self.settings_window.evaluate_js("window.__refresh && window.__refresh()")
            except Exception as e:
                print(f"[warn] 刷新设置面板失败: {e}")

    def hide_settings(self):
        if self.settings_window is not None:
            self.settings_window.hide()

    def apply_settings(self, new: dict):
        """改完即时生效并持久化：输出方式/热键即时切，引擎相关字段重建 engine。"""
        old = dict(self.cfg_dict)
        for k, v in new.items():
            if k in self.cfg_dict and v is not None:   # 只接受已知且非空字段
                self.cfg_dict[k] = v
        settings.save(self.cfg_dict)

        # 1) 即时生效：输出方式
        self.output_mode = self.cfg_dict.get("output_mode", "paste")

        # 2) 热键 / 模式变了 → 只更新字段，监听器常驻复用（不销毁+重建）。
        #    on_press/on_release 每次都读最新字段，改字段即生效。
        if (self.cfg_dict.get("hotkey") != old.get("hotkey")
                or self.cfg_dict.get("hotkey_mode") != old.get("hotkey_mode")):
            self.hotkey_mode = self.cfg_dict.get("hotkey_mode", "hold")
            self._hotkey = self._resolve_hotkey(self.cfg_dict.get("hotkey", "f8"))
            self._hotkey_vk = self._key_vk(self._hotkey)   # 抑制用 vk 同步更新
            self._key_down = False
            print(f"🎹 热键已更新（{self.cfg_dict.get('hotkey','f8')} · "
                  f"{'长按' if self.hotkey_mode=='hold' else '切换'}）—— 监听器复用。")

        # 3) 引擎相关字段变了 → 重建 engine（会重载模型）
        if any(self.cfg_dict.get(k) != old.get(k) for k in ENGINE_FIELDS):
            self._rebuild_engine()

    def _rebuild_engine(self):
        """改配置 = 重建 engine：（锁内）关闸停旧 → 锁外加载新模型 → （锁内）原子换上。"""
        with self._session_lock:
            self.engine_ready.clear()
            was_running = self._state != "idle"
            self._state = "idle"
            self._pending_begin = False
            old_eng = self.engine
            if was_running and old_eng is not None:
                try:
                    old_eng.stop()
                except Exception:
                    pass
        if was_running:
            self._set_window_visible(False)
        self._set_tray_state("loading", "应用新设置，重载模型中…")
        cfg = settings.build_config(self.cfg_dict)
        try:
            new_eng = DictationEngine(cfg, on_result=self._on_result, on_status=self._on_status)
        except Exception as e:
            print(f"[error] 重载引擎失败: {e}")
            self._set_tray_state("warn", f"重载失败: {e}")
            with self._session_lock:      # 回退到旧引擎，保持可用
                if old_eng is not None:
                    self.engine = old_eng
                    self.engine_ready.set()
            raise
        with self._session_lock:          # 原子换引擎 + 开闸
            self.engine = new_eng
            self.engine_ready.set()
        if old_eng is not None:
            try:
                old_eng.stop()
            except Exception:
                pass
        self._rest_tray()
        print(f"✅ 已应用新设置（引擎={cfg.engine} · 模型={cfg.model}）。")

    def quit(self):
        print("\n正在退出…")
        try:
            if self._listener is not None:
                self._listener.stop()
        except Exception:
            pass
        try:
            if self.engine is not None:
                self.engine.stop()
        except Exception:
            pass
        try:
            if self._tray is not None:
                self._tray.stop()
        except Exception:
            pass
        try:
            if self.settings_window is not None:
                self.settings_window.destroy()
        except Exception:
            pass
        try:
            if self.window is not None:
                self.window.destroy()   # 销毁主窗 → 结束 webview.start，进程退出
        except Exception:
            pass


def run_selftest() -> int:
    """无头自检（--selftest）：导入全部原生依赖 → 校验打包资源 → 读配置 →
    加载并跑一帧 Silero VAD onnx。全程不开麦克风、不开 GUI。

    成功打印 'selftest OK' 返回 0；任一检查失败返回 1。CI 用它在干净 x64 Windows 上
    确定性地抓住冻结 EXE 的 DLL/ABI 加载崩溃（ctranslate2 / onnxruntime / PyAV /
    pythonnet-CLR 等原生件是打包后最大的未知）。"""
    print("===== Recorpaster selftest 开始 =====")
    failures = []

    def check(name, fn):
        try:
            info = fn()
            print(f"[selftest] OK   {name}" + (f" · {info}" if info else ""))
        except Exception as e:
            failures.append(name)
            print(f"[selftest] FAIL {name}: {e!r}")

    def _imp(mod):
        m = __import__(mod)
        return getattr(m, "__version__", "")

    # 1) 原生依赖导入（ABI/DLL 加载——冻结 EXE 最大的未知）
    for mod in ("numpy", "sounddevice", "pynput", "pyperclip", "onnxruntime",
                "ctranslate2", "faster_whisper", "av", "huggingface_hub",
                "webview", "pystray", "PIL"):
        check(f"import {mod}", lambda mod=mod: _imp(mod))
    # Windows 专属后端：pythonnet/CLR（pywebview EdgeChromium 后端）+ pystray win32
    if IS_WINDOWS:
        check("import clr (pythonnet/.NET)", lambda: _imp("clr"))
        check("import pystray._win32", lambda: (__import__("pystray._win32"), "win32")[1])

    # 2) 打包内资源齐全（前端 HTML）
    def _assets():
        missing = [p for p in (INDEX_HTML, SETTINGS_HTML) if not os.path.isfile(p)]
        if missing:
            raise FileNotFoundError("缺少 web 资源: " + ", ".join(missing))
        return "web/index.html + settings.html"
    check("打包资源 web/", _assets)

    # 3) 读配置（不触碰 GUI/麦克风）
    check("settings.load()", lambda: f"hotkey={settings.load().get('hotkey')}")

    # 4) 加载 Silero VAD onnx 并跑一帧推理（最实在的 onnxruntime + numpy ABI 检验）
    def _vad():
        import numpy as np
        from engine import _find_silero_onnx, _OnnxSileroModel
        path = _find_silero_onnx()
        prob = _OnnxSileroModel(path)(np.zeros(512, dtype=np.float32))
        if not (0.0 <= prob <= 1.0):
            raise ValueError(f"VAD 概率越界: {prob}")
        return f"{os.path.basename(path)} · prob={prob:.4f}"
    check("Silero VAD onnx 加载+推理", _vad)

    if failures:
        print(f"❌ selftest FAILED（{len(failures)} 项）: {', '.join(failures)}")
        return 1
    print("selftest OK")
    return 0


def main():
    setup_logging()
    if "--selftest" in sys.argv:
        sys.exit(run_selftest())
    print("=" * 60)
    print(" 轻量化本地语音听写工具（Windows 版）")
    print(" 长按热键说话；松开停止。系统托盘图标可设置/退出。")
    print("=" * 60)
    App().run()


if __name__ == "__main__":
    main()
