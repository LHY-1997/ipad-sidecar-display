# iPad Sidecar Display

把 iPad 变成 Mac 的主显示器，自动连接，失败不弹窗。

适合固定工位：iPad 架在支架上当主屏，Mac mini 藏在桌下，每天开机自动连上，人走开自动不连。

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
- **菜单栏控制**：手动连接、断开、暂停守护
- **通用二进制**：Apple Silicon 和 Intel 都支持

## 安装

### 下载即用

从 Releases 下载 `iPad随航工具集-2.0.zip`，解压后**右键点击 `安装.command`** 选「打开」。

> 为什么是右键？脚本没有 Apple 开发者签名，macOS 第一次会拦。右键选「打开」会多出「打开」按钮，点它就行。

### 从源码构建

```bash
git clone <this-repo>
cd ipad-sidecar-display
./build.sh
```

产出 `iPad随航工具集-2.0.zip`，解压后同样双击 `安装.command`。

需要 macOS 13+ 和 Xcode 命令行工具（`xcode-select --install`）。

## 工作原理

### 连接与设主屏

私有框架 `SidecarCore.framework`：

```objc
SidecarDisplayManager *mgr = [SidecarDisplayManager new];
[mgr connectToDevice:device completion:^(NSError *e) { ... }];
```

设主屏用 CoreGraphics：主屏 = 原点在 (0,0)，把所有显示器整体平移，相对布局不变。

识别 iPad 靠 `CGDisplayModelNumber == 0x69506164`（ASCII 即 "iPad"）。

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
- 只测过 iPad Pro 12.9"（M1）和 macOS 26/27，其他组合未验证

## License

MIT
