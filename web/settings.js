// 设置面板前端：通过 pywebview.api 与 Python 后端通信。
// get_settings / get_capabilities / save_settings / close_settings 由 app.py 的 SettingsAPI 提供。

const $ = (id) => document.getElementById(id);
let CAPS = { apple_silicon: true, auto_engine: 'mlx' };

// —— 分段按钮（output_mode / hotkey_mode）——
function setupSeg(id) {
  const box = $(id);
  box.addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-v]');
    if (!btn) return;
    box.querySelectorAll('button').forEach(b => b.classList.toggle('active', b === btn));
  });
}
function getSeg(id) {
  const a = $(id).querySelector('button.active');
  if (a) return a.dataset.v;
  // 没有任何选中（配置含越界值）→ 退回该组第一个按钮的值，绝不返回 null
  const first = $(id).querySelector('button[data-v]');
  return first ? first.dataset.v : null;
}
function setSeg(id, val) {
  $(id).querySelectorAll('button').forEach(b => b.classList.toggle('active', b.dataset.v === val));
}

function bindSlider(id, fmt) {
  const el = $(id), out = $(id + '_val');
  const upd = () => { out.textContent = fmt ? fmt(el.value) : el.value; };
  el.addEventListener('input', upd);
  return upd;
}
const updSilence = bindSlider('min_silence_ms');
const updVad = bindSlider('vad_threshold', v => Number(v).toFixed(2));

// 高级折叠
$('adv-toggle').addEventListener('click', () => {
  $('adv-toggle').classList.toggle('open');
  $('adv-body').classList.toggle('hidden');
});

function setStatus(msg, kind) {
  const s = $('status');
  s.textContent = msg || '';
  s.className = 'muted' + (kind ? ' ' + kind : '');
}

function fill(s) {
  $('model').value = s.model || 'large-v3-turbo';
  $('min_silence_ms').value = s.min_silence_ms ?? 300; updSilence();
  setSeg('output_mode', s.output_mode || 'paste');
  $('hotkey').value = s.hotkey || 'alt_r';
  setSeg('hotkey_mode', s.hotkey_mode || 'hold');
  $('engine').value = s.engine || 'auto';
  // 非 Apple Silicon 上把残留的 engine=mlx 纠正回 auto（在赋值之后做才有效）
  if (!CAPS.apple_silicon && $('engine').value === 'mlx') $('engine').value = 'auto';
  $('vad_threshold').value = s.vad_threshold ?? 0.5; updVad();
  $('quality_mode').checked = !!s.quality_mode;
}

function applyCaps() {
  $('engine-now').textContent = '当前引擎：' + (CAPS.auto_engine === 'mlx' ? 'mlx（Apple GPU）' : 'faster-whisper（CPU）');
  if (!CAPS.apple_silicon) {
    // 非 Apple Silicon：禁用 mlx 选项，并把任何残留的 engine=mlx 纠正回 auto
    const opt = $('engine').querySelector('option[value=mlx]');
    if (opt) { opt.disabled = true; opt.textContent += '（本机不支持）'; }
    $('engine-hint').textContent = '本机非 Apple Silicon，仅 faster-whisper(CPU) 可用';
  }
}

function collect() {
  let engine = $('engine').value;
  if (!CAPS.apple_silicon && engine === 'mlx') engine = 'auto';   // 双保险：绝不存 mlx 到非 AS
  return {
    model: $('model').value,
    min_silence_ms: parseInt($('min_silence_ms').value, 10),
    output_mode: getSeg('output_mode'),
    hotkey: $('hotkey').value,
    hotkey_mode: getSeg('hotkey_mode'),
    engine: engine,
    vad_threshold: parseFloat($('vad_threshold').value),
    quality_mode: $('quality_mode').checked,
  };
}

async function save() {
  const btn = $('save');
  btn.disabled = true;
  setStatus('应用中…（切换模型/引擎需重载，请稍候）');
  try {
    const res = await window.pywebview.api.save_settings(collect());
    if (res && res.ok) setStatus('已保存并应用 ✓', 'ok');
    else setStatus('保存失败：' + (res && res.error || '未知错误'), 'err');
  } catch (e) {
    setStatus('保存失败：' + e, 'err');
  } finally {
    btn.disabled = false;
  }
}

// 重新拉取并填充（每次打开面板都调用，避免显示上次未保存的残留）
async function refresh() {
  try {
    CAPS = await window.pywebview.api.get_capabilities();
    applyCaps();
    fill(await window.pywebview.api.get_settings());
    setStatus('');
  } catch (e) {
    setStatus('读取设置失败：' + e, 'err');
  }
}
window.__refresh = refresh;

// 一次性绑定监听器（不要在 refresh 里重复绑定）
async function init() {
  setupSeg('output_mode');
  setupSeg('hotkey_mode');
  $('save').addEventListener('click', save);
  $('cancel').addEventListener('click', () => window.pywebview.api.close_settings());
  await refresh();
}

// pywebview 注入 api 后再初始化
if (window.pywebview && window.pywebview.api) init();
else window.addEventListener('pywebviewready', init);
