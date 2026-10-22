# cleanyourtv · 坚果 JmGO P2 投影仪精简实战

> 只禁用、不卸载，随时可恢复。给一台 2014 年前后的 Android 4.4 投影仪做减法：
> 释放内存 160MB+、清理 1.2GB 死空间、装回能用的直播源。

[![Device](https://img.shields.io/badge/Device-JmGO_P2-blue)]()
[![Android](https://img.shields.io/badge/Android-4.4.4%20(API%2019)-green)]()
[![Method](https://img.shields.io/badge/Method-pm%20disable--user-orange)]()
[![Reversible](https://img.shields.io/badge/100%25-可恢复-brightgreen)]()

## 效果总览

| 指标 | 精简前 | 精简后 |
|---|---|---|
| 系统空闲内存 | 14 MB | **175 MB** |
| 已禁用预装包 | 0 | **24** |
| 内置存储已用 | 1.4 GB | **175 MB** |
| 系统分区占用 | — | 0（全部是 disable，system 未动） |

## 背景

设备：坚果 P2（`JmGO_P2`），Android 4.4.4（SDK 19），MStar 6A628，820MB 内存。
固件 `JmGO_P2-userdebug 4.4.4 KTU84P 1.2.11 test-keys`，`ro.debuggable=1`，可用 `adb root`。

思路来自 [Gathin23/cleanyourtv](https://github.com/Gathin23/cleanyourtv)（Apple TV 风格桌面 + 预装清理），但它的工具要求 Android 8+，在这台 Android 4.4 上跑不了，所以按同样的“只禁用不卸载”原则，用 PowerShell + 官方 adb 重写了一套可回滚的小工具。

## 核心原则

1. **只禁用、不卸载**：`pm disable-user` 可用 `pm enable` 一键还原，风险最低；
2. **先清点再动手**：完整包清单 → DryRun → 应用 → 验证；
3. **必须 `adb root`**：普通 shell（uid 2000）执行 `pm disable-user` 会得到
   `SecurityException: Permission Denial: attempt to change component state`；
4. **留档可回滚**：每次禁用都写 undo 记录到 `records/`。

## 快速开始

```powershell
# 0. 首次连接：设置 → 关于本机 → 连点“软件版本号” → 开发者选项 → 开启 ADB
.\platform-tools\adb.exe connect 192.168.10.122:5555      # 遥控器点“允许”
.\platform-tools\adb.exe root                             # userdebug 固件需要

# 1. 探测 / 清点
powershell -ExecutionPolicy Bypass -File .\tools\jmgo.ps1 probe
powershell -ExecutionPolicy Bypass -File .\tools\jmgo.ps1 inventory   # 生成 reports/*.csv

# 2. 禁用（先 DryRun 再实删）
powershell -ExecutionPolicy Bypass -File .\tools\jmgo.ps1 disable -List .\lists\jmgo-p2.txt -DryRun
powershell -ExecutionPolicy Bypass -File .\tools\jmgo.ps1 disable -List .\lists\jmgo-p2.txt

# 3. 一键恢复
powershell -ExecutionPolicy Bypass -File .\tools\jmgo.ps1 restore
```

> 重启后 adbd 会回到 shell 权限，需要重新 `adb root`。

## 禁用了什么（24 项）

完整清单见 [`lists/jmgo-p2.txt`](lists/jmgo-p2.txt)，undo 记录见 [`records/`](records/)。主要类别：

| 类别 | 代表包 |
|---|---|
| 第三方预装/推送 | 悟空遥控 ×2、沙发管家、全民K歌、Chrome |
| 用不到的工具 | Documents To Go、MMCast 演示、工厂测试、Pico TTS |
| AOSP 冗余 | 打印服务、全局搜索、HTML 查看器、VPN、备份、日历、用户词典、WAP 推送 |
| 屏保/壁纸包 | BasicDreams、PhotoTable、MagicSmoke、NoiseField、PhaseBeam、MusicVis、HoloSpiral、WallpaperCropper |

**有意保留**：系统更新 OTA、乐播投屏、JMGO 内置视频/音乐/图片/浏览器、小白文件管理器 + 播放器，以及所有 `com.jmgo.* / com.mstar.* / com.softwinner.*` 系统底座。

## 实测避坑：Android 4.4 与新版 App 的兼容性

| 项目 | minSdk | 在这台 4.4 上？ |
|---|---|---|
| my-tv / mytv-android | 21+ | ✗ |
| FongMi/TV | 24 | ✗ |
| WebViewTvLive / easy_tv_live / takagen99/Box | 21+ | ✗ |
| **TVBox（q215613905 分支，j4Uq 构建 java32 包）** | **16** | **✓ 实测可装可用** |

坑：

- 4.4 的老 TLS 栈对 **ECDSA 证书**的网站（如 GitHub Pages）握手会直接失败（`sslv3 alert handshake failure`）；
- 本地网络到 `github.com:443` / GitHub Pages（`185.199.*.*:443`）经常直接超时；
- 所以 TVBox 的点播“接口”尽量选 **HTTP 直连** 托管在国内可达域名上的源，这类接口寿命很短，失效就换。

最终在这台机器上稳定可用的是**直播源** `https://live.zbds.top/tv/iptv4.m3u`（央视+主流卫视）；点播“接口”的失败过程与原因也一并记录在案（`docs/素材清单.md`），方便后来人对号入座。

## 存储审计：内置存储 1.4G → 175M

`/data` 分区本来就 80% 空闲；真正的垃圾藏在 `/mnt/sdcard`：

| 目标 | 大小 | 说明 |
|---|---|---|
| `/mnt/sdcard/yfnet/cache` | **1.0G** | YfNet CDN SDK 的缓存碎片，最后写入 2023-10-22，停用三年 |
| `Download/WKHelper` | 93M | 悟空遥控助手的安装包缓存 |
| `shafa` | 65M | 沙发管家缓存 |
| 商城/升级残件 + 出厂演示视频 | ≈100M | dbUpdate、DuoleStore、lovetv、tvmgrserver、Test.apk 等 |

详见 [`data/storage-audit.txt`](data/storage-audit.txt) 与 [`records/storage-cleanup-20261022-155637.json`](records/storage-cleanup-20261022-155637.json)。

## 文件结构

```
├─ README.md
├─ tools/jmgo.ps1          # 连接/探测/清点/禁用/恢复（PowerShell + adb）
├─ lists/jmgo-p2.txt       # 已应用的 24 项禁用清单（带注释与保留项）
├─ records/
│  ├─ jmgo-p2-20261022-123413.json      # 禁用记录（restore 的数据源）
│  └─ storage-cleanup-*.json            # 存储清理明细
├─ data/                   # 全程原始数据（包清单 CSV / meminfo / 审计报告 / 设备信息）
└─ docs/
   ├─ 素材清单.md           # 过程证据索引
   └─ images/              # 各阶段截图
```

## 免责声明

- 执行前请确认设备是**自己的设备**；精简可能影响依赖被禁用包的功能，`restore` 即可还原；
- `docs/images/` 下的截图来自真实设备，可能包含家庭 Wi-Fi SSID / IP，介意可自行打码后重新上传；
- 文中的直播源/点播接口均来自网络公开资源，随时可能失效，请自行判断可用性与合规性。
