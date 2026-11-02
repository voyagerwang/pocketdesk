/**
 * [INPUT]: console-actions共享的本机请求封装、voice控制台卡片及只读运行状态。
 * [OUTPUT]: 唤醒/应答/音色配置及试听、重连；当前输入源与键盘自报能力、旧输入队列逐条显式处理，展示余量，轮询保留配置草稿。
 * [POS]: 小E本机语音设置；不在网页收音、不执行设备指令、不读取第三方配套应用凭据。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';
  const $ = id => document.getElementById(id);
  const request = window.pocketdeskConsoleRequest;
  const quality = value => value >= 3 ? '高级' : value === 2 ? '增强' : '紧凑';
  const rateLabel = value => value === 0 ? '正常' : (value > 0 ? '偏快 +' + value + '%' : '偏慢 ' + value + '%');
  let busy = false, dirty = false, loaded = false, toneKey = '', toneValues = [];

  // 音色下拉：神经音色（真人感）排前面，系统音色跟在后面兜底；选中项决定音色来源。
  function tones(state, saved) {
    const select = $('voiceTone');
    const voices = state.voices || [];
    const key = voices.map(voice => voice.id + '|' + voice.kind).join(',')
      + '#' + (state.ttsVoice || '') + '#' + (state.voice || '') + '#' + (state.ttsEngine || '');
    let rebuilt = false;
    if (select.dataset.ready !== '1' || toneKey !== key) {
      rebuilt = true;
      select.textContent = '';
      toneValues = [];
      const neural = voices.filter(voice => voice.kind === 'neural');
      const system = voices.filter(voice => voice.kind !== 'neural');
      const group = (label, items) => {
        if (!items.length) return;
        const box = document.createElement('optgroup');
        box.label = label;
        for (const voice of items) {
          const option = document.createElement('option');
          option.value = voice.kind + ':' + voice.id;
          option.textContent = voice.name + (voice.hint ? ' · ' + voice.hint : (voice.quality ? ' · ' + quality(voice.quality) : ''));
          box.appendChild(option);
          toneValues.push(option.value);
        }
        select.appendChild(box);
      };
      group('真人感 · 云端神经音色', neural);
      group('本机音色（断网兜底）', system);
      select.dataset.ready = '1';
      toneKey = key;
    }
    if (rebuilt || saved) {
      const current = state.ttsEngine === 'system'
        ? 'system:' + (state.voice || '')
        : 'neural:' + (state.ttsVoice || 'zh-CN-XiaoxiaoNeural');
      if (toneValues.indexOf(current) >= 0) select.value = current;
    }
    const chosen = (state.voices || []).find(voice => voice.kind + ':' + voice.id === select.value);
    $('voiceToneHint').textContent = !chosen
      ? '音色清单还在读取，稍等一下再试。'
      : (chosen.kind === 'neural'
        ? '当前音色：' + chosen.name + '（神经音色，' + (chosen.hint || '真人感') + '）'
        : '当前音色：' + chosen.name + '（本机音色，' + quality(chosen.quality) + '）。断网时自动用它顶上。');
  }

  // 键盘只读自报能力：扬声器播放到底支不支持，看设备自己怎么说，不由电脑侧猜。
  function device(state) {
    const caps = state.deviceCapabilities || {};
    const keys = Object.keys(caps);
    const speaker = caps.speaker_playback === true || caps.speaker_stream === true;
    const parts = [];
    if (state.deviceFirmware) parts.push('固件 ' + state.deviceFirmware);
    parts.push(keys.length ? (speaker ? '键盘自称支持扬声器' : '键盘未声明扬声器播放') : '键盘能力未上报');
    $('voiceDevice').textContent = parts.join(' · ');
  }

  function render(state, saved) {
    $('voiceStatus').textContent = state.status;
    $('voiceSource').textContent = state.source;
    $('voiceBinding').textContent = state.fallback
      ? '键盘未连接，暂用电脑麦克风'
      : (state.bound ? '已绑定这只键盘' : '启用后连接并绑定 EasyInput');
    device(state);
    if (!loaded || saved) {
      $('voiceWake').value = state.wakeWord;
      $('voiceAckPhrase').value = state.ackPhrase || '';
      $('voiceAck').checked = state.ackEnabled !== false;
      $('voiceEnabled').checked = state.enabled;
      $('voiceLocked').checked = state.allowLocked;
      $('voiceRate').value = typeof state.ttsRate === 'number' ? state.ttsRate : 4;
      loaded = true; dirty = false;
    }
    tones(state, saved);
    $('voiceAckPhrase').disabled = !$('voiceAck').checked;
    $('voiceRateLabel').textContent = rateLabel(Number($('voiceRate').value));
    $('voiceDraftBox').hidden = !state.draft;
    $('voiceDraft').value = state.draft || '';
    $('voiceParkedBox').hidden = !state.parked;
    $('voiceParked').value = state.parked || '';
    $('voiceParkedTitle').textContent = state.parkedCount > 1 ? '较早未发送的输入 · ' + state.parkedCount + ' 条' : '较早未发送的输入';
  }

  async function refresh() {
    if (busy || document.hidden) return;
    try { render(await request('voice')); }
    catch (error) { $('voiceStatus').textContent = error.message; }
  }

  $('voiceForm').addEventListener('input', () => { dirty = true; });
  $('voiceTone').addEventListener('change', () => { dirty = true; });
  $('voiceRate').addEventListener('input', () => { $('voiceRateLabel').textContent = rateLabel(Number($('voiceRate').value)); });

  async function act(action) {
    if (busy || !loaded) return;
    if (action === 'retry' && dirty) { $('voiceStatus').textContent = '请先保存配置。'; return; }
    busy = true;
    const buttons = $('voice-card').querySelectorAll('button');
    buttons.forEach(button => { button.disabled = true; });
    try {
      let body = { action };
      if (action === 'save') {
        const picked = ($('voiceTone').value || 'neural:zh-CN-XiaoxiaoNeural').split(':');
        const engine = picked[0], id = picked.slice(1).join(':');
        body = { action, enabled: $('voiceEnabled').checked, wakeWord: $('voiceWake').value.trim(), allowLocked: $('voiceLocked').checked,
          ackEnabled: $('voiceAck').checked, ackPhrase: $('voiceAckPhrase').value.trim(),
          ttsEngine: engine, ttsVoice: engine === 'neural' ? id : '', voice: engine === 'system' ? id : '',
          ttsRate: Number($('voiceRate').value) };
      }
      render(await request('voice', body), action === 'save');
    } catch (error) { $('voiceStatus').textContent = error.message; }
    finally { busy = false; buttons.forEach(button => { button.disabled = false; }); }
  }

  $('voiceForm').addEventListener('submit', event => { event.preventDefault(); act('save'); });
  $('voiceRetry').onclick = () => act('retry');
  $('voicePreview').onclick = () => act('preview');
  $('voiceSendDraft').onclick = () => act('sendDraft');
  $('voiceDiscardDraft').onclick = () => act('discardDraft');
  $('voiceSendParked').onclick = () => act('sendParked');
  $('voiceDiscardParked').onclick = () => act('discardParked');
  refresh(); setInterval(refresh, 1500);
})();
