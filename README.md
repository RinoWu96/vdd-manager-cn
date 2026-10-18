# VDD 中文管理器

[Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)（VDD，MIT 开源）的中文图形管理界面。
这是一个外置工具：**不修改、不打包 VDD 本身**，驱动仍然使用官方签名发布的版本，本工具只通过公开接口管理它。

## 下载和启动

1. 到 [Releases](../../releases) 下载 `VDD-Manager-CN.zip`，解压到一个固定的文件夹。
2. 双击 `VDDManager.exe`。

不需要以管理员身份运行，只有禁用、启用、安装、卸载驱动时才会弹出 Windows 授权窗口。
需要 Windows 10 / 11 自带的 Windows PowerShell 5.1，不需要安装其他东西。

`VDDManager.exe` 只是一个很小的启动器，负责在不显示控制台窗口的情况下运行同目录下的 `VDDManager.ps1`，
所以两个文件要放在一起。界面和功能都在 `VDDManager.ps1` 里，可以直接修改。

## 文件

| 文件 | 说明 |
| --- | --- |
| `VDDManager.ps1` | 主程序（PowerShell + WPF） |
| `launcher/VDDManager.cs` | 启动器源码 |
| `build.ps1` | 生成图标 `VDDManager.ico`、编译 `VDDManager.exe`；加 `-Package` 同时打包 `dist/VDD-Manager-CN.zip` |

## 自己构建

只用 Windows 自带的 .NET Framework 4（`csc.exe`），不需要 Visual Studio：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Package
```

## 功能

| 页面 | 能做什么 |
| --- | --- |
| 概览 | 驱动状态、在线虚拟屏数量、与驱动的通信状态、所有在用显示器列表（每 3 秒刷新） |
| 显示设置 | 改虚拟屏的分辨率和刷新率（应用后 15 秒内不点“保留”会自动还原）、设为主显示器、改虚拟屏数量 |
| 可选分辨率 | 增删分辨率（带常用预设）、增删通用刷新率，保存并重启驱动后生效 |
| 驱动选项 | 硬件光标、SDR 10 位、HDR+、自定义 EDID、日志等开关（带中文说明），指定渲染用的显卡 |
| 驱动管理 | 重启、禁用、启用、安装、重新安装、卸载驱动 |
| 配置文件 | 直接编辑 `vdd_settings.xml`，保存前检查格式；自动备份，可一键恢复 |

## 用到的接口

| 用途 | 方式 | 需要管理员 |
| --- | --- | --- |
| 读写配置 | `C:\VirtualDisplayDriver\vdd_settings.xml`（或注册表 `HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver\VDDPATH` 指定的目录） | 否 |
| 重启驱动、改虚拟屏数量 | 驱动的命名管道 `\\.\pipe\MTTVirtualDisplayPipe`，命令 `RELOAD_DRIVER`、`SETDISPLAYCOUNT n` | 否 |
| 改分辨率 / 刷新率 / 主显示器 | Win32 `ChangeDisplaySettingsEx` | 否 |
| 驱动状态 | 读注册表 `HKLM\SYSTEM\CurrentControlSet\Enum\ROOT\DISPLAY`（硬件 ID `Root\MttVDD`） | 否 |
| 禁用 / 启用 / 重启设备 | `pnputil /disable-device`、`/enable-device`、`/restart-device` | 是 |
| 安装 / 卸载 | VDD Control 自带的 `devcon.exe install MttVDD.inf Root\MttVDD` / `devcon.exe remove Root\MttVDD` | 是 |

驱动安装包默认从 winget 安装的 VDD Control 目录里找（`%LOCALAPPDATA%\Microsoft\WinGet\Packages\VirtualDrivers.Virtual-Display-Driver_*`），
也可以在“驱动管理”页点“选择…”，指定解压后的官方驱动文件夹。

配置备份保存在 `%APPDATA%\VDDManagerCN\Backups`，保留最近 20 份。

## 测试过的版本

- VDD 驱动 11.30.4.434（2024-12-24），VDD Control 25.7.26（winget）
- Windows 11 Enterprise 23H2

如果以后 VDD 更新后配置格式或管道命令有变化，对照官方仓库对应版本的 `Virtual Display Driver (HDR)/MttVDD/Driver.cpp` 调整即可。

## 注意

- 大版本更新显卡或芯片组驱动前，先卸载 VDD，更新完再安装。
- 开机黑屏时：进入安全模式 → 设备管理器 → 显示适配器 → 卸载 Virtual Display Driver。
- 虚拟屏是唯一显示器时，禁用或卸载驱动可能导致本地黑屏或远程连接断开，程序会先提醒。
