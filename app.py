#!/usr/bin/env python3
"""
轻量化本地语音转文字工具 — Phase 1（核心闭环）

长按热键（默认右 Option）→ 唤出悬浮窗 + 开始听写 → 实时把语音转文字
→ 剪贴板+Cmd+V 上屏（或仅复制）→ 松开停止、淡出。常驻菜单栏。

架构要点（macOS 主线程 run-loop 协调，见 README“已知坑”）：
  · pywebview 占用主线程 NSApplication run-loop（webview.start 阻塞主线程）。
  · 菜单栏托盘用原生 pyobjc NSStatusItem，注入到 pywebview 同一个 run-loop，
    不再起第二个 run-loop（避免和 rumps/pystray 抢主线程）。
  · 全局热键用 pynput，其监听器跑在自己的线程，不碰主线程。
  · 悬浮窗用 focus=False 创建（canBecomeKeyWindow=False），并用
    orderFrontRegardless 显示 → 不抢占目标输入框焦点，Cmd+V 才能落到正确的 App。

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
from engine import DictationEngine, Result

# pyobjc（菜单栏托盘 + 原生窗口微调 + 权限检测 + 毛玻璃）
import AppKit
from AppKit import (
    NSApp,
    NSScreen,
    NSEvent,
    NSImage,
    NSColor,
    NSStatusBar,
    NSMenu,
    NSMenuItem,
    NSVariableStatusItemLength,
    NSApplicationActivationPolicyAccessory,
    NSVisualEffectView,
    NSVisualEffectStateActive,
    NSVisualEffectBlendingModeBehindWindow,
    NSVisualEffectMaterialHUDWindow,
    NSVisualEffectMaterialPopover,
    NSViewWidthSizable,
    NSViewHeightSizable,
)
from Foundation import NSObject
from PyObjCTools import AppHelper
import objc

# 悬浮窗尺寸（窗口本身即“玻璃面板”）
FLOAT_W, FLOAT_H = 480, 58
FLOAT_RADIUS = 18.0
FLOAT_MARGIN_BOTTOM = 40        # 面板底边距活动屏可见区底部的距离

# —— 玻璃外观（易调参数）——
# 用户选定 Clear 风格。真·Liquid Glass(NSGlassEffectView) 仅 macOS 26+ 原生可用，
# < 26 自动回退到 NSVisualEffectView（CSS 再叠 Clear 质感，但桌面模糊来自原生层）。
GLASS_STYLE = "clear"                 # "clear" | "regular"（macOS 26 原生风格）
GLASS_TINT_WHITE = 1.0                # tint 颜色（白）
GLASS_TINT_ALPHA = 0.06               # tint 透明度：Clear 极低、近乎无色
# < macOS 26 的回退材质：Popover 比 HUD 更亮更通透，更贴近 “Clear” 取向
VIBRANCY_MATERIAL = NSVisualEffectMaterialPopover


def macos_major() -> int:
    try:
        return int(platform.mac_ver()[0].split(".")[0])
    except Exception:
        return 0


# 轻量本地标点规整：仅当 ASCII 标点“两侧都是中日韩汉字”时转全角，
# 不动英文/数字/小数点（如 3,000 / v1.2 / OK,我）。口语转书面留给 Phase 3。
_ASCII2FULL = {",": "，", ".": "。", "!": "！", "?": "？", ";": "；", ":": "："}
_CJK_PUNCT_RE = re.compile(r"(?<=[一-鿿㐀-䶿])([,.!?;:])(?=[一-鿿㐀-䶿])")


def normalize_cjk_punct(text: str) -> str:
    return _CJK_PUNCT_RE.sub(lambda m: _ASCII2FULL[m.group(1)], text)


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
    """打包后的 .app 没有控制台，把 stdout/stderr 落到 ~/Library/Logs/Recorpaster.log，
    方便排错（也便于开发期核对）。"""
    try:
        logdir = os.path.expanduser("~/Library/Logs")
        os.makedirs(logdir, exist_ok=True)
        f = open(os.path.join(logdir, "Recorpaster.log"), "a", buffering=1, encoding="utf-8")
        sys.stdout = _Tee(sys.__stdout__, f)
        sys.stderr = _Tee(sys.__stderr__, f)
        print(f"\n===== Recorpaster 启动 @ {os.environ.get('TZ','')} (pid {os.getpid()}) =====")
    except Exception as e:
        print(f"[warn] 日志文件初始化失败: {e}")

# 菜单栏图标：单色 template SF Symbol，随系统明暗自适应
TRAY_SYMBOLS = {
    "idle":      "mic",
    "listening": "mic.fill",
    "loading":   "arrow.triangle.2.circlepath",
    "warn":      "exclamationmark.triangle",
}

# 输出（上屏 / 复制）
import pyperclip
from pynput import keyboard

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

# NSWindow collectionBehavior：跨所有 Space + 不随 Space 切换移动 + 浮在全屏 App 之上
_NS_CB_CAN_JOIN_ALL_SPACES = 1 << 0
_NS_CB_STATIONARY = 1 << 4
_NS_CB_FULLSCREEN_AUX = 1 << 8


# ----------------------------------------------------------------------------
# 菜单栏托盘的动作接收器（pyobjc 需要一个 NSObject 来接 selector）
# ----------------------------------------------------------------------------
class _MenuTarget(NSObject):
    def initWithApp_(self, app):
        self = objc.super(_MenuTarget, self).init()
        if self is None:
            return None
        self._app = app
        return self

    # 菜单动作在主线程触发；这些方法会调用 evaluate_js（同步等待主线程），
    # 若在主线程直接跑会“等自己”→死锁。因此一律甩到后台线程执行。
    def toggle_(self, sender):
        threading.Thread(target=self._app.toggle_session, daemon=True).start()

    def openSettings_(self, sender):
        threading.Thread(target=self._app.open_settings, daemon=True).start()

    def quitApp_(self, sender):
        self._app.quit()


# ----------------------------------------------------------------------------
# 设置面板 ↔ Python 的桥（pywebview js_api：方法在 pywebview 工作线程上被调用）
# ----------------------------------------------------------------------------
class SettingsAPI:
    def __init__(self, app):
        self._app = app

    def get_settings(self):
        return self._app.cfg_dict

    def get_capabilities(self):
        import platform
        from engine import default_engine
        return {
            "apple_silicon": platform.system() == "Darwin" and platform.machine() == "arm64",
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
        self._trusted = True              # 辅助功能/输入监控 是否已授权

        # 悬浮窗可见性控制器：与引擎收尾完全解耦，严格跟随热键状态。
        # _vis_epoch 每次切换自增，用于取消在途的延迟 orderOut（快速连按健壮）。
        self._vis_lock = threading.Lock()
        self._vis_visible = False
        self._vis_epoch = 0
        self._vev = None                  # NSVisualEffectView 引用（<26 回退）
        self._glass = None                # NSGlassEffectView 引用（macOS 26+ 原生）

        self._kb = keyboard.Controller()
        self._hotkey = self._resolve_hotkey(self.cfg_dict.get("hotkey", "alt_r"))
        self._listener = None

        # 输出队列：识别线程只管入队，单独线程顺序上屏/复制，避免阻塞下一句识别
        self._out_q: "queue.Queue[str]" = queue.Queue()

        # 托盘强引用（不持有会被 GC，菜单点击即失效）
        self._status_item = None
        self._menu_target = None
        self._toggle_item = None

    # ---------------- 启动序列 ----------------
    def run(self):
        """主线程入口：建窗 → webview.start 占主线程跑 run-loop。"""
        # 计算窗口尺寸；位置在 on_started 里用原生坐标精确摆放
        self.window = webview.create_window(
            "听写",
            url=INDEX_HTML,
            width=FLOAT_W,
            height=FLOAT_H,
            frameless=True,
            easy_drag=False,
            on_top=True,
            transparent=True,
            vibrancy=True,        # 注入原生 NSVisualEffectView（毛玻璃）到透明 webview 之后
            focus=False,          # 关键：canBecomeKeyWindow=False，不抢目标输入框焦点
            hidden=True,          # 默认隐藏，唤起时再显示
            resizable=False,
            background_color="#000000",
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
        # 拦截“关闭”：改为隐藏，保留实例复用（返回 False 取消真正关闭）
        self.settings_window.events.closing += self._on_settings_closing

        # func 在 GUI 起来后由 pywebview 在独立线程调用
        webview.start(self._on_started, gui="cocoa")

    def _on_settings_closing(self):
        self.settings_window.hide()
        return False

    def _on_web_loaded(self):
        self.web_ready.set()

    def _on_started(self):
        """在后台线程执行；耗时的模型加载放这里，避免卡住主线程出窗。"""
        # 1) 改为菜单栏 App（隐藏 Dock 图标）+ 原生窗口微调（主线程）
        AppHelper.callAfter(self._configure_native)
        # 2) 建托盘（必须主线程）
        AppHelper.callAfter(self._build_tray)
        # 3) 权限自检 + 必要时弹系统授权引导
        self._check_permissions()
        # 4) 起输出线程 + 热键监听
        threading.Thread(target=self._output_worker, daemon=True).start()
        self._start_hotkey()
        # 5) 加载并预热引擎（最慢，放最后；期间托盘显示 ⏳）
        self._build_engine()

    # ---------------- 原生窗口微调 ----------------
    def _configure_native(self):
        try:
            NSApp().setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        except Exception as e:
            print(f"[warn] setActivationPolicy 失败: {e}")

        # 等 native 窗口就绪后：玻璃材质 + 圆角 + 柔和投影 + 点击穿透 + 跨 Space/全屏悬浮。
        # 位置不在此固定——每次唤起时按“活动屏”重算（见 _set_window_visible）。
        def setup():
            win = getattr(self.window, "native", None)
            if win is None:
                AppHelper.callLater(0.1, setup)
                return
            try:
                win.setIgnoresMouseEvents_(True)        # 纯展示，点击穿透到下层 App
                win.setCollectionBehavior_(
                    _NS_CB_CAN_JOIN_ALL_SPACES | _NS_CB_STATIONARY | _NS_CB_FULLSCREEN_AUX
                )
                win.setHasShadow_(True)                 # 圆角面板的柔和投影
                # macOS 26+ 用原生 Liquid Glass；否则回退 NSVisualEffectView。
                if not (macos_major() >= 26 and self._setup_liquid_glass(win)):
                    self._setup_vibrancy(win)
                win.invalidateShadow()
            except Exception as e:
                print(f"[warn] 窗口微调失败: {e}")

        setup()

    def _setup_liquid_glass(self, win):
        """macOS 26+ 原生 Liquid Glass（NSGlassEffectView，Clear 风格）。

        WWDC25 要点：把透明 webview 设为 NSGlassEffectView 的 contentView（而非把玻璃当
        sibling 垫在内容后面）。本机为 macOS 15、无法实测，按文档防御式实现：任何环节失败
        都返回 False 交给 NSVisualEffectView 回退，绝不让 app 崩。
        返回 True 表示已成功套上原生玻璃。
        """
        GlassCls = getattr(AppKit, "NSGlassEffectView", None)
        if GlassCls is None:
            return False
        webview = win.contentView()                 # 当前 contentView 是 WKWebView
        try:
            glass = GlassCls.alloc().initWithFrame_(webview.frame())
            # 承重 API 必须存在，否则趁早回退（此时还没动任何不可逆操作）
            if not (glass.respondsToSelector_("setContentView:")
                    and win.respondsToSelector_("setContentView:")):
                return False
            glass.setAutoresizingMask_(NSViewWidthSizable | NSViewHeightSizable)
            if glass.respondsToSelector_("setCornerRadius:"):
                glass.setCornerRadius_(FLOAT_RADIUS)
            # Clear 风格（更透更亮、镜面感）——常量名按 WWDC25 命名，缺失则记录并走默认
            style_const = {
                "clear": getattr(AppKit, "NSGlassEffectViewStyleClear", None),
                "regular": getattr(AppKit, "NSGlassEffectViewStyleRegular", None),
            }.get(GLASS_STYLE)
            if style_const is not None and glass.respondsToSelector_("setStyle:"):
                glass.setStyle_(style_const)
            elif glass.respondsToSelector_("setStyle:"):
                print(f"[warn] NSGlassEffectView style 常量未解析（{GLASS_STYLE}），用默认风格")
            if glass.respondsToSelector_("setTintColor:"):
                glass.setTintColor_(
                    NSColor.colorWithWhite_alpha_(GLASS_TINT_WHITE, GLASS_TINT_ALPHA)
                )
            # 关键：webview 作为玻璃的 contentView（不是 sibling）
            glass.setContentView_(webview)
            win.setContentView_(glass)
            # 校验真的装上了；没装成就把 webview 设回窗口并回退，绝不留空窗
            if not (win.contentView() == glass and glass.contentView() == webview):
                win.setContentView_(webview)
                return False
            # 成功后才移除 pywebview 垫的那层 NSVisualEffectView（此前一直留着以保回退可用）
            stray = self._find_in_tree(webview, lambda v: v.isKindOfClass_(NSVisualEffectView))
            if stray is not None:
                stray.removeFromSuperview()
            self._glass = glass
            print(f"✅ 原生 Liquid Glass 已启用（NSGlassEffectView · {GLASS_STYLE}）")
            return True
        except Exception as e:
            # 尽量恢复 webview 为窗口内容，避免空窗；stray 从未被移除，回退仍能找到它
            try:
                if win.contentView() != webview:
                    win.setContentView_(webview)
            except Exception:
                pass
            print(f"[warn] NSGlassEffectView 装配失败，回退磨砂: {e}")
            return False

    @staticmethod
    def _find_in_tree(view, predicate):
        """在 view 子树里递归找第一个满足 predicate 的视图。"""
        try:
            subs = view.subviews()
        except Exception:
            return None
        for sub in subs:
            if predicate(sub):
                return sub
            found = App._find_in_tree(sub, predicate)
            if found is not None:
                return found
        return None

    def _setup_vibrancy(self, win, _tries=0):
        """把 pywebview(vibrancy=True) 注入的 NSVisualEffectView 调成磨砂圆角面板。

        该视图挂在 WKWebView 之下，且可能在 native 就绪后才挂上，故递归查找 + 短重试。
        """
        root = win.contentView()
        vev = self._find_in_tree(root, lambda v: v.isKindOfClass_(NSVisualEffectView))
        if vev is None and root is not None and root.superview() is not None:
            vev = self._find_in_tree(root.superview(),
                                     lambda v: v.isKindOfClass_(NSVisualEffectView))
        if vev is None:
            if _tries < 12:
                AppHelper.callLater(0.1, lambda: self._setup_vibrancy(win, _tries + 1))
            else:
                print("[warn] 未找到 NSVisualEffectView（毛玻璃可能不可用）")
            return
        self._vev = vev
        vev.setMaterial_(VIBRANCY_MATERIAL)   # Popover：比 HUD 更亮更通透，贴近 Clear 取向
        vev.setState_(NSVisualEffectStateActive)
        vev.setBlendingMode_(NSVisualEffectBlendingModeBehindWindow)
        vev.setWantsLayer_(True)
        layer = vev.layer()
        if layer is not None:
            layer.setCornerRadius_(FLOAT_RADIUS)
            layer.setMasksToBounds_(True)
        try:
            win.invalidateShadow()
        except Exception:
            pass
        print("✅ 玻璃面板已就绪（NSVisualEffectView 回退 · CSS 叠 Clear 质感 · 圆角）"
              "（真·Liquid Glass 需 macOS 26）")

    # ---------------- 菜单栏托盘 ----------------
    def _build_tray(self):
        self._menu_target = _MenuTarget.alloc().initWithApp_(self)
        bar = NSStatusBar.systemStatusBar()
        self._status_item = bar.statusItemWithLength_(NSVariableStatusItemLength)
        btn = self._status_item.button()
        img = self._tray_image("loading")
        if img is not None:
            btn.setImage_(img)
        else:
            btn.setTitle_("🎤")
        btn.setToolTip_("听写：加载模型中…")

        menu = NSMenu.alloc().init()
        menu.setAutoenablesItems_(False)

        self._toggle_item = self._mk_item("开始 / 停止听写", "toggle:")
        menu.addItem_(self._toggle_item)
        menu.addItem_(NSMenuItem.separatorItem())
        menu.addItem_(self._mk_item("设置…", "openSettings:"))
        menu.addItem_(NSMenuItem.separatorItem())
        menu.addItem_(self._mk_item("退出", "quitApp:"))

        self._status_item.setMenu_(menu)

    def _mk_item(self, title, selector):
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, selector, "")
        item.setTarget_(self._menu_target)
        return item

    @staticmethod
    def _tray_image(state):
        """单色 template SF Symbol（随系统明暗自适应）。"""
        name = TRAY_SYMBOLS.get(state, "mic")
        img = NSImage.imageWithSystemSymbolName_accessibilityDescription_(name, None)
        if img is not None:
            img.setTemplate_(True)
        return img

    def _set_tray_state(self, state, tooltip):
        def _do():
            if self._status_item is None:
                return
            btn = self._status_item.button()
            img = self._tray_image(state)
            if img is not None:
                btn.setImage_(img)
                btn.setTitle_("")
            else:
                # SF Symbol 不可用时退回 emoji，仍能传达状态
                btn.setImage_(None)
                btn.setTitle_({"listening": "🔴", "warn": "⚠️", "loading": "⏳"}.get(state, "🎤"))
            btn.setToolTip_(tooltip)
        AppHelper.callAfter(_do)

    def _rest_tray(self):
        """非听写态的托盘图标：缺权限→warn，已就绪→idle，否则 loading。"""
        if not self._trusted:
            self._set_tray_state("warn", "缺少 辅助功能/输入监控 权限，见 README")
        elif self.engine_ready.is_set():
            self._set_tray_state("idle", "听写就绪 · 长按右 Option 说话")
        else:
            self._set_tray_state("loading", "加载模型中…")

    # ---------------- 引擎 ----------------
    @staticmethod
    def _model_cached(cfg) -> bool:
        """模型是否已在本地缓存（决定首次运行是否需要下载）。"""
        if cfg.engine == "mlx":
            repo = cfg.mlx_repo.replace("/", "--")
            p = os.path.expanduser(f"~/.cache/huggingface/hub/models--{repo}")
            return os.path.isdir(p)
        return True   # faster-whisper 自行管理缓存

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
            self._set_tray_state("loading", "首次运行：下载模型中（约 1.6GB，请保持联网）…")
            self._show_persist("首次运行 · 下载模型中…（约 1.6GB，请保持联网）")
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
        self._rest_tray()   # idle（已授权）或 warn（缺权限）
        print("✅ 引擎就绪，长按右 Option 开始说话。")

    def _show_persist(self, msg: str):
        """持续显示一句状态（不自动淡出；用于较长的首次下载）。"""
        with self._vis_lock:
            self._vis_visible = True
            self._vis_epoch += 1
        def _show():
            win = getattr(self.window, "native", None)
            if win is not None:
                self._position_on_active_screen(win)
                win.orderFrontRegardless()
        AppHelper.callAfter(_show)
        self.js(f"window.toast({json.dumps(msg)})")

    def _on_status(self, s: str):
        # 引擎状态：加载提示 / "listening"
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
                print(f"[warn] 输出失败（可能缺少“辅助功能”权限）: {e}")

    def _paste(self, text: str):
        """剪贴板 + 模拟 Cmd+V（对中文最稳）；用完还原剪贴板。"""
        prev = pyperclip.paste()
        pyperclip.copy(text)
        time.sleep(0.05)
        with self._kb.pressed(keyboard.Key.cmd):
            self._kb.press("v")
            self._kb.release("v")
        time.sleep(0.12)
        pyperclip.copy(prev)   # 还原用户原本的剪贴板内容

    # ---------------- 会话开关 ----------------
    # 设计：悬浮窗「可见性」与引擎「会话状态」彻底解耦。
    #   · 可见性严格跟随热键/会话意图，由 _set_window_visible 幂等控制（见下）。
    #   · 引擎收尾（flush/stop/排空尾句）在后台线程独立进行，不再拖住窗口；
    #     松开后窗口立刻淡出，尾句识别好了照常上屏（_on_result 不再触碰可见性）。
    def begin_session(self):
        # engine_ready 检查 + engine.start() 必须与状态机、以及 _rebuild_engine 的
        # 关闸/停旧/换引擎处在同一把锁内，否则会在“正被替换的旧引擎”上 start()，
        # 造成孤儿麦克风流 + 双 VAD（Phase 2 审查确认的 TOCTOU）。
        outcome = "go"   # go | not_ready | mic_error | show
        with self._session_lock:
            if not self.engine_ready.is_set():
                outcome = "not_ready"
            elif self._state == "active":
                outcome = "show"             # 已在听，确保可见即可（不重置内容）
            elif self._state == "stopping":
                self._pending_begin = True   # 上一段还在收尾，停完再开
                outcome = "begin"            # key-down 立即给“聆听中”反馈（引擎稍后重启）
            else:
                self._state = "active"
                try:
                    self.engine.start()      # 锁内启动：保证启动的就是当前引擎
                    outcome = "begin"
                except Exception as e:
                    self._state = "idle"
                    print(f"[error] 启动麦克风失败（可能缺少“麦克风”权限）: {e}")
                    outcome = "mic_error"
        if outcome == "not_ready":
            self._toast("模型还在加载，请稍候…")
            return
        if outcome == "mic_error":
            self._toast("麦克风启动失败，请检查权限")
            return
        # show / begin：立即显示（key-down 即可见）
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
            # 注意：这里不再操作窗口——尾句识别好了由 _on_result 上屏即可，不依赖窗口还在。
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
                # 收尾中：翻转“停完是否重开”的意图，避免每次 toggle 都被当成 begin
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

    # ---------------- 悬浮窗可见性（幂等 + 可取消，快速连按健壮）----------------
    def _set_window_visible(self, visible: bool):
        """立即把窗口切到目标可见态。

        每次调用自增 epoch；淡出后的 orderOut 延迟执行，只有 epoch 未被后续事件
        覆盖时才真正下沉——于是“淡出途中又按下”会取消这次下沉，绝不会卡在隐藏/显示态。
        CSS 过渡天然可被新 class 打断，所以淡入/淡出动画也是随时可中断的。
        """
        with self._vis_lock:
            self._vis_visible = visible
            self._vis_epoch += 1
            epoch = self._vis_epoch

        if visible:
            # 先按活动屏摆位并 orderFront（主线程），再加 .visible 播放淡入
            def _show():
                win = getattr(self.window, "native", None)
                if win is None:
                    return
                self._position_on_active_screen(win)
                win.orderFrontRegardless()   # 显示但不激活本 App、不夺取键盘焦点
            AppHelper.callAfter(_show)
            self.js("window.showWidget()")
        else:
            self.js("window.hideWidget()")   # 立即去 .visible，CSS 播放淡出
            def _finalize():
                time.sleep(0.22)             # 等淡出动画
                # epoch 复检与 orderOut 必须在主线程同一块里原子完成：
                # callAfter 的主线程任务是串行的，若期间有 show 把 orderFront 排在前面，
                # 它会先执行，随后本块复读到已自增的 epoch 而跳过下沉（last-writer-wins）。
                def _order_out():
                    with self._vis_lock:
                        if self._vis_epoch != epoch:
                            return           # 期间又切了态 → 放弃这次下沉
                    win = getattr(self.window, "native", None)
                    if win is not None:
                        win.orderOut_(None)
                AppHelper.callAfter(_order_out)
            threading.Thread(target=_finalize, daemon=True).start()

    # ---------------- 多屏：定位到“当前活动屏”----------------
    @staticmethod
    def _active_screen():
        """鼠标光标所在的 NSScreen；找不到则退回 key window 所在屏 / 主屏。"""
        try:
            loc = NSEvent.mouseLocation()
            for s in NSScreen.screens():
                f = s.frame()
                if (f.origin.x <= loc.x <= f.origin.x + f.size.width and
                        f.origin.y <= loc.y <= f.origin.y + f.size.height):
                    return s
        except Exception:
            pass
        kw = NSApp().keyWindow()
        if kw is not None and kw.screen() is not None:
            return kw.screen()
        return NSScreen.mainScreen()

    def _position_on_active_screen(self, win):
        try:
            vf = self._active_screen().visibleFrame()
            size = win.frame().size
            x = vf.origin.x + (vf.size.width - size.width) / 2.0
            y = vf.origin.y + FLOAT_MARGIN_BOTTOM
            win.setFrameOrigin_((x, y))
        except Exception as e:
            print(f"[warn] 悬浮窗摆位失败: {e}")

    def _toast(self, msg: str, secs: float = 1.8):
        """临时在悬浮窗里提示一句（权限/设置/加载等）；到点自动淡出（可被新事件取消）。"""
        with self._vis_lock:
            self._vis_visible = True
            self._vis_epoch += 1
            epoch = self._vis_epoch

        def _show():
            win = getattr(self.window, "native", None)
            if win is None:
                return
            self._position_on_active_screen(win)
            win.orderFrontRegardless()
        AppHelper.callAfter(_show)
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
            self.window.evaluate_js(script)   # pywebview 内部 marshalling 到主线程
        except Exception as e:
            print(f"[warn] evaluate_js 失败: {e}")

    # ---------------- 热键 ----------------
    @staticmethod
    def _resolve_hotkey(name: str):
        try:
            return getattr(keyboard.Key, name)
        except AttributeError:
            return keyboard.KeyCode.from_char(name)

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

        self._listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        self._listener.start()
        mode = "长按推杆" if self.hotkey_mode == "hold" else "按一下切换"
        print(f"🎹 热键监听已启动（{self.cfg_dict.get('hotkey','alt_r')} · {mode}）。")

    def _key_match(self, key) -> bool:
        return key == self._hotkey

    # ---------------- 权限 ----------------
    def _check_permissions(self):
        trusted = True
        try:
            from ApplicationServices import (
                AXIsProcessTrusted,
                AXIsProcessTrustedWithOptions,
                kAXTrustedCheckOptionPrompt,
            )
            trusted = AXIsProcessTrusted()
            if not trusted:
                # 弹系统授权引导对话框（指向“辅助功能”）
                AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True})
        except Exception as e:
            print(f"[warn] 权限检测异常: {e}")
        self._trusted = trusted
        if not trusted:
            print(
                "\n⚠️  未取得「辅助功能 / 输入监控」权限：全局热键可能收不到、Cmd+V 上屏也会失败。\n"
                "   请到 系统设置 → 隐私与安全性 → 辅助功能 / 输入监控，勾选运行本程序的终端\n"
                "   （Terminal / iTerm / VS Code），然后重启本程序。详见 README。\n"
            )
            self._set_tray_state("warn", "缺少辅助功能/输入监控权限，见 README")

    # ---------------- 设置面板 ----------------
    def open_settings(self):
        # 窗口是复用的（关闭=隐藏），每次打开都重新拉取当前配置，避免显示上次未保存的残留。
        if self.settings_window is not None:
            self.settings_window.show()
            try:
                # 本方法在菜单后台线程执行，evaluate_js 会 marshalling 到主线程，安全
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
            if k in self.cfg_dict and v is not None:   # 只接受已知且非空字段（拒绝 null 枚举值）
                self.cfg_dict[k] = v
        settings.save(self.cfg_dict)      # 持久化（重启保留）

        # 1) 即时生效：输出方式
        self.output_mode = self.cfg_dict.get("output_mode", "paste")

        # 2) 热键 / 模式变了 → 重注册监听
        if (self.cfg_dict.get("hotkey") != old.get("hotkey")
                or self.cfg_dict.get("hotkey_mode") != old.get("hotkey_mode")):
            self.hotkey_mode = self.cfg_dict.get("hotkey_mode", "hold")
            self._hotkey = self._resolve_hotkey(self.cfg_dict.get("hotkey", "alt_r"))
            self._restart_hotkey()

        # 3) 引擎相关字段变了 → 重建 engine（会重载模型）
        if any(self.cfg_dict.get(k) != old.get(k) for k in ENGINE_FIELDS):
            self._rebuild_engine()

    def _rebuild_engine(self):
        """改配置 = 重建 engine：（锁内）关闸停旧 → 锁外加载新模型 → （锁内）原子换上。

        关闸(engine_ready.clear)、停旧、换引擎都在 _session_lock 内，与 begin_session 的
        “检查 ready + engine.start()”互斥，杜绝在被替换的旧引擎上 start()。模型加载耗时，
        放锁外，期间 engine_ready 为清空态，begin_session 在锁内会看到未就绪而退避。
        """
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

    def _restart_hotkey(self):
        try:
            if self._listener is not None:
                self._listener.stop()
        except Exception:
            pass
        self._key_down = False
        self._start_hotkey()

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
        AppHelper.callAfter(lambda: NSApp().terminate_(None))


def main():
    setup_logging()
    print("=" * 60)
    print(" 轻量化本地语音转文字工具 · Phase 1")
    print(" 长按右 Option 说话；松开停止。菜单栏图标可退出。")
    print("=" * 60)
    App().run()


if __name__ == "__main__":
    main()
