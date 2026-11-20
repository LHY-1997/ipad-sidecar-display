# iPad Sidecar Display

把 iPad 变成 Mac 的主显示器，自动连接，失败不弹窗，**自带虚拟屏，不依赖 BetterDisplay**。

**English:** Turn your iPad into a Mac's primary display — auto-connect when you're at the desk, silent cleanup of the `-1010` connection-failure popup, no manual Screen Mirroring clicks every morning, and a built-in 5K HiDPI virtual display so you can drop BetterDisplay entirely.

适合固定工位：iPad 架在支架上当主屏，Mac mini 藏在桌下，每天开机自动连上，人走开自动不连。

<p align="center">
  <img src="docs/panel.png" alt="iPad 随航控制面板：已连接 iPad Pro、已设 iPad 为主屏、虚拟屏开启、自动重连 10 秒、三条就绪日志、左下角版本号 v2.3" width="280">
</p>

<p align="center">
  <img src="docs/desktop.jpg" alt="iPad 上显示的完整 macOS 桌面：菜单栏、桌面小组件、Dock 全部铺开" width="620">
</p>

## 为什么做这个

macOS 的随航（Sidecar）功能本身很好用，但把它当**主显示器**用有几个麻烦：

1. 每次开机都要手动连一次
2. 连上后主屏还在 Mac 上，得去「系统设置 → 显示器」拖白条
3. **最烦的是连不上时疯狂弹窗**——iPad 没带在身边、深度休眠、或者关机，系统会弹一个「无法连接，发生了其他错误 (-1010)」，你点掉它，十秒后又弹一个

第三点尤其难受。实测过一个晚上：凌晨 1:51 到 8:03，连续失败 40 次，弹出 40 多个窗口。

这个工具解决的就是这三件事。

## 特性

- **自动连接**：开机自启，人回到电脑前自动连上，并设为主显示器
- **人不在就不连**：熄屏、锁屏、长时间无操作且无音频 → 不发起任何连接，从根上消除弹窗
- **弹窗兜底**：万一真失败，弹窗进程会在十秒内被清掉
- **菜单栏图标**：常驻菜单栏，点一下弹出面板（v2.1 起）。面板里手动连接、断开、暂停自动重连
- **自带 5K HiDPI 虚拟屏**：面板进程里直接建一块 2560×1440 逻辑 / 5120×2880 物理的假屏，无头 Mac mini 开机就有画面，不用装 BetterDisplay
- **虚拟屏开关**：面板里一键开关，默认开启；关掉会提示会丢随航
- **面板挂了自动拉起**：虚拟屏由面板进程持有，watchdog 每 10 秒看一眼，面板不在了就重新拉起并重建虚拟屏（实测 kill -9 后 7 秒恢复）
- **轻量**：不额外跑进程，整套只有 watchdog + 面板（BetterDisplay 光建假屏就占 88 MB）
- **通用二进制**：Apple Silicon 和 Intel 都支持

## 安装

### 下载即用

从 [Releases](https://github.com/nishtica/ipad-sidecar-display/releases/latest) 下载 `iPad-Sidecar-Display-2.3.zip`，解压后**右键点击 `安装.command`** 选「打开」。

> **别点绿色的 Code 按钮。** GitHub 首页的 `Code → Download ZIP`、Release 页面底部的 `Source code (zip)` 都是**源码包**，里面只有代码、没有编译好的程序，装不了——运行 `安装.command` 会报「缺少 payload」。认准 Releases 里 Assets 下的 `iPad-Sidecar-Display-2.3.zip`，解压出来应该有一个 `payload` 文件夹，里面有 `iPad随航.app`。

> 为什么是右键？脚本没有 Apple 开发者签名，macOS 第一次会拦。右键选「打开」会多出「打开」按钮，点它就行。

> zip 为什么用英文名：GitHub 上传 Release 附件时会剥掉文件名里的中文字符，`iPad随航工具集-2.0.zip` 会被存成 `iPad.-2.0.zip`。解压出来的东西都是中文的，只有外层文件名是英文。

### 从源码构建

```bash
git clone git@github.com:nishtica/ipad-sidecar-display.git
cd ipad-sidecar-display
./build.sh
```

产出 `iPad-Sidecar-Display-2.3.zip`，解压后同样双击 `安装.command`。

需要 macOS 13+ 和 Xcode 命令行工具（`xcode-select --install`）。

**改版本号只改一处**：`build.sh` 顶部的 `VERSION`。zip 文件名和 app 的 `Info.plist` 都引用它，`CFBundleVersion` 自动取去掉小数点的形式（`2.3` → `23`）。面板左下角显示的 `v2.3` 是运行时从 `Info.plist` 读的，不用另外维护。

## 工作原理

### 连接与设主屏

私有框架 `SidecarCore.framework`：

```objc
SidecarDisplayManager *mgr = [SidecarDisplayManager new];
[mgr connectToDevice:device completion:^(NSError *e) { ... }];
```

设主屏用 CoreGraphics：主屏 = 原点在 (0,0)，把所有显示器整体平移，相对布局不变。

识别 iPad 靠 `CGDisplayModelNumber == 0x69506164`（ASCII 即 "iPad"）。

### 主屏归属规则

三块屏的优先级是定死的：

| 屏幕 | 能不能当主屏 |
|---|---|
| 实体屏 | ✅ 默认 |
| iPad 随航屏 | ✅ 可以，但要手动点「设 iPad 为主屏」 |
| 虚拟屏 | ❌ 永远不行 |

虚拟屏是随航的落脚点，它一建出来默认落在原点，会把主屏抢走。所以两处都做了守护：

- **面板**：`AppState.refresh()` 每 2 秒检查一次，主屏在虚拟屏上就立刻让给实体屏（没有实体屏则给 iPad）
- **watchdog**：每 10 秒一轮，同样只在虚拟屏占着主屏时纠正

**watchdog 不再抢主屏。** v2.2 之前它每 10 秒无条件把 iPad 设为主屏，用户手动切回实体屏后会被抢回去。v2.3 改成：主屏是实体屏还是 iPad 完全由用户决定，watchdog 只在主屏落到虚拟屏上时才动手。

面板上的「主屏切回实体屏」按钮：主屏在虚拟屏上（异常）或 iPad 当主屏时出现，一键还给实体屏。

### 判断"人在不在"

这是整个工具的核心。最初只判断"屏幕是否熄灭"，但显示器设成永不关闭时这个判据永远为真，人走了照样每 10 秒发起一次连接。所以按可靠性从高到低叠加：

| 信号 | 判定 | API |
|---|---|---|
| 屏幕锁定 | 不在 | `CGSessionCopyCurrentDictionary()` 的 `CGSSessionScreenIsLocked` |
| 屏幕熄灭 | 不在 | `CGDisplayIsAsleep(CGMainDisplayID())` |
| 键鼠 5 分钟内有动 | 在 | `IOHIDSystem` 的 `HIDIdleTime` |
| 默认输出设备在出声 | 在 | `kAudioDevicePropertyDeviceIsRunningSomewhere` |
| 键鼠 30 分钟内动过 | 在 | 同上 `HIDIdleTime` |
| 全不满足 | 不在 | — |

"有音频输出"这一条是为了覆盖看视频、听音乐时鼠标几十分钟不动的情况。

**LaunchAgent 必须设 `LimitLoadToSessionType = Aqua`**，否则跑在后台会话里 `CGSessionCopyCurrentDictionary()` 返回 nil，锁屏永远检测不到。

### 弹窗拦截

弹窗的进程不是 `SidecarDisplayAgent`，而是 **`UserNotificationCenter`**。这点搞错很久——早期版本一直盯着 `SidecarDisplayAgent` 杀，从来没生效过。另有一个叫 `NotificationCenter` 的进程是桌面通知小组件，中文系统下 owner 名显示为「通知中心」，别搞混。

为什么只能杀不能点：点「好」按钮需要 AppleScript 或 Accessibility API。实测在 LaunchAgent 环境下两者都没权限——`AXIsProcessTrusted()` 返回 `false`，`AXUIElementCopyAttributeValue` 返回 `-25211`，只有从终端直接跑才有。所以走 `killall UserNotificationCenter`。

副作用是连带清掉当前所有通知横幅。但该进程按需启动，不会立刻自拉起，下次真有通知时 launchd 会重新拉它，系统不受影响。

识别方式是扫 `CGWindowListCopyWindowInfo`（只读窗口 owner，不需要屏幕录制权限），按尺寸过滤：Sidecar 弹窗实测 260×218，普通通知横幅更扁（高度通常不到 120），桌面层窗口是全屏尺寸，都不落在 200–500 × 120–400 区间里。

两个触发点：

- watchdog 每次运行开头扫一遍，清掉残留弹窗（比如手动点菜单栏连接失败留下的）
- 连接流程中每 0.2 秒扫一遍，一出现就杀

这是最后一道保险，正常路径下不该触发。

### 单实例锁

一次连接流程最长 35 秒（等回调 20 秒 + 等屏出现 15 秒），而 LaunchAgent 每 10 秒拉一个新进程。用 `flock` 锁住 `.lock` 文件，保证同时只有一个实例在跑。

### 虚拟屏（内置在菜单栏面板里）

无头 Mac mini 没有物理屏幕，开机后如果没有虚拟显示器，WindowServer 就没地方画桌面，随航也无从接管。

传统做法是装 BetterDisplay，但它 88 MB 内存只为了建一块假屏。现在 `iPad随航.app` 自己在进程里调 `CGVirtualDisplay` 私有 API 建这块屏——不额外跑进程，也不用装 BetterDisplay。

**开关在面板里，默认开启。** 关掉会弹警告：实测关掉虚拟屏后 iPad 随航会**当场断开**，系统退到一块 1920×1080 的兜底屏（1x，HiDPI 没了），十几秒后才自动重连回来。

开关状态记在 `~/Library/Application Support/ipad-watchdog/vdisplay.off`：文件存在 = 关闭，不存在 = 开启。所以想强制恢复默认，删掉这个文件重启即可。

四个私有类都在 **CoreGraphics** 里（不是 `CoreDisplay`）：

```
CGVirtualDisplay
CGVirtualDisplayDescriptor
CGVirtualDisplayMode
CGVirtualDisplaySettings
```

系统 framework 在 dyld shared cache 里，磁盘上的文件只是 stub，`nm`/`strings` 读不到。要看谁导入了这些类，用：

```bash
dyld_info -imports /Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay | grep VirtualDisplay
```

编译期不链接私有框架，运行时用 `NSClassFromString` + ObjC runtime 反射调用（跟 watchdog 处理 `SidecarCore` 是同一套路）。

**HiDPI 的正确姿势**（踩坑最深的一处）：

| 注册分辨率 | `setHiDPI` | 结果 |
|---|---|---|
| 5120×2880 | 1 | ❌ 逻辑=物理=5120，1x，UI 小到不可用，ioFlags `0x2000003` |
| **2560×1440** | **1** | ✅ 系统自动派生 HiDPI，逻辑 2560 / 物理 5120，ioFlags `0x2000007` |

也就是说，**注册逻辑分辨率，让系统去翻倍**，不是注册物理分辨率。

另外 `CGDisplayCopyAllDisplayModes` 默认列表**不含** HiDPI 变体，必须传：

```swift
let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
```

**必须由进程强引用持有**：`CGVirtualDisplay` 实例一销毁，虚拟屏立刻消失。菜单栏面板本来就是常驻进程，天然满足；`AppDelegate` 在 `applicationDidFinishLaunching` 里最早建屏，`AppState` 初始化时再兜一次（幂等）。

**面板挂了怎么办**：虚拟屏跟着面板走，面板一崩虚拟屏立刻消失，系统退到 1920×1080 兜底屏、随航断开。所以 watchdog 每次运行开头会先 `ensurePanelRunning()`——面板不在就用 `open -a --args --background` 拉起来，虚拟屏随之重建。实测 `kill -9` 面板后 7 秒内恢复，iPad 9 秒内重连。

区分「崩了」和「用户主动退出」靠 `panel.off`：面板的「退出」按钮在虚拟屏开着时会先弹警告（说明退出会连虚拟屏一起关掉、随航会断），确认后写 `panel.off` 再退出；下次面板启动时自动删掉这个标记。watchdog 看到 `panel.off` 就不干预。

**旧版遗留的两个坑**（2.0 之前虚拟屏是独立进程 `ipad-vdisplay`，如果以后改回独立进程会再遇到）：

1. `KeepAlive` 配 `SuccessfulExit=false` 时，进程收到 SIGTERM 后 `exit(0)` 会被判定为"正常完成"，launchd **不会重启**。信号处理器里要 `exit(1)`。
2. `lipo` 拼接通用二进制会**丢失签名**，launchd 报 `OS_REASON_CODESIGNING` 拒绝启动。必须 `codesign --force -s -` 重签。

实测参数（跟 BetterDisplay 建的屏逐字节一致）：

```
逻辑 2560×1440 / 物理 5120×2880 / 60Hz / ioFlags 0x2000007
```

分辨率写死在 `Sources/VirtualScreen.swift` 顶部的 `logicalW` / `logicalH`，改配置需重编译。

## 关于 -1010 和 -501

弹窗里见过两个错误码：`-1010`（A miscellaneous error occurred）和 `-501`，都表示连不上。

这个错误码让人困惑很久。一开始以为是 iPad 锁屏导致的，后来实测发现 **iPad 锁屏完全不影响连接**——Sidecar 会主动唤醒 iPad 并接管显示。

真正的失败原因是：

- iPad 不在蓝牙范围内
- iPad 深度休眠，无线响应超时
- iPad 关机或电量耗尽

**`SidecarDevice` 的 12 个 ivar 里没有任何可用性字段**（没有 `isAvailable`、`isConnected`、`connectionState`），所以"检查设备能不能连"这个动作本身必然等于"真的发起连接"，不存在免费的前置探测。这也是为什么只能靠"人在不在"来避免无谓尝试。

## 配置

配置文件都在 `~/Library/Application Support/ipad-watchdog/`：

| 文件 | 作用 |
|---|---|
| `pause` | 存在即暂停守护（菜单栏也能开关） |
| `target` | 指定优先连接的设备 UUID |
| `quiet` | 静默时段，内容如 `2 7` 表示 02:00-07:00 不连接 |
| `watchdog.log` | 日志，只在有事件时写 |
| `vdisplay.log` | 虚拟屏日志（建屏、切 HiDPI、开关） |
| `vdisplay.off` | 存在 = 虚拟屏被手动关闭，不存在 = 默认开启 |
| `panel.off` | 存在 = 用户主动退出了面板，watchdog 不再拉起；重新打开面板会自动清掉 |

自检：

```bash
~/Library/Application Support/ipad-watchdog/ipad-here
# 屏幕亮=是 已锁屏=否 有音频=否 空闲=13.5秒 → 人在=是
```

## 卸载

双击 `卸载.command`，或运行 `Packaging/uninstall.sh`。

## 已知限制

- 使用私有框架 `SidecarCore`，macOS 大版本更新可能失效。失效表现：日志持续记「SidecarCore 加载失败」
- app 是 adhoc 签名，首次打开会被 Gatekeeper 拦，需要右键打开
- 静音看视频超过 30 分钟会被判定为"人不在"，碰一下鼠标即恢复
- 虚拟屏用私有 API `CGVirtualDisplay`（来自 CoreGraphics），macOS 大版本更新可能失效。失效表现：`vdisplay.log` 记「私有类缺失」
- 虚拟屏分辨率写死在 `Sources/VirtualScreen.swift` 顶部（`logicalW` / `logicalH`），改配置需重编译
- 关掉虚拟屏后随航会断开一次，系统退到 1920×1080 兜底屏，等十几秒自动重连
- 只测过 iPad Pro 12.9"（M1）和 macOS 26/27，其他组合未验证

## License

MIT
