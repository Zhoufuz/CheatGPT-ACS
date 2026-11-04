<h1 align="center">CheatGPT.cc</h1>

<p align="center"><strong>ACS武器系统通用脚本</strong></p>

<p align="center">
  <a href="src/main.lua"><img src="https://img.shields.io/badge/Release-1.2.2-94a3b8?style=flat-square&amp;labelColor=161b22" alt="Release 1.2.2"></a>
  <a href="https://www.lua.org/manual/5.1/"><img src="https://img.shields.io/badge/LuaU-818cf8?style=flat-square&amp;logo=lua&amp;logoColor=white&amp;labelColor=161b22" alt="Written in LuaU"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-34d399?style=flat-square&amp;labelColor=161b22" alt="License MIT"></a>
</p>

<p align="center">
  <a href="README-en.md">English</a> /
中文
</p>

---

<p align="center">
  <a href="#quick-start">快速开始</a> ·
  <a href="#usage">使用指南</a> ·
  <a href="#config">配置文件</a> ·
  <a href="#executor-compat">执行器兼容</a> ·
  <a href="#faq">常见问题</a> 
</p>

<a id="features"></a>

## 功能

| 模块 | 功能 | 说明 |
| --- | --- | --- |
| **Legit — Aim Assist** | 自动瞄准 | `Lock` / `Adaptive` 两种模式，可选瞄准部位，FOV、平滑速度、距离、队伍/墙体/开镜过滤，可绘制 FOV 圈 |
| **Legit — Combat** | 扳机 | 准星穿过敌人时自动开火，支持反应延迟、距离、队伍与开镜限制 |
| **Rage — RageBot** | RageBot | 直接构造 ACS 伤害请求，支持多目标、目标优先级、命中部位、多线程、连发、HitLog 与命中音效 |
| **Visual** | 视觉反馈 | Hit Marker、命中特效、击杀特效（Valorant / Battlefield 1）、弹着点标记、散布 FOV、Arms / Character / Tool Chams、Bullet Trace |
| **LocalPlayer** | 本地武器与移动 | Fly、Speed、Noclip、SpinBot、3rd Cam，以及 No Recoil / No Spread / Steady Aim / Infinite Ammo / Rapid Fire 等 ACS 模组修改 |
| **PlayersList** | 玩家管理 | 实时玩家列表、Friend / Enemy / None 角色标记、右键复制昵称/用户名/ID、进退场通知 |
| **Setting** | 界面设置 | 可拖动 Watermark、自定义内容、连接/离开通知、GUI 快捷键、通知开关、Clear Config |
| **Debug（隐藏）** | 诊断 | 执行器信息、UI 缩放、Steady Aim 状态、图片/下载队列、累计击杀与分数、缺失 API、最近错误日志 |

> 调试标签页默认隐藏：连续点击标题旁的 **`Release-v1.2.2`** 标签 **7 次**即可解锁。

<a id="quick-start"></a>

## 快速开始

在你的执行器中运行运行
```Lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Zhoufuz/CheatGPT-ACS/refs/heads/master/src/main.lua", true))()
```

### 环境要求

| 项目 | 要求 |
| --- | --- |
| 游戏 | 运行 **ACS（Advanced Combat System）** 武器框架的 Roblox 游戏 |
| 执行器 | 必须支持 `getsenv`；建议同时支持 `debug.getupvalues`、`hookfunction`、`newcclosure`（详见 [执行器兼容](#executor-compat)） |
| 网络 | 首次运行需要联网下载 UI 资源（图标、音效、字体、击杀特效） |
| 文件权限 | 执行器需支持 `writefile` / `readfile` 以保存配置；支持 `getcustomasset`（或 `getsynasset`）以加载资源 |

### 使用步骤

1. **进入游戏并等待加载完成**：确保角色已生成、手上已装备 ACS 武器（如步枪），让 `ACS_Client` 与武器设置先完成初始化。
2. **执行脚本**：将 [`src/main.lua`](src/main.lua) 的内容粘贴到执行器（或通过执行器加载该文件）并执行。
3. **等待初始化**：脚本最多等待 **12 秒**寻找可读取的 ACS 环境，随后创建界面。首次运行还会在后台下载资源，可能额外耗时数秒。
4. **打开菜单**：初始化完成后窗口会自动显示，默认停留在 **Rage** 标签页；之后可用 **RightShift**（默认 GUI Key）显示/隐藏窗口。
5. **按需开启功能**：部分开关依赖执行器 API，缺失时会置灰并提示缺少的函数，详见 [执行器兼容](#executor-compat)。

> 如果执行后没有出现窗口，请先按 F9 查看控制台，并确认当前游戏、角色与 ACS 武器均已加载；详见 [常见问题](#faq)。

<a id="usage"></a>

## 使用指南

### 窗口操作

  - 标题栏可**拖动**移动窗口；窗口大小按分辨率自动缩放（没有手动缩放/关闭按钮）。
  - 标签页支持横向滚动，切换时页面左右滑动、下划线动画跟随。
  - 移动端（仅触屏）会显示一个可拖动的悬浮圆钮，用来打开/关闭菜单。
  - 界面使用固定深色主题，没有主题切换功能。

### 标签页与功能

#### Legit（合法）

  - `Aim Assist`：总开关，支持绑定快捷键。
  - `Mode`：`Lock`（直接锁定）/ `Adaptive`（带反应延迟、抖动与过冲的拟人化平滑）。
  - `AimPart`：`Head` / `Torso` / `Left Arm` / `Right Arm` / `Left Leg` / `Right Leg`。
  - `Aim speed`：1–30（默认 10）；`Max Distance`：0–10000（默认 1500）。
  - `Only Enemy` / `Team Check` / `Wall Check` / `Only Scope`：目标过滤。
  - `Draw Fov` + `Fov size`（0–200）+ `Fov Color`：绘制瞄准范围圈。
  - `Trigger`：准星经过目标时自动开火（**需要执行器支持 `getsenv`**）。
  - `Reaction Time (ms)`：0–1000（默认 100）；`Max Distance`：0–10000；另有 `Team Check` / `Only Enemy` / `Only Scope`。

#### Rage（暴力）

  - `RageBot`：静默瞄准并直接发送伤害请求（**需要 `getsenv` + `debug.getupvalues`**）。
  - `Only Enemy` / `Team Check`：目标过滤；`WallBang`：允许穿过墙体命中。
  - `Multi Target`：1–8（默认 3）；`Thread`：1–9（默认 1）。
  - `Target Priority`：`Distance` / `Centre`；`Hit Part`：头、躯干、四肢。
  - `HitLog`：屏幕命中记录，可调 `HitLog Size`（8–24，默认 16）与 `Duration Time (s)`（0.5–10，默认 2.2）。
  - `Hitsound`：12 种命中音效，默认 `Skeet`；`Hitsounds` 开关与 `Volume`（0–5，默认 0.8）。

#### Visual（视觉）

  - `Hit Marker`：命中标记，位置可选 `Centre` / `Impact Point`。
  - `Hit effect`：命中粒子特效，可调颜色与透明度。
  - `Kill effect`：击杀横幅特效。
  - `Kill effect style`：`Valorant` / `Battlefield 1`。
  - `Collection Style`（仅 Valorant）：`2021 Vandal` / `Recon` / `Rogue` / `Singularity`
  - `Kill Sounds Volume`：0–5（默认 2）。
  - `Show Impact`：弹着点标记，可调颜色、透明度、`Impact Material`（`Neon` / `ForceField` / `Glass` / `SmoothPlastic`）与大小。
  - `Spread FOV`：显示武器散布范围圈，可调颜色与透明度。
  - `Arms Chams` / `Character Chams` / `Tool Chams`：ForceField 材质透视高亮，可单独设色。
  - `Bullet Trace`：弹道拖尾，可分别设置自己/他人的颜色、透明度、显示对象、`Trace Lifetime`、`Trace Width` 与 `Trace Style`（`Basic` / `Styled`）。

#### LocalPlayer（本地效果）

  - `Fly` + `Fly Speed`（1–100，默认 1）：相机朝向飞行。
  - `Speed` + `Speed Value`（0–80）：修改移动速度。
  - `Noclip`：关闭角色碰撞。
  - ACS 武器增强（**均需要执行器支持相应调试/挂钩 API**）：
  - `No Suppression`：移除压制/耳鸣等负面效果。
  - `No Malfunction`：武器不会卡壳。
  - `Steady Aim`：移除开镜/移动时的视角摇晃
  - `No Recoil`：移除后坐力。
  - `No Spread`：移除散布。
  - `Accelerate Muzzle Velocity`：子弹加速
  - `Rapid Fire`：无射击间隔
  - `Infinite Ammo`：无限子弹
  - `Instant Aim`、`Instant Equip`：开镜/切枪动画瞬时完成。
  - `3rd Cam`：开启第3人称
  - `SpinBot` + `Spin Speed`人物旋转

#### PlayersList（玩家列表）

- 实时显示服务器玩家：头像、`显示名 (@用户名)`、角色按钮。
- 角色分为 **Friend**（绿）/ **Enemy**（红）/ **None**（灰），自己显示为 **Local**；角色会影响 Aim Assist、Trigger、RageBot 的 `Only Enemy` / `Team Check` 过滤。
- 右键玩家行（触屏长按 0.5 秒）可打开上下文菜单：`Copy display name` / `Copy username` / `Copy user ID`。
- Friend / Enemy 名单会自动保存到 `whitelist.json` / `enemylist.json`。

#### Setting（设置）

- `Watermark`：左上角水印，可多选显示 `FPS`、`PING`、`PLAYERS`、`USERNAME`、`TIME`、`CUSTOM`、`Kills`、`Score`、`Runtime`（默认 FPS + PING），`Custom` 可填写自定义文字。
- `Enemy leave notify` / `Friend leave notify` / `Enemy join notify` / `Friend join notify`：四个独立的进退场通知开关（默认关闭）。
- `GUI Key`：菜单显示/隐藏快捷键（默认 `RightShift`）。
- `Notifications`：脚本通知开关（关闭后回退到 Roblox 原生通知）。
- `Clear Config`：清空已保存的配置并重置所有控件（保留玩家列表与缓存），带二次确认。

#### Debug（隐藏）

> 连续点击版本标签 7 次解锁

包含：

- 执行器名称与版本、视口尺寸与 UI 缩放、Steady Aim 状态与 hook/pin 计数；
- 图片就绪/等待/忙碌数量、资源下载队列长度；
- 累计 `Kills` / `Score`、战绩存储路径 `CheatGPT/ACS/misc.json`、`Missing APIs`（缺失的执行器 API）；
- 最近 8 条错误记录
- 按钮：`Refresh diagnostics`、`Retry unloaded images`、`Copy diagnostics`、`Test notification / bug icon`、`Clear error log`。

<a id="config"></a>

## 配置文件

脚本会在执行器工作目录下创建 `CheatGPT/ACS/` 目录：

| 路径 | 内容 |
| --- | --- |
| `CheatGPT/ACS/Config.json` | 配置文件|
| `CheatGPT/ACS/whitelist.json` | Friend 名单 |
| `CheatGPT/ACS/enemylist.json` | Enemy 名单 |
| `CheatGPT/ACS/misc.json` | 累计击杀数和分数 |
| `CheatGPT/ACS/ClientId.json` | 本地表示，仅存本地 |
| `CheatGPT/ACS/Cache/` | 图标、音效、击杀特效帧、字体等缓存文件 |

- **自动保存**：变更后 **4 秒** 写入
- **清除配置**：`Clear Config` 删除 `Config.json`
- 如果执行器不支持 `writefile` / `readfile`，配置不会保存

<a id="executor-compat"></a>

##  执行器兼容性

脚本在启动时检测执行器能力，并据此启用/禁用功能。

### 必需与可选 API

| API | 作用 | 缺失影响 |
| --- | --- | --- |
| `getsenv` | 读取 ACS 环境 | **必要**：缺失脚本无法运行 |
| `debug.getupvalues` / `debug.getupvalue` / `debug.setupvalue` | 读写 ACS 武器模组 | 大部分 ACS 增强开关禁用 |
| `hookfunction` / `newcclosure` | 挂钩 ACS 函数 | `Rapid Fire`、`Instant Equip`、`Steady Aim` 等禁用 |
| `getconnections` / `getgc` / `getfenv` / `debug.getconstants` | 定位渲染连接 | `Steady Aim` 禁用 |
| `writefile` / `readfile` | 保存配置、写入资源缓存 | 配置不保存；资源无法缓存 |
| `getcustomasset` / `getsynasset` | 注册本地资源 URI | 图标/音效/击杀特效/字体不可用 |
| `request` / `http_request` / `syn.request` / `http.request` | 下载资源 | 回退到 `game:HttpGet` |
| `setclipboard` / `getclipboard` | 复制诊断、玩家名、颜色 | 相关按钮禁用 |
| `crypt.generatebytes` | 生成 ClientId | 仅影响 `ClientId.json`，不影响主功能 |
| `identifyexecutor` | 显示执行器信息 | Debug 中显示 `Unknown` |
| `gethui` | 存放运行锁 sentinel（缺失时回退 `CoreGui`） | 功能不受影响 |
| `syn.protect_gui` | 保护 UI（可选） | 功能不受影响 |

### API预览

| 功能 | 需要的 API |
| --- | --- |
| `Trigger` | `getsenv` |
| `RageBot`、`No Malfunction`、`No Recoil`、`No Spread`、`Accelerate Muzzle Velocity` | `getsenv` + `debug.getupvalues` |
| `Rapid Fire` | `getsenv`、`hookfunction`、`newcclosure`、`getcallingscript`、`debug.getupvalues`、`debug.setupvalue` |
| `Infinite Ammo` | `getsenv`、`debug.getupvalues`、`debug.setupvalue` |
| `Instant Aim` | `getsenv`、`debug.getupvalues`、`debug.getupvalue`、`debug.setupvalue` |
| `Instant Equip` | `getsenv`、`debug.getupvalues`、`debug.setupvalue`、`hookfunction`、`newcclosure` |
| `Steady Aim` | `getsenv`、`getconnections` 或 `getgc`、`getfenv`、`debug.getconstants`、`debug.getupvalues`、`debug.getupvalue`、`debug.setupvalue`、`hookfunction`、`newcclosure` |

- 缺少依赖的开关会**强制关闭并变灰**，点击时提示 `Your executor doesn't support '<API>' function`

<a id="faq"></a>

##  FAQ

<details>
<summary><b>执行脚本后没有任何窗口？</b></summary>

1. 确认游戏使用 ACS 框架，且角色已生成、已装备 ACS 武器；
2. 确认执行器支持 `getsenv`；
3. 按 F9 查看控制台，或查看脚本通知/错误提示；
4. 尝试重进。
</details>

<details>
<summary><b>提示“12 秒内未找到可读取的 ACS 环境”？</b></summary>

脚本在 12 秒内没有找到角色下的 `ACS_Client` 环境。请等待角色与武器完全加载后重试，或重进；若仍失败，当前游戏可能不是ACS武器系统
</details>

<details>
<summary><b>提示“执行器缺少 getsenv，无法读取 ACS 环境”？</b></summary>

当前执行器不支持 `getsenv`，脚本无法读取 ACS 环境，必须更换支持该 API 的执行器。
</details>

<details>
<summary><b>某些开关是灰色的 / 点击提示不支持？</b></summary>

这些功能需要额外的执行器 API（如 `debug.getupvalues`、`hookfunction`、`newcclosure`）。请对照[执行器兼容性](#executor-compat)，或到 Debug 标签页查看 `Missing APIs`（Debug 需先连点版本号 7 次解锁）。换用 API 更完整、支持等级更高的执行器即可解锁。
</details>

<details>
<summary><b>命中音效、击杀特效或字体不显示？</b></summary>

这些资源需要联网下载，并要求执行器支持 `writefile` 与 `getcustomasset`（或 `getsynasset`）。请检查 Debug 中的下载队列与失败记录，点击 `Retry unloaded images` 重试；字体加载失败时会自动回退到默认字体，不影响功能。更换击杀特效需要重置人物才会应用
</details>

<details>
<summary><b>设置没有保存？</b></summary>

配置写入 `CheatGPT/ACS/Config.json`，执行器需要支持 `writefile` / `readfile` ；请确认执行器允许文件读写，并检查 `CheatGPT/ACS/` 目录是否存在。没有文件权限时配置不会保存
</details>

<details>
<summary><b>如何恢复默认设置？</b></summary>

打开 Setting → `Clear Config` → `Clear and Reset`。该操作会删除 `Config.json` 并重置所有控件，但保留 Friend/Enemy 名单与资源缓存。
</details>

<details>
<summary><b>可以重复执行脚本吗？</b></summary>

可以，但脚本带有运行锁：检测到已有实例时会尝试重新显示现有窗口，而不是启动第二份。如果窗口丢失或状态异常，请退出并重新进入服务器后再执行。
</details>


<a id="structure"></a>

##  项目结构

```text
CheatGPT-ACS/
├─ src/
│  └─ main.lua      # 主模块
├─ README.md        # 本文档
└─ LICENSE          # MIT License
```


<a id="license"></a>

## License

 [MIT License](LICENSE) , Copyright © 2026 CheatGPT.cc。

---

<p align="center">
  <sub>CheatGPT.cc · ACS Universal Script · Release v1.2.2</sub><br>
</p>

  
