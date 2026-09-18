/**
 * [INPUT]: 依赖 app.js 的目标/连接状态、compose.js 的草稿事务与 agent-panel.js 的任务反馈。
 * [OUTPUT]: 重选小精灵显式恢复桌面反馈；提供实时输入浮层与原版动态球球生命周期与开心/等待/工作状态与接收者渲染、显式应用选择、置顶应用栏进入小精灵与只读前台跟随；启动沿用电脑前台。
 * [POS]: 手机接收者路由层；显式应用选择才激活电脑，进入小精灵和被动前台跟随不操作桌面；未发送草稿阻止被动换目标。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/* ---------- 渲染 ---------- */

// 接收者顺序来自服务端（控制台可拖拽排序并持久保存，方案 §3）。
// 顺序里没有的项按原相对顺序追加；小精灵缺失时补到首位——这只在迁移时发生一次。
function orderedRecipients() {
  const byId = new Map(targets.map(item => [item.id, item]));
  const list = [];
  const seen = new Set();
  for (const id of recipientOrder) {
    if (id === SPRITE_ID) {
      if (!seen.has(SPRITE_ID)) { list.push({ id: SPRITE_ID, name: '小精灵' }); seen.add(SPRITE_ID); }
      continue;
    }
    const target = byId.get(id);
    if (target && !seen.has(id)) { list.push(target); seen.add(id); }
  }
  targets.forEach(item => { if (!seen.has(item.id)) { list.push(item); seen.add(item.id); } });
  if (!seen.has(SPRITE_ID)) list.unshift({ id: SPRITE_ID, name: '小精灵' });
  return list;
}

// 小精灵图标用本地 SVG：不用 emoji、外部字体或 CDN（方案 §2）。
function spriteButton() {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `target target-sprite${selected === SPRITE_ID ? ' selected' : ''}`;
  button.dataset.targetId = SPRITE_ID;
  button.setAttribute('role', 'radio');
  button.setAttribute('aria-checked', String(selected === SPRITE_ID));
  button.tabIndex = selected === SPRITE_ID ? 0 : -1;
  // 原版渲染器独占容器，不重绘眼形或裁取动画帧。
  button.innerHTML = '<span class="target-icon sprite-icon" aria-hidden="true"><span class="sprite-engine"></span></span><small>小精灵</small>';
  return button;
}

function renderTargets() {
  window.pocketdeskOrb.destroy();
  row.innerHTML = '';
  orderedRecipients().forEach(target => {
    if (target.id === SPRITE_ID) { row.append(spriteButton()); return; }
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `target${target.id === selected ? ' selected' : ''}`;
    button.dataset.targetId = target.id;
    button.setAttribute('role', 'radio');
    button.setAttribute('aria-checked', String(target.id === selected));
    // roving tabindex：整组只留一个 Tab 停靠点，就是当前选中项。
    button.tabIndex = target.id === selected ? 0 : -1;
    // 应用图标由服务端从系统取；img 加载失败才露出首字兜底（首字只给眼睛看，读屏念下方名称）。
    button.innerHTML = `<span class="target-icon"><img src="/api/icon?id=${encodeURIComponent(target.id)}" alt="" draggable="false"><span class="target-initial" aria-hidden="true"></span></span><small></small>`;
    const image = button.querySelector('img');
    // 首字默认隐藏：加载中不闪文字，确认拿不到图标时才由 CSS 放出来。
    const initial = button.querySelector('.target-initial');
    initial.textContent = target.name.slice(0, 1).toUpperCase();
    image.addEventListener('error', () => {
      image.classList.add('missing');
      initial.classList.add('visible');
    });
    button.querySelector('small').textContent = target.name;
    row.append(button);
  });
}

// 表情只消费任务与草稿事实；选中柔光由 selected 独立控制。
function syncSpriteExpression() {
  const transcript = document.getElementById('sprite-transcript');
  if (transcript) {
    transcript.textContent = typeof liveValue === 'function' && liveValue() || '';
    transcript.hidden = selected !== SPRITE_ID || !transcript.textContent;
  }
  const orb = row.querySelector('.target-sprite');
  if (!orb) return;
  const task = window.pocketdeskAgent?.current();
  const working = !!task && ['accepted', 'running', 'verifying'].includes(task.status);
  const hasText = typeof liveValue === 'function' && liveValue().trim().length > 0;
  const resultPanel = document.getElementById('agent-panel');
  if (resultPanel && !window.pocketdeskAgent?.isActive()) resultPanel.hidden = selected !== SPRITE_ID || !task || hasText;
  orb.dataset.expression = working ? 'working' : hasText || task?.status === 'needsInput' ? 'listening' : 'idle';
  window.pocketdeskOrb.update(orb.querySelector('.sprite-engine'), selected === SPRITE_ID, working ? '32' : hasText || task?.status === 'needsInput' ? '35' : 'mobile-idle');
}

function markSelected() {
  syncSpriteExpression();
  row.querySelectorAll('.target').forEach(element => {
    const isSelected = element.dataset.targetId === selected;
    element.classList.toggle('selected', isSelected);
    element.setAttribute('aria-checked', String(isSelected));
    element.tabIndex = isSelected ? 0 : -1;   // Tab 下次进来落在选中项上
  });
  // 快捷键组随选中态切换：选中目标有专属组就只显示那组，否则回退全局组。
  syncShortcutsForSelected();
  const front = targets.find(item => item.id === selected);
  const isSprite = selected === SPRITE_ID;
  // 展示层用这个类型问句判断任务卡是否应出现；不让 agent-panel 反向猜 Dock DOM。
  window.pocketdeskIsSpriteSelected = () => selected === SPRITE_ID;
  window.pocketdeskAgentPanel?.render();
  // 没有目标时按钮置灰并明说：点了也不会有去向。
  const hasTarget = Boolean(front) || selected === FRONTMOST_ID || isSprite;
  sendEl.disabled = !hasTarget;
  sendEl.classList.toggle('no-target', !hasTarget);
  // 识别到什么就写什么：Dock 目标用配置名；伪目标用心跳识别出的前台应用名（frontmostLabel）。
  const label = front ? front.name : (selected === FRONTMOST_ID ? (frontmostLabel || '当前前台') : (isSprite ? '小精灵' : null));
  sendEl.textContent = label ? `发送给 ${label}` : '请先选择应用';
  for (const id of ['compose-recipient', 'screen-recipient']) {
    const node = document.getElementById(id);
    if (node) node.textContent = label ? `发给 ${label}` : '请选择接收者';
  }
  // 首版小精灵只收文字：切过去就收起图片入口，电脑应用的附件留在应用草稿里（方案 §5）。
  const imageButton = document.querySelector('#image-btn');
  if (imageButton) imageButton.hidden = isSprite;
}

/* ---------- 选中与唤醒 ---------- */

// 选择代际：只有最新一次选择的定位才允许生效。快速点 A 再点 B 时，A 的迟到回执
// 既不能挪动光标（服务端按代际拒绝），也不能改动面板、提示或草稿同步。
let selectGeneration = 0;

async function activateTarget(targetId, locate = false) {
  lastActivateAt = Date.now();
  const generation = ++selectGeneration;
  const target = targets.find(item => item.id === targetId);
  message(`正在唤醒 ${target ? target.name : targetId}…`);
  try {
    const session = window.pocketdeskControlInfo?.().session || '';
    const response = await fetch('/api/activate', {
      method: 'POST',
      headers: { ...authHeaders(), 'X-PocketDesk-Session': session },
      // locate 只在手动选择应用时为 true；定位由服务端在控制租约下执行，前端不自己挪光标。
      body: JSON.stringify({ targetId, locate, generation }),
    });
    const result = await response.json();
    if (response.status === 401) throw new Error('未配对：请在电脑端控制台重新扫码。');
    if (response.status === 409) throw new Error(result.error || '控制权已变化，请先接管控制。');
    if (!response.ok) throw new Error(result.error || '无法唤醒应用。');
    // 迟到的回执：这次选择已经不是最新的了，就此止步，不改动任何界面状态或草稿。
    if (generation !== selectGeneration) return false;
    // 回执如实分级：旧版只要 200 就说"可开始输入"，焦点没落进去时用户只看到一次"没反应"，
    // 每次都误以为又坏了。locate=unchanged 也可能点了输入框（光标本就在窗口内），
    // 所以以 clickedInput / inputFocused 为准，不以移动结论为准。
    let tail = '';
    if (result.clickedInput) {
      if (result.inputFocused === 'yes') tail = '已点进输入框，可直接输入。';
      else if (result.inputFocused === 'no') tail = '没能把焦点放进输入框，请在电脑上点一下输入框再输入。';
      else tail = '已尝试点击输入框，未能确认聚焦；打字无效时请点一下电脑输入框。';
    }
    // 激活结果与鼠标结果分开：定位跳过不等于应用没唤醒，这里只用 note 说明"窗口在另一块屏"这类事实。
    message(`${target ? target.name : targetId} 已置于电脑前台。${tail}${result.note ? '（' + result.note + '）' : ''}`);
    // 按应用偏好切面板：触控板型应用直接展开触控板（收起键盘），输入型保持输入区。
    // 只在手动激活时切——前台自动跟随不切，避免被动抢走用户正打字的键盘。
    if (target?.openPanel === 'pad') enterPadMode(); else exitPadMode();
    return true;
  } catch (error) {
    // 失败也可能来自更早的一轮选择，同样不得覆盖最新一轮的提示。
    if (generation !== selectGeneration) return false;
    message(error.message, true);
    return false;
  }
}

async function selectTarget(button) {
  const targetId = button.dataset.targetId;
  if (targetId === SPRITE_ID) { selectSprite(); return; }
  // 切到普通应用：结束桌面反馈球的显示意图。代际用当前值——之后任何选择都会
  // ++selectGeneration（严格更大），服务端因此能拒绝迟到的 deselect 复活/杀掉新选择。
  window.pocketdeskSpriteDeselect?.(selectGeneration);
  // 接收者切换只改变去向，保留当前可见草稿（包含全屏输入）。
  const draft = liveValue();
  textEl.value = draft;
  kbProxy.value = draft;
  const rebuiltDraft = beginDraftForExplicitTarget(targetId);
  selected = targetId;
  markSelected();
  // 手动选择才请求鼠标就位：用户随后可直接用手机触控板操作目标窗口。
  const activated = await activateTarget(selected, true);
  // 切换目标或失败后重选当前目标，代表用户要以此刻输入位置开始新一轮；已有正文
  // 立即触发新绑定，纯图片发送时绑定。健康状态重复点击不重建，避免把全文再次追加。
  if (activated && rebuiltDraft && liveValue()) scheduleLive();
}

// 选中内置接收者：不唤醒应用、不绑定 AX 输入、不移动鼠标（方案 §3/§4）。
// 小精灵是手机端接收者，与 Mac 前台应用是两种状态，不共用一个变量表达。
function selectSprite() {
  ++selectGeneration;
  if (selected === SPRITE_ID) {
    // 已选中再点一次只回到输入并聚焦：不清草稿、不新建任务（方案 §4）。
    window.pocketdeskSpriteSelect?.(selectGeneration);
    window.pocketdeskFocusCompose?.();
    window.pocketdeskOrb.wake();
    return;
  }
  // 共用手机草稿；切到小精灵取消桌面队列，不清正文、不删除电脑已有内容。
  const draft = liveValue();
  textEl.value = draft;
  kbProxy.value = draft;
  beginDraftForExplicitTarget(SPRITE_ID);
  selected = SPRITE_ID;
  markSelected();
  // 上报桌面反馈球的出现（代际防迟到）；重选不清草稿、不新建任务（方案 §4）。
  window.pocketdeskSpriteSelect?.(selectGeneration);
  window.pocketdeskOrb.wake();
  exitPadMode();
  // 只聚焦，不走 showKeyboard：后者会 refreshInputContext + scheduleLive，
  // 等价于把还没发的 AI 指令同步到电脑（方案 §11 点名要绕开的桌面副作用）。
  window.pocketdeskFocusCompose?.();
}

// 接续只使用服务端提交回执中的目标；复用应用选择，不重复派单。
window.pocketdeskContinueInApp = async (targetId) => {
  if (!targets.some(target => target.id === targetId)) { message('应用已移除，请重新添加。', true); return; }
  const operation = selectTarget({ dataset: { targetId } });
  window.pocketdeskFocusCompose?.();
  await operation;
};

row.addEventListener('click', event => {
  const button = event.target.closest('.target');
  if (!button || button.parentElement !== row) return;
  selectTarget(button);
});

row.addEventListener('contextmenu', event => {
  if (event.target.closest('.target')) event.preventDefault();
});

// 键盘：方向键 / Home / End 与点击共用选择事务，避免只换标签却沿用旧输入绑定。
row.addEventListener('keydown', event => {
  const button = event.target.closest('.target');
  if (!button) return;
  const buttons = [...row.querySelectorAll('.target')];
  const at = buttons.indexOf(button);
  let to = -1;
  if (event.key === 'ArrowRight') to = Math.min(buttons.length - 1, at + 1);
  else if (event.key === 'ArrowLeft') to = Math.max(0, at - 1);
  else if (event.key === 'Home') to = 0;
  else if (event.key === 'End') to = buttons.length - 1;
  else return;
  event.preventDefault();
  const next = buttons[to];
  if (!next) return;
  if (next !== button) {
    selectTarget(next);
  }
  next.focus();
  next.scrollIntoView({ block: 'nearest', inline: 'nearest' });
});

/* ---------- 前台跟随与返回：只读观察，不激活桌面 ---------- */

function hasRecipientDraft() {
  return Boolean(liveValue() || pendingImages.length || liveComposing || submittingDraft);
}

function applyFrontmost(status) {
  const target = targets.find(item => item.id === status.frontmostId);
  const next = target ? target.id : status.frontmostName ? FRONTMOST_ID : null;
  const key = status.frontmostId || status.frontmostName || null;
  // 未配置应用共用伪目标 ID，换应用时仍要作废旧输入绑定。
  if (next !== selected || key !== lastSeenFront) {
    ++selectGeneration;
    beginDraftForExplicitTarget(next, true);
  }
  selected = next;
  frontmostLabel = target ? null : status.frontmostName || null;
  lastSeenFront = key;
  markSelected();
}

function followFrontmost(status) {
  if (selected === SPRITE_ID || hasRecipientDraft()) return;
  if (Date.now() <= manualUntil || Date.now() - lastActivateAt < 2500) return;
  const key = status.frontmostId || status.frontmostName || null;
  if (key === lastSeenFront) return;
  applyFrontmost(status);
}
