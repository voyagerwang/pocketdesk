/**
 * [INPUT]: 本机 /api/console 的文件与解锁接口，控制台的操作卡片。
 * [OUTPUT]: 网页内文件选择与分块拖放/待收状态、密码配置、显式钥匙串授权检查、开关、二维码核对与设备撤销；密码不持久化、不回填。
 * [POS]: 独立闭包管理常用电脑操作，避免与应用/模型设置的保存函数冲突。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';
  const $ = id => document.getElementById(id);
  let revision = 0, saving = false, activePair = null, credentialsJSON = '';
  async function request(path, body) {
    const response = await fetch('/api/console/' + path, body === undefined ? { cache: 'no-store' } : {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-PocketDesk-Console': '1' }, body: JSON.stringify(body)
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '操作失败，请重试。');
    return result;
  }
  function message(id, text, error = false) { $(id).textContent = text; $(id).classList.toggle('action-error', error); }
  function renderFiles(files) {
    const box = $('sendFileList'); box.replaceChildren();
    if (!files.length) { const p = document.createElement('p'); p.className = 'hint'; p.textContent = '还没有待收文件。选择电脑上的文件，手机就能看到。'; box.append(p); return; }
    for (const file of files) {
      const row = document.createElement('div'); row.className = 'console-file-row';
      const name = document.createElement('strong'); name.textContent = file.name;
      const state = document.createElement('span'); state.className = 'hint';
      state.textContent = `${(file.size / 1024 / 1024).toFixed(1)} MB · ${file.accepted ? '手机已确认接收' : '等待手机接收'}`;
      row.append(name, state); box.append(row);
    }
  }
  async function refreshFiles() {
    try { renderFiles((await request('files')).files || []); }
    catch (error) { message('sendFileStatus', error.message, true); }
  }
  $('sendFilePick').onclick = async () => {
    $('sendFilePick').disabled = true; message('sendFileStatus', '请选择文件，选好后会出现在手机文件页。');
    try { const result = await request('files/pick', {}); message('sendFileStatus', result.cancelled ? '已取消选择。' : result.message); await refreshFiles(); }
    catch (error) { message('sendFileStatus', error.message, true); }
    finally { $('sendFilePick').disabled = false; }
  };
  const drop = $('sendFileDrop');
  function asBase64(buffer) {
    const bytes = new Uint8Array(buffer); let binary = '';
    for (let start = 0; start < bytes.length; start += 0x8000) binary += String.fromCharCode(...bytes.subarray(start, start + 0x8000));
    return btoa(binary);
  }
  async function uploadDropped(fileList) {
    const files = Array.from(fileList || []);
    if (!files.length) return;
    if (files.some(file => !file.name)) { message('sendFileStatus', '只能拖入普通文件；文件夹请先压缩。', true); return; }
    drop.classList.add('is-uploading'); $('sendFilePick').disabled = true;
    let uploadId = null;
    try {
      const started = await request('files/upload/start', { files: files.map(file => ({ name: file.name, size: file.size })) });
      uploadId = started.uploadId; const chunkBytes = started.chunkBytes;
      const total = files.reduce((sum, file) => sum + file.size, 0); let sent = 0;
      for (let index = 0; index < files.length; index++) {
        for (let offset = 0; offset < files[index].size || (files[index].size === 0 && offset === 0); offset += chunkBytes) {
          const data = asBase64(await files[index].slice(offset, offset + chunkBytes).arrayBuffer());
          await request('files/upload/chunk', { uploadId, index, offset, data });
          sent += Math.min(chunkBytes, files[index].size - offset);
          message('sendFileStatus', total ? `正在上传 ${Math.min(100, Math.round(sent / total * 100))}%` : '正在准备空文件…');
          if (files[index].size === 0) break;
        }
      }
      const result = await request('files/upload/finish', { uploadId }); uploadId = null;
      message('sendFileStatus', result.message); await refreshFiles();
    } catch (error) {
      if (uploadId) request('files/upload/cancel', { uploadId }).catch(() => {});
      message('sendFileStatus', error.message, true);
    } finally { drop.classList.remove('is-uploading'); $('sendFilePick').disabled = false; }
  }
  ['dragenter', 'dragover'].forEach(type => drop.addEventListener(type, event => { event.preventDefault(); if (!drop.classList.contains('is-uploading')) drop.classList.add('is-dragging'); }));
  ['dragleave', 'drop'].forEach(type => drop.addEventListener(type, event => { event.preventDefault(); drop.classList.remove('is-dragging'); }));
  drop.addEventListener('drop', event => { if (!drop.classList.contains('is-uploading')) uploadDropped(event.dataTransfer.files); });
  $('sendFileRefresh').onclick = refreshFiles;
  function renderUnlock(data) {
    const attempt = data.lastAttempt;
    $('quLastAttempt').hidden = !attempt;
    if(attempt) $('quLastAttempt').textContent = '最近一次解锁 · ' + new Date(attempt.time*1000).toLocaleTimeString() + ' · ' + attempt.stage + '：' + (attempt.detail || attempt.outcome) + (attempt.error ? '（' + attempt.error + '）' : '');
    $('quickUnlockState').textContent = !data.configured ? '安全通道未就绪' : !data.hasPassword ? '待设置密码' : data.enabled ? '已开启' : '已关闭';
    $('quEnabled').checked = !!data.enabled;
    $('quEnabled').disabled = !data.hasPassword || !data.configured;
    $('quPasswordStatus').textContent = data.hasPassword ? '登录密码已保存在这台 Mac 的钥匙串中。' : '先保存电脑登录密码，再开启快捷解锁。';
    $('quDeletePassword').hidden = !data.hasPassword;
    $('quPasswordEditor').open = !data.hasPassword || $('quPasswordEditor').open;
    $('quPairStart').disabled = !data.enabled || !data.hasPassword || !data.configured;
    activePair = data.pair || null;
    $('quPairBox').hidden = !activePair;
    if (activePair) {
      if ($('quPairQR').getAttribute('src') !== activePair.qr) $('quPairQR').src = activePair.qr;
      $('quPairCode').textContent = activePair.code ? `核对码 ${activePair.code}` : '请在手机 App 扫描此码';
      $('quPairConfirm').hidden = !activePair.code;
      $('quPairHelp').textContent = activePair.code ? '确认手机与这里的核对码一致后，再点确认。' : '手机打开设备 → 快捷解锁 → 扫码。二维码 5 分钟内有效。';
    } else { $('quPairQR').removeAttribute('src'); $('quPairCode').textContent = ''; }
    const next = JSON.stringify(data.credentials || []);
    if (next !== credentialsJSON) {
      credentialsJSON = next; $('quDevices').replaceChildren();
      for (const device of data.credentials || []) {
        const row = document.createElement('div'); row.className = 'console-file-row';
        const label = document.createElement('span'); label.textContent = device.label;
        const revoke = document.createElement('button'); revoke.className = 'btn ghost'; revoke.textContent = '移除授权';
        revoke.onclick = () => { if (confirm(`移除“${device.label}”的解锁授权？移除后需重新配对。`)) change('revoke', { id: device.id }, '已移除设备授权。'); };
        row.append(label, revoke); $('quDevices').append(row);
      }
      if (!(data.credentials || []).length) $('quDevices').textContent = '尚未添加解锁设备。';
    }
  }
  async function change(action, body, success) {
    if (saving) return;
    saving = true; revision++; $('quControls').inert = true;
    message('quHint', action === 'keychain-authorize' ? '请在电脑上处理 PocketDesk 的系统钥匙串提示；完成后会检查后台读取权限。' : '正在处理…');
    try {
      const data = await request('unlock/' + action, body); renderUnlock(data); message('quHint', success);
      if (action === 'password') $('quPasswordEditor').open = false;
    } catch (error) { message('quHint', error.message, true); }
    finally { saving = false; revision++; $('quControls').inert = false; await refreshUnlock(); }
  }
  async function refreshUnlock() {
    const current = revision; if (saving) return;
    try { const data = await request('unlock'); if (current === revision && !saving) renderUnlock(data); }
    catch (error) { message('quHint', error.message, true); }
  }
  $('quPasswordForm').onsubmit = event => {
    event.preventDefault(); const password = $('quPassword').value; $('quPassword').value = '';
    if (!password) { message('quHint', '请输入电脑登录密码。', true); return; }
    change('password', { password }, '密码已保存，仅保留在这台电脑的钥匙串中。');
  };
  $('quEnabled').onchange = () => change('enabled', { enabled: $('quEnabled').checked }, $('quEnabled').checked ? '快捷解锁已开启。' : '快捷解锁已关闭。');
  $('quDeletePassword').onclick = () => { if (confirm('删除保存的登录密码并关闭快捷解锁？')) change('password/delete', {}, '密码已删除，快捷解锁已关闭。'); };
  $('quPairStart').onclick = () => change('pair', {}, '用手机 App 扫描下方二维码。');
  $('quKeychain').onclick = () => change('keychain-authorize', {}, '钥匙串后台读取检查通过，可以再用手机尝试解锁。');
  $('quPairCancel').onclick = () => change('cancel', {}, '已取消本次配对。');
  $('quPairConfirm').onclick = () => { if (activePair) change('confirm', { pairId: activePair.pairId }, '手机已获准解锁这台电脑。'); };
  $('quPairCopy').onclick = async () => {
    if (!activePair) return;
    try { await navigator.clipboard.writeText(activePair.link); message('quHint', '配对链接已复制，5 分钟内有效。'); }
    catch { message('quHint', '无法复制，请使用扫码配对。', true); }
  };
  refreshFiles(); refreshUnlock();
  setInterval(() => { if (!document.hidden) { refreshFiles(); refreshUnlock(); } }, 4000);
})();
