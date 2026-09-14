/* Browser-supplied descriptions only; never infer an exact iPhone model or system device name. */
(function () {
  function describe(nav) {
    const ua = nav.userAgent || '';
    const ipad = /iPad/.test(ua) || (/Macintosh/.test(ua) && nav.maxTouchPoints > 1);
    const platform = ipad ? 'iPadOS' : /iPhone/.test(ua) ? 'iOS' : /Android/.test(ua) ? 'Android' : /Windows/.test(ua) ? 'Windows' : /Macintosh/.test(ua) ? 'macOS' : '其他设备';
    const category = ipad ? 'iPad' : platform === 'iOS' ? 'iPhone' : platform === 'Android' ? 'Android 手机' : platform;
    const browser = /Edg|EdgiOS|EdgA/.test(ua) ? 'Edge' : /SamsungBrowser/.test(ua) ? 'Samsung Internet' : /Firefox|FxiOS/.test(ua) ? 'Firefox' : /Chrome|CriOS/.test(ua) ? 'Chrome' : /Safari/.test(ua) ? 'Safari' : '浏览器';
    let model = '';
    const match = ua.match(/Android[^;)]*;\s*(?:[a-z]{2}[-_][A-Z]{2};\s*)?([^;)]+?)(?:\s+Build\/[^;)]*)?\)/);
    if (platform === 'Android' && match && !/^(K|wv|Mobile|Linux)$/i.test(match[1].trim())) model = match[1].trim();
    return { platform, category, browser, model };
  }
  if (typeof module !== 'undefined') { module.exports = { describe }; return; }
  const info = describe(navigator);
  const read = key => { try { return localStorage.getItem(key); } catch { return null; } };
  const write = (key, value) => { try { localStorage.setItem(key, value); } catch {} };
  let id = read('pd-device-id');
  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    const hex = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
    id = `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
    write('pd-device-id', id);
  }
  const detail = document.querySelector('#device-description');
  function render() {
    detail.textContent = [info.model || info.category, info.platform, info.browser].filter((v,i,a) => a.indexOf(v) === i).join(' · ');
  }
  window.pocketdeskDevice = () => ({ deviceId: id, name: info.model || info.category, model: info.model, platform: info.platform, browser: info.browser, userAgent: navigator.userAgent, session: window.pocketdeskControlInfo?.().session || '' });
  render();
  if (navigator.userAgentData?.getHighEntropyValues) {
    navigator.userAgentData.getHighEntropyValues(['model']).then(data => {
      if (info.platform === 'Android' && data.model && data.model !== 'K') info.model = data.model.slice(0, 80);
      render();
    }).catch(() => {});
  }
})();
