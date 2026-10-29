# 雷神加速器自动暂停

关闭雷神加速器客户端后，自动把剩余时长暂停，避免挂机空耗。

雷神官方只支持手动点"暂停"，退出客户端不会自动暂停。这个工具在本地后台监控客户端进程，进程真正退出（或电脑关机/注销）时调用官方接口暂停时长。

## 行为

| 操作 | 是否暂停 |
|---|---|
| 点 X 最小化到托盘（进程仍在） | 不暂停，继续加速 |
| 从托盘彻底退出客户端（进程结束） | 约 1 秒内暂停 |
| 关机 / 重启 / 注销 | 立即暂停（`WM_QUERYENDSESSION`） |
| 长按电源强制断电 / 蓝屏 | 无法保证 |

重新打开客户端后不会自动恢复加速，仍需手动点开启。

## 安装

需要 Windows PowerShell 5.1（Windows 10/11 自带）和一个**已设置密码**的雷神账号。

如果还没有 `LeigodAutoPause.exe`，先编译（只用到系统自带的 .NET Framework 编译器，不需要 .NET SDK）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

然后运行配置：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.ps1` 在发现 exe 不存在时也会自动调用 `build.ps1`。

按提示输入雷神手机号和密码。密码只在本地转换成 MD5 保存，不会上传。配置和日志位于：

```
%APPDATA%\LeigodAutoPause\
├── config.json     # 手机号 + 密码 MD5（请勿分享）
├── autopause.log   # 运行日志
└── instance.lock   # 单实例锁
```

`setup.ps1` 会注册一个名为 `LeigodAutoPause` 的计划任务，登录时自动启动后台监控。

> 如果账号平时只用手机验证码登录，需要先在客户端里通过"忘记密码"设置一个密码，否则无法无人值守地自动登录。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## 文件

- `LeigodAutoPause.cs` — 监控程序源码（原生 C#）
- `build.ps1` — 用系统自带的 .NET Framework 编译器生成 `LeigodAutoPause.exe`
- `setup.ps1` — 一次性配置：保存凭据、验证登录、注册计划任务
- `uninstall.ps1` — 移除计划任务、停止监控、删除本地配置

## 资源占用

编译后的 `LeigodAutoPause.exe` 常驻内存约 **35 MB**（工作集），CPU 接近 **0%**（每秒一次进程轮询）。只有暂停或关机时才会发一次 HTTP 请求。

## 原理

- 登录：`POST https://webapi.leigod.com/wap/login/bind`（手机号 + MD5 密码）
- 暂停：`POST https://webapi.leigod.com/api/user/pause`（`account_token`）
- 监控：轮询 `leigod.exe` 的 UI 进程 PID，PID 消失即触发暂停
- 关机：隐藏 WinForms 窗口监听 `WM_QUERYENDSESSION`，同步发出暂停请求
- 自愈：计划任务每 1 分钟检查一次，进程意外退出会自动重启（运行中则跳过）
- 暂停请求失败时会自动重试（最多 3 次），并记录原始响应便于排查

接口来自客户端抓包/社区实现，属于非官方用法；雷神更新后接口可能变化，届时日志里会出现登录或暂停失败。

## 注意

- 接口返回 `400803` 表示"账号已经暂停"，视为成功。
- `config.json` 中的 MD5 等价于登录凭据，不要提交或分享。
- 本项目不收集、不上传任何数据。

---

## English

**Leigod Auto Pause** — automatically pauses your Leigod accelerator time when the client process really exits or the PC shuts down.

| Action | Pauses? |
|---|---|
| Click X to minimize to tray (process alive) | No, acceleration continues |
| Fully quit the client from the tray | Yes, within ~1 second |
| Shutdown / restart / logoff | Yes, immediately (`WM_QUERYENDSESSION`) |
| Hard power-off / BSOD | Cannot be guaranteed |

Re-opening the client does **not** resume acceleration automatically.

### Setup

Requires Windows PowerShell 5.1 and a Leigod account with a password set (accounts that only use SMS login must set one first).

Build the native watcher first (uses the .NET Framework compiler that ships with Windows, no SDK needed):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

Then run the setup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

Credentials are stored locally in `%APPDATA%\LeigodAutoPause\config.json` as a phone number plus an MD5 password hash; nothing is uploaded by this tool. Setup registers a `LeigodAutoPause` scheduled task that starts the watcher at logon.

### Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

### How it works

- Login: `POST https://webapi.leigod.com/wap/login/bind`
- Pause: `POST https://webapi.leigod.com/api/user/pause`
- The watcher polls the UI process PID of `leigod.exe` and pauses when that process disappears.
- A hidden WinForms window handles `WM_QUERYENDSESSION` to pause during shutdown.
- The native watcher uses ~35 MB of memory and ~0% CPU at steady state.

These are unofficial interfaces and may change after a Leigod update.
