/**
 * [INPUT]: 原版 EmotionBall 引擎与原生面板的可见性、展示代际、任务表情和减少动态设置。
 * [OUTPUT]: pocketdeskDesktopOrb.update/state：空闲开心唤醒、任务完成一次庆祝后满意停留、状态切换、隐藏停帧及同状态不重播。
 * [POS]: 桌面表情适配器；复用原版眼环/眨眼/物理动画，不改几何，不接收正文，不执行任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';
  const engine = EmotionBall.create(document.getElementById('orb'), {
    emotion: '10', autostart: false, lite: false, idle: false
  });
  const allowed = new Set(['02', '10', '11', '19', '30', '31', '32', '33', '35']);
  const labels = { '02': '小精灵，待机', '10': '小精灵，开心迎接', '11': '小精灵，等你补充',
    '19': '小精灵，已回应', '30': '小精灵，正在核对', '31': '小精灵，接收任务',
    '32': '小精灵，正在处理', '33': '小精灵，任务完成', '35': '小精灵，聆听输入' };
  let model = { visible: false, revision: -1, emotion: '02', reduced: false, taskId: '' };
  let greeting = 0;
  let active = false;
  let celebration = 0, completedTask = '';
  function cancelCelebration() { clearTimeout(celebration); celebration = 0; }
  function cancelGreeting() {
    clearTimeout(greeting);
    greeting = 0;
  }
  function sync() {
    active = model.visible && !model.reduced && !document.hidden;
    engine.setActive(active);
    const completionKey = model.taskId || String(model.revision);
    if (model.emotion === '33' && completionKey !== completedTask) {
      if (!model.visible || model.reduced) completedTask = completionKey;
      else if (!document.hidden) {
        completedTask = completionKey;
        cancelCelebration();
        celebration = setTimeout(() => { celebration = 0; sync(); }, 2000);
        engine.setEmotion('33');
      }
      // WebKit 调整窗口尺寸时可能短暂不可见；真正可见后才消费庆祝事件。
    }
    const emotion = greeting ? '10' : model.emotion === '33' && !celebration ? '19' : model.emotion;
    if (engine.emotionId !== emotion) engine.setEmotion(emotion);
    if (!active) engine.renderStatic();
    document.getElementById('orb').setAttribute('aria-label', labels[emotion]);
  }
  function update(next) {
    const previous = model;
    model = { visible: !!next.visible, revision: next.revision,
      emotion: allowed.has(next.emotion) ? next.emotion : '02', reduced: !!next.reduced, taskId: next.taskId || '' };
    const wake = model.visible && (model.revision !== previous.revision || !previous.visible);
    if (!model.visible || model.reduced || model.emotion !== previous.emotion) cancelGreeting();
    if (!model.visible || model.reduced || model.emotion !== previous.emotion) cancelCelebration();
    // 执行/终态重选必须直接交代任务事实，不被开心欢迎遮住。
    if (wake && !model.reduced && ['02', '35'].includes(model.emotion)) {
      cancelGreeting();
      greeting = setTimeout(() => { greeting = 0; sync(); }, 1800);
      // 重选同一状态也重新开心回应；轮询不会触发此分支。
      engine.setActive(!document.hidden);
      engine.setEmotion('10');
      engine.bounce();
    }
    sync();
  }
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { cancelGreeting(); cancelCelebration(); }
    sync();
  });
  window.pocketdeskDesktopOrb = {
    update,
    state: () => ({ emotion: engine.emotionId, active, greeting: !!greeting })
  };
})();
