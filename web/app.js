// 悬浮条前端：Python 通过 window.evaluate_js(...) 调用下列函数。纯展示。
// 可见性（showWidget/hideWidget）与会话内容（beginSession/showText）解耦——
// 前者只控制淡入淡出，后者只更新内容与“聆听”状态。

const bar  = document.getElementById('bar');
const wave = document.getElementById('wave');
const textBox = document.getElementById('text');
const lineEl  = document.getElementById('line');

// —— 可见性（由 Python 的可见性控制器调用，幂等可中断）——
window.showWidget = function () {
  void bar.offsetWidth;            // 强制 reflow，确保过渡触发
  bar.classList.add('visible');
};
window.hideWidget = function () {
  bar.classList.remove('visible');
  bar.classList.remove('listening');   // 隐藏即停波形
};

// —— 会话内容 ——
// 新会话开始：清空、进入聆听态（波形动起来）、显示占位
window.beginSession = function () {
  bar.classList.add('listening');
  setLine('聆听中…', true);
};
// 会话结束（仅停波形；可见性由 hideWidget 负责）
window.endSession = function () {
  bar.classList.remove('listening');
};

// 出一句：替换当前行并播放“浮现”动画（单行，超长省略号）
window.showText = function (text) {
  if (!text) return;
  setLine(text, false);
};

// 状态文案（"listening" 时用占位灰；其余为正文色）
window.setStatus = function (state, msg) {
  if (state === 'listening') {
    bar.classList.add('listening');
    setLine(msg || '聆听中…', true);
  } else {
    setLine(msg || '', false);
  }
};

// 临时提示（权限/设置/加载）：停波形、正文色
window.toast = function (msg) {
  bar.classList.remove('listening');
  setLine(msg || '', false);
};

function setLine(text, placeholder) {
  textBox.classList.toggle('placeholder', !!placeholder);
  // 重建元素以重放出现动画
  lineEl.classList.remove('appear');
  lineEl.textContent = text;
  void lineEl.offsetWidth;
  if (!placeholder) lineEl.classList.add('appear');
}

window.__ready = true;
