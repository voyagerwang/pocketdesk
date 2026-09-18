/**
 * [INPUT]: Web/orb.svg（静态导出副本）与 Web/orb-rings.js（引擎几何数据层）。
 * [OUTPUT]: 校验 orb.svg 与球球引擎的几何契约一致：viewBox、头部中心、身体/眼形路径、原版渐变与来源声明。
 * [POS]: scripts 的素材校验工具；权威视觉定义 = Web/orb-*.js 引擎（工作台 emotion-ball 原版），
 *        orb.svg 是桌面原生面板与 console.html 共用的固定左视静态帧（pool 0 / lookX -55 / lookY 0）。
 *        若改了引擎几何：在浏览器按同参数导出新一帧覆盖 orb.svg，再跑本脚本校验。勿手改 orb.svg。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
const orbPath = path.join(root, 'Web', 'orb.svg');
const ringsPath = path.join(root, 'Web', 'orb-rings.js');

const orb = fs.readFileSync(orbPath, 'utf8');
const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(ringsPath, 'utf8'), sandbox, { filename: 'orb-rings.js' });
const rings = sandbox.window.EB_RINGS;

const failures = [];
const check = (ok, label) => { if (!ok) failures.push(label); };

check(orb.includes('viewBox="-15 -15 259 259"'), 'orb.svg viewBox 与引擎坐标系一致（-15 -15 259 259）');
check(rings && Math.abs(rings.HEAD_C - 114.2705) < 0.01, '引擎头部中心仍为 114.2705');
check(orb.includes('114.27'), 'orb.svg 身体路径以引擎头部中心为基准');
check((orb.match(/<path/g) || []).length === 3, 'orb.svg 保留 3 条原版路径（身体+眼形）');
check((orb.match(/<radialGradient/g) || []).length === 1, 'orb.svg 保留原版身体径向渐变');
check(orb.includes('[PROTOCOL]'), 'orb.svg 带素材头部声明（含授权指引）');
check(orb.includes('orb-attribution'), 'orb.svg 指向 docs/orb-attribution.md 授权文档');

if (failures.length) {
  console.error('orb.svg 契约校验失败：');
  for (const f of failures) console.error('  FAIL -', f);
  process.exit(1);
}
console.log('orb.svg 契约校验通过：viewBox / 头部中心 / 路径 / 渐变 / 来源声明');
