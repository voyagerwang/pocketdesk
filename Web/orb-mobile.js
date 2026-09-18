/**
 * [INPUT]: EmotionBall 原版引擎、接收者/任务/草稿状态与页面可见性。
 * [OUTPUT]: pocketdeskOrb.update/destroy，唯一实例与点击保持眼形的整球轻抖，最初完整原图待机；切走/后台/离屏暂停，减少动态时静态呈现。
 * [POS]: 手机适配边界；不改原版表情配置和眼形，帧率预算在 orb-engine 限制。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  let engine = null, host = null, selected = false, visible = true;
  let desired = 'mobile-idle', wakeTimer = 0, wakeAnimation = null;
  const originalImage = 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9Ii0xNSAtMTUgMjU5IDI1OSIgd2lkdGg9IjEwMCUiIGhlaWdodD0iMTAwJSIgcm9sZT0iaW1nIiBhcmlhLWxhYmVsPSJBSSDooajmg4XlsI/nkIMiIHN0eWxlPSJkaXNwbGF5OiBibG9jazsgb3ZlcmZsb3c6IHZpc2libGU7Ij48ZGVmcz48cmFkaWFsR3JhZGllbnQgaWQ9ImViMGciIGN4PSIzOCUiIGN5PSIzMiUiIHI9Ijc1JSI+PHN0b3Agb2Zmc2V0PSIwJSIgc3RvcC1jb2xvcj0iI2Y2ZjNlZiI+PC9zdG9wPjxzdG9wIG9mZnNldD0iNjIlIiBzdG9wLWNvbG9yPSIjRjNGMEVBIj48L3N0b3A+PHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjZDZkM2NlIj48L3N0b3A+PC9yYWRpYWxHcmFkaWVudD48L2RlZnM+PGcgcG9pbnRlci1ldmVudHM9Im5vbmUiPjwvZz48ZyB0cmFuc2Zvcm09InRyYW5zbGF0ZSgxMTQuMjcgMTE0LjY4KSByb3RhdGUoMCkgc2NhbGUoMSkgdHJhbnNsYXRlKC0xMTQuMjcgLTExNC4yNykiPjxwYXRoIGQ9Ik0yMjguNTQgMTE0LjI3TDIyOC4yOSAxMjEuNzRMMjI3LjU1IDEyOS4xOEwyMjYuMzIgMTM2LjU2TDIyNC42MiAxNDMuODRMMjIyLjQ1IDE1MC45OUwyMTkuODIgMTU3Ljk5TDIxNi43MyAxNjQuODBMMjEzLjIwIDE3MS4zOUwyMDkuMjUgMTc3LjczTDIwNC44OSAxODMuODFMMjAwLjE1IDE4OS41OUwxOTUuMDQgMTk1LjA0TDE4OS41OSAyMDAuMTVMMTgzLjgxIDIwNC44OUwxNzcuNzMgMjA5LjI0TDE3MS4zOCAyMTMuMTlMMTY0Ljc4IDIxNi43MEwxNTcuOTcgMjE5Ljc4TDE1MC45OCAyMjIuNDBMMTQzLjgyIDIyNC41NkwxMzYuNTQgMjI2LjI1TDEyOS4xNyAyMjcuNDZMMTIxLjc0IDIyOC4xOUwxMTQuMjcgMjI4LjQ0TDEwNi44MCAyMjguMjBMOTkuMzcgMjI3LjQ4TDkxLjk5IDIyNi4yN0w4NC43MSAyMjQuNThMNzcuNTYgMjIyLjQyTDcwLjU2IDIxOS43OUw2My43NSAyMTYuNzFMNTcuMTYgMjEzLjE4TDUwLjgxIDIwOS4yNEw0NC43NCAyMDQuODlMMzguOTYgMjAwLjE1TDMzLjUwIDE5NS4wNEwyOC4zOSAxODkuNTlMMjMuNjUgMTgzLjgxTDE5LjI5IDE3Ny43M0wxNS4zNSAxNzEuMzhMMTEuODIgMTY0Ljc5TDguNzMgMTU3Ljk5TDYuMDkgMTUwLjk5TDMuOTIgMTQzLjg0TDIuMjEgMTM2LjU2TDAuOTkgMTI5LjE4TDAuMjUgMTIxLjc0TDAuMDAgMTE0LjI3TDAuMjUgMTA2LjgwTDAuOTggOTkuMzZMMi4yMCA5MS45OEwzLjkwIDg0LjcwTDYuMDYgNzcuNTRMOC42OSA3MC41NEwxMS43OCA2My43M0wxNS4zMCA1Ny4xM0wxOS4yNSA1MC43OEwyMy42MSA0NC43MEwyOC4zNSAzOC45MkwzMy40NiAzMy40NkwzOC45MSAyOC4zNEw0NC42OSAyMy41OUw1MC43NyAxOS4yNEw1Ny4xMiAxNS4yOUw2My43MiAxMS43N0w3MC41NCA4LjY5TDc3LjU0IDYuMDdMODQuNzAgMy45MEw5MS45OCAyLjIxTDk5LjM2IDEuMDBMMTA2LjgwIDAuMjZMMTE0LjI3IDAuMDFMMTIxLjc0IDAuMjVMMTI5LjE5IDAuOThMMTM2LjU3IDIuMTlMMTQzLjg1IDMuODhMMTUxLjAxIDYuMDRMMTU4LjAxIDguNjhMMTY0LjgyIDExLjc2TDE3MS40MiAxNS4yOUwxNzcuNzcgMTkuMjRMMTgzLjg0IDIzLjYwTDE4OS42MiAyOC4zNUwxOTUuMDggMzMuNDZMMjAwLjIwIDM4LjkyTDIwNC45NCA0NC43MEwyMDkuMjkgNTAuNzhMMjEzLjIzIDU3LjEzTDIxNi43NiA2My43M0wyMTkuODQgNzAuNTRMMjIyLjQ4IDc3LjU0TDIyNC42NSA4NC43MEwyMjYuMzQgOTEuOThMMjI3LjU2IDk5LjM2TDIyOC4yOSAxMDYuODBaIiBmaWxsPSJ1cmwoI2ViMGcpIiBzdHJva2U9Im5vbmUiIHN0cm9rZS13aWR0aD0iMiI+PC9wYXRoPjxwYXRoIGZpbGw9IiMxQTFBMUEiIHN0cm9rZT0ibm9uZSIgc3Ryb2tlLXdpZHRoPSIxLjYiIGQ9Ik0xMzAuMzYgNDUuOThMMTMyLjcxIDQ2LjE5TDEzNC45OCA0Ni44MUwxMzcuMTEgNDcuODNMMTM4Ljk3IDQ5LjI4TDE0MC40NyA1MS4wOUwxNDEuNjggNTMuMTJMMTQyLjczIDU1LjIzTDE0My43NiA1Ny4zNkwxNDQuNzggNTkuNDlMMTQ1Ljc5IDYxLjYyTDE0Ni43OSA2My43NkwxNDcuNzYgNjUuOTFMMTQ4LjcxIDY4LjA3TDE0OS42MyA3MC4yNUwxNTAuNTIgNzIuNDNMMTUxLjM3IDc0LjYzTDE1MS45OSA3Ni45MUwxNTIuMTAgNzkuMjZMMTUxLjY0IDgxLjU3TDE1MC41OSA4My42OEwxNDkuMDQgODUuNDVMMTQ3LjEwIDg2Ljc4TDE0NC45MCA4Ny42MkwxNDIuNTYgODcuOTNMMTQwLjIyIDg3LjcxTDEzNy45OCA4Ni45OUwxMzUuOTMgODUuODJMMTM0LjE3IDg0LjI0TDEzMi43OCA4Mi4zNEwxMzEuNjkgODAuMjVMMTMwLjc3IDc4LjA4TDEyOS44NyA3NS44OUwxMjguOTQgNzMuNzJMMTI4LjAwIDcxLjU2TDEyNy4wMyA2OS40MEwxMjYuMDUgNjcuMjZMMTI1LjA1IDY1LjEyTDEyNC4wMyA2Mi45OUwxMjIuOTMgNjAuOTBMMTIxLjg3IDU4Ljc5TDEyMS4wMyA1Ni41OUwxMjAuNzIgNTQuMjZMMTIxLjEwIDUxLjkzTDEyMi4xNSA0OS44M0wxMjMuNzUgNDguMTBMMTI1Ljc2IDQ2Ljg5TDEyOC4wMSA0Ni4xOVoiIHRyYW5zZm9ybT0idHJhbnNsYXRlKDEzNi4yMSA2OC41NCkgc2NhbGUoMC45OCAwLjk5KSB0cmFuc2xhdGUoLTEzNi42MiAtNjYuNzMpIj48L3BhdGg+PHBhdGggZmlsbD0iIzFBMUExQSIgc3Ryb2tlPSJub25lIiBzdHJva2Utd2lkdGg9IjEuNiIgZD0iTTE3Ni42MSAzNy4wOEwxNzguNzIgMzcuNTlMMTgwLjcwIDM4LjQ4TDE4Mi41MiAzOS42NUwxODQuMjAgNDEuMDNMMTg1LjcxIDQyLjU5TDE4Ny4wMyA0NC4zMUwxODguMjAgNDYuMTRMMTg5LjI2IDQ4LjAzTDE5MC4yNyA0OS45NkwxOTEuMjYgNTEuODlMMTkyLjIzIDUzLjg0TDE5My4xNiA1NS44MEwxOTQuMDUgNTcuNzhMMTk0LjkyIDU5Ljc3TDE5NS43NCA2MS43OEwxOTYuNTMgNjMuODBMMTk3LjI3IDY1Ljg0TDE5Ny45NyA2Ny45MEwxOTguNDcgNzAuMDFMMTk4LjYzIDcyLjE4TDE5OC40MCA3NC4zM0wxOTcuNTggNzYuMzNMMTk1Ljk1IDc3LjcyTDE5My44MyA3OC4wOEwxOTEuNzEgNzcuNjVMMTg5Ljc2IDc2LjY5TDE4OC4wMyA3NS4zOEwxODYuNTMgNzMuODJMMTg1LjI4IDcyLjA1TDE4NC4yNSA3MC4xM0wxODMuNDAgNjguMTRMMTgyLjYzIDY2LjExTDE4MS44NyA2NC4wN0wxODEuMDcgNjIuMDVMMTgwLjI1IDYwLjA0TDE3OS4zOSA1OC4wNUwxNzguNDkgNTYuMDdMMTc3LjU3IDU0LjEwTDE3Ni42MSA1Mi4xNUwxNzUuNjIgNTAuMjJMMTc0LjU5IDQ4LjMxTDE3My41MyA0Ni40MUwxNzIuNTQgNDQuNDhMMTcxLjg2IDQyLjQyTDE3MS43NiA0MC4yNkwxNzIuNjIgMzguMzBMMTc0LjQ1IDM3LjE5WiIgdHJhbnNmb3JtPSJ0cmFuc2xhdGUoMTgwLjEgNTkuNzYpIHNjYWxlKDAuNzUgMC45OCkgdHJhbnNsYXRlKC0xODUuNjkgLTU3LjIxKSI+PC9wYXRoPjwvZz48ZyBwb2ludGVyLWV2ZW50cz0ibm9uZSI+PC9nPjwvc3ZnPg==';
  function settle() {
    clearTimeout(wakeTimer); wakeTimer = 0;
    if (wakeAnimation) { wakeAnimation.cancel(); wakeAnimation = null; }
    if (engine) sync();
  }
  function wake() {
    if (!engine || !selected || reduced.matches || desired === '32') return;
    clearTimeout(wakeTimer);
    if (wakeAnimation) wakeAnimation.cancel();
    wakeAnimation = host.animate([
      {transform: 'translateX(0) rotate(0deg)'},
      {transform: 'translateX(-2px) rotate(-3deg)'},
      {transform: 'translateX(2px) rotate(3deg)'},
      {transform: 'translateX(-1px) rotate(-2deg)'},
      {transform: 'translateX(1px) rotate(1deg)'},
      {transform: 'translateX(0) rotate(0deg)'}
    ], {duration: 480, easing: 'ease-in-out'});
    wakeTimer = setTimeout(settle, 500);
    sync();
  }
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const observer = new IntersectionObserver(entries => {
    for (const entry of entries) if (entry.target === host) visible = entry.isIntersecting;
    sync();
  });
  function sync() {
    if (!engine) return;
    const canPlay = selected && visible && !document.hidden && !reduced.matches;
    if (!canPlay && wakeTimer) {
      clearTimeout(wakeTimer); wakeTimer = 0;
      if (wakeAnimation) { wakeAnimation.cancel(); wakeAnimation = null; }
    }
    const resting = desired === 'mobile-idle';
    host.dataset.resting = String(resting);
    engine.setActive(canPlay && !resting);
  }
  function destroy() {
    clearTimeout(wakeTimer); wakeTimer = 0;
    if (wakeAnimation) { wakeAnimation.cancel(); wakeAnimation = null; }
    observer.disconnect();
    if (engine) engine.destroy();
    engine = host = null;
  }
  function update(element, active, emotion) {
    if (!element) return;
    if (host !== element) {
      destroy(); host = element; visible = true;
      engine = EmotionBall.create(host, {emotion: emotion === 'mobile-idle' ? '02' : emotion, autostart: false, lite: false, idle: false});
      const image = document.createElement('img');
      image.className = 'sprite-original'; image.alt = ''; image.src = originalImage;
      host.appendChild(image);
      observer.observe(host);
    }
    selected = active;
    const changed = desired !== emotion;
    desired = emotion;
    if (changed && wakeTimer) settle();
    const targetEmotion = emotion === 'mobile-idle' ? '02' : emotion;
    if (!wakeTimer && engine.emotionId !== targetEmotion) engine.setEmotion(targetEmotion);
    if (changed && (!active || reduced.matches)) engine.renderStatic();
    sync();
  }
  document.addEventListener('visibilitychange', sync);
  reduced.addEventListener('change', () => { if (engine && reduced.matches) engine.renderStatic(); sync(); });
  window.pocketdeskOrb = { update, destroy, wake };
})();
