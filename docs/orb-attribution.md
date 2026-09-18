# 工作台球球图标
> L2 归属: CLAUDE.md

手机接收者复用工作台 emotion-ball 的静态 SVG 渲染结果，内嵌在 Web/app.js；不加载动画引擎，不新增网络依赖。来源：工作台 web/public/emotion-ball 与 emotion-ball-embed.html，2026-09-18 提取。

该第三方素材不属于 PocketDesk 的 MIT 授权范围。原许可限制球形角色视觉形象为非商业用途，商业发布前须更换形象。以下保留原始许可与声明。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

## 原始声明

# NOTICE · 使用声明 / Usage Notice

> **适用范围**：本声明针对 `emotion-ball/` 目录球形角色（blob / wedge / gem）的**视觉形象**（身体造型、配色方案、彩带等特效视觉及其整体形象）。表情引擎源代码与表情配置数据不在本声明限制范围内，采用「非商业免费 + 可获取商业授权」双许可，详见根目录 `LICENSE` 与 `LICENSE-COMMERCIAL.md`。`mood-mates/` 目录中的角色（云宝 Nimbo、亮亮 Twinkle）为独立原创设计，亦不在本声明范围内，详见 `mood-mates/LICENSE` 与 `mood-mates/LICENSE-COMMERCIAL.md`。
>
> **Scope**: This notice covers the **visual designs** of the ball-shaped characters (blob / wedge / gem) in the `emotion-ball/` directory — body silhouettes, color schemes, ribbon and other FX visuals, and the overall character appearance. The expression engine source code and emotion configuration data are outside this notice and are dual-licensed (free for non-commercial use + commercial licensing available) — see `LICENSE` and `LICENSE-COMMERCIAL.md` in the repository root. The characters in the `mood-mates/` directory (Nimbo the cloud, Twinkle the star) are independently created original designs and also fall outside this notice — see `mood-mates/LICENSE` and `mood-mates/LICENSE-COMMERCIAL.md`.

## 【中文】

1. **视觉形象使用限制**：球形角色的视觉形象（身体造型、配色方案、彩带等特效视觉及其整体形象）仅供个人技术学习与研究，**禁止任何商业用途**；该部分不提供、也永不提供商业授权。

2. **代码与表情数据归属**：本仓库中的代码实现（状态机、弹簧插值动画、球面投影、配置注册中心等）与表情配置数据（眼环 / 眼形 / 嘴形参数、动画原语、关键帧序列）为独立编写与设计，非商业使用免费，商业用途可获取商业授权（见 `LICENSE` 与 `LICENSE-COMMERCIAL.md`）；商业使用时须搭配使用方自有或另行合法授权的角色形象。

3. **联系方式**：若认为本仓库的内容存在不妥，请通过邮箱 **1251579308@qq.com** 联系，我们将在收到通知后及时处理。

## [English]

1. **Visual-design restrictions**: The ball characters' visual designs (body silhouettes, color schemes, ribbon and other FX visuals, and the overall character appearance) are for personal technical study and research only. **Any commercial use is prohibited**, and no commercial license is or will ever be offered for them.

2. **Code & emotion data**: The code in this repository (state machine, spring interpolation, spherical projection, config registry, etc.) and the emotion configuration data (eye-ring / eye-shape / mouth-shape parameters, animation primitives, keyframe sequences) were independently written and designed. They are free for non-commercial use, and commercial licensing is available (see `LICENSE` and `LICENSE-COMMERCIAL.md`); commercial use must pair them with the user's own or otherwise lawfully licensed character designs.

3. **Contact**: If you consider any content of this repository inappropriate, please contact **1251579308@qq.com** and it will be handled promptly upon notice.

## 原始许可

Emotion Ball Community License
Emotion Ball 社区许可（非商业免费；引擎与表情数据可另行商业授权；球形角色视觉形象永不商用）

Copyright (c) 2026 sam70361 (仅就独立编写的源代码、表情配置数据与文档部分)

适用范围 / Scope: 本许可仅适用于仓库根目录及 emotion-ball/ 目录的内容
（球形角色项目及其站点与文档）。mood-mates/ 子目录为独立原创角色子项目，
受其自带的 mood-mates/LICENSE（社区许可）与 mood-mates/LICENSE-COMMERCIAL.md
（商业许可）约束，不适用本许可。
This license applies only to the contents at the repository root and in the
emotion-ball/ directory (the ball-character project, its site and docs). The
mood-mates/ subdirectory is an independent original-character sub-project
governed by its own mood-mates/LICENSE (community) and
mood-mates/LICENSE-COMMERCIAL.md (commercial); this license does not apply
to it.

【中文】

0. 内容划分：本项目包含两类授权不同的内容——

   (A) 表情引擎与表情数据：源代码（状态机、弹簧插值动画、球面投影、
       渲染与配置注册中心等）、表情配置数据（眼环 / 眼形 / 嘴形参数、
       动画原语与关键帧序列）以及配套文档，均为独立编写与设计；

   (B) 球形角色视觉形象：blob / wedge / gem 身体造型、配色方案、彩带等
       特效视觉，及其组合形成的整体角色形象。

1. 非商业使用（适用于 A 与 B）：允许免费查看、下载、运行、修改本项目，
   并在注明出处的前提下，在个人学习、研究与技术交流等非商业场景中分享
   本项目或其衍生作品。

2. 商业使用（仅限 A）：表情引擎与表情数据可通过商业授权用于商业用途，
   通用条款见仓库根目录 LICENSE-COMMERCIAL.md；商业授权请联系
   1251579308@qq.com。

3. 视觉形象永不商用（B）：球形角色视觉形象仅供个人技术学习与研究，
   禁止任何商业用途；该部分不提供、也永不提供商业授权。取得商业授权的
   被许可方亦不得将球形角色视觉形象用于商业用途，须搭配自有或另行合法
   授权的角色形象使用。详见仓库根目录 NOTICE.md。

4. 未经商业授权，禁止将本项目或其衍生作品用于任何商业用途，包括但不
   限于售卖、付费授权、集成到商业产品或服务、用于商业推广等。

5. 分发本项目或其衍生作品时，须完整保留本许可声明、版权信息与
   NOTICE.md。

6. 本项目按"现状"提供，不附带任何明示或默示的担保；因使用本项目产生
   的任何风险与责任由使用者自行承担。

[English]

0. CONTENT CLASSES: this project contains two differently licensed classes
   of content —

   (A) Expression engine & emotion data: the source code (state machine,
       spring interpolation, spherical projection, rendering, config
       registry, etc.), the emotion configuration data (eye-ring / eye-shape
       / mouth-shape parameters, animation primitives and keyframe
       sequences) and the accompanying documentation, all independently
       written and designed;

   (B) Ball-character visual designs: the blob / wedge / gem body
       silhouettes, color schemes, ribbon and other FX visuals, and the
       overall character appearance they form together.

1. NON-COMMERCIAL USE (applies to both A and B): viewing, downloading,
   running and modifying this project free of charge, and sharing this
   project or derivative works with proper attribution in non-commercial
   scenarios (personal learning, research and technical exchange) are
   permitted.

2. COMMERCIAL USE (A only): the expression engine and emotion data may be
   used commercially under a commercial license; see LICENSE-COMMERCIAL.md
   in the repository root for the general terms, and contact
   1251579308@qq.com for licensing.

3. VISUAL DESIGNS NEVER COMMERCIAL (B): the ball-character visual designs
   are provided solely for personal technical study and research; any
   commercial use is prohibited, and no commercial license is or will ever
   be offered for them. Even commercial licensees must not use the
   ball-character visual designs commercially and must pair the licensed
   materials with their own or otherwise lawfully licensed character
   designs. See NOTICE.md in the repository root.

4. Without a commercial license, any commercial use of this project or its
   derivative works is prohibited, including but not limited to selling,
   paid licensing, integration into commercial products or services, or use
   in commercial promotion.

5. This license notice, the copyright notice and NOTICE.md must be retained
   in all copies or substantial portions of the project.

6. The project is provided "AS IS", without warranty of any kind, express or
   implied. All risks and liabilities arising from its use are borne by the
   user.

2026-09-18 动效适配：保留原始球体路径、眼睛路径与配色，将 SVG 内联分层；由 PocketDesk CSS 控制转头、眨眼和点按正视，不引入原动画引擎。

转头适配已撤回：用户反馈眼形变形，现恢复完整原始 SVG 图像，只有整图轻动效，不单独变换眼睛。

原版引擎恢复：Web/orb-rings、orb-emotions、orb-ball、orb-engine.js 复制自工作台 emotion-ball/js；保留原始表情与效果，engine 仅限制绘制约 30fps。orb-mobile.js 是 PocketDesk 生命周期适配器；原版文件适用本页原始声明与许可，不适用 MIT。

电脑控制台静态形象（2026-09-18）：Web/console.html 复用原版引擎导出的左视 SVG，pool=[0]、eyes.both.lookX=-55、lookY=0、body.breathe=0；运行时不加载引擎、不运行动画。适用上方原始许可。

桌面原生面板同步使用 Web/orb.svg 的同一原版左视静态帧，取消球体待机/忙碌循环动画。
