# Codex Proxy Guard

[English](#english) | [简体中文](#简体中文)

## 简体中文

`Codex Proxy Guard` 是一个面向 Windows 10/11 的轻量 PowerShell 守护程序。它持续发现当前可用的本地代理监听地址，更新启动 Codex 所需的用户级代理环境变量；当代理地址变更或代理恢复后，按防抖规则重启 Codex 桌面端。

它适用于 Codex 桌面端偶发“正在重新连接”，且本地 v2rayN、Xray、Clash、Mihomo、sing-box、NekoRay、Hiddify 等代理会重启、切换端口或短暂失去监听的场景。

### 特性

- 以代理配置文件、Windows 系统代理和本地监听端口三种来源发现代理。
- 优先识别常见代理进程与端口；支持通过 `config.json` 指定程序和配置文件。
- 连续检测与防抖，避免端口瞬时变化反复重启 Codex。
- 可选重启已配置的代理程序，并在监听恢复后重启 Codex。
- 单实例、静默运行、当前用户开机自启、日志轮转和状态检查。
- 安装前备份用户级代理环境变量；卸载时恢复它们。

### 安全边界

- 不修改 Windows 的系统代理、PAC、DNS、防火墙或第三方代理软件配置。
- 仅写入当前用户的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY` 及其小写形式。
- 日志、状态和本地 `config.json` 位于 `%APPDATA%\CodexProxyGuard`，且不会被提交到 Git。
- 代理端口可访问不等同于代理上游网络一定可用；该工具解决的是本地监听与 Codex 进程环境同步问题。

### 安装

1. 下载或克隆仓库，在 PowerShell 中进入项目目录。
2. 先启动你的代理软件。安装程序会优先读取正在运行的代理程序路径，并尝试发现同目录的配置文件。
3. 执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

如自动发现失败，可显式提供路径：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -ProxyProgramPath 'C:\Path\To\proxy-client.exe' `
  -ProxyConfigPath 'C:\Path\To\config.json'
```

安装后守护程序在后台运行，并在两次稳定检测后设置环境变量。首次生效或代理恢复时，Codex 可能会被重启一次。

### 配置

安装脚本会从 `config.example.json` 创建本地 `config.json`。常用字段如下：

| 字段 | 说明 |
| --- | --- |
| `ProxyProgramPath` | 可选；用于检测失败后启动代理客户端。 |
| `ProxyConfigPaths` | 可选代理核心配置文件列表，用于精确获取入站端口。 |
| `PreferredProxyPrograms` | 监听扫描时优先匹配的进程名称。 |
| `PreferredPorts` | 没有配置文件时尝试的常见本地代理端口。 |
| `StableChecksRequired` | 新地址连续可用的次数，达到后才更新环境变量。 |
| `RestartDebounceSeconds` | Codex 两次重启之间的最短间隔。 |
| `ProxyProgramRestartDebounceSeconds` | 代理客户端两次恢复启动之间的最短间隔。 |

修改 `%APPDATA%\CodexProxyGuard\config.json` 后，重启 Windows 或结束守护进程后重新运行安装命令，使后台进程重新加载配置。

### 状态与排障

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:APPDATA\CodexProxyGuard\status.ps1"
```

查看日志：

```powershell
Get-Content "$env:APPDATA\CodexProxyGuard\logs\guard.log" -Tail 100
```

若状态显示没有可用监听端口，请先确认代理客户端正在运行、其本地监听已开启，并在 `config.json` 中补充程序路径或配置文件路径。若本地端口稳定但 Codex 仍频繁重连，通常是代理服务的上游线路、订阅节点或网络链路不稳定；可用其他客户端对同一代理进行连接测试，以区分本地守护问题与上游网络问题。

### 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:APPDATA\CodexProxyGuard\uninstall.ps1"
```

卸载会删除本工具的开机启动项、后台文件和日志，并恢复安装前保存的用户级代理环境变量。不会修改 Windows 系统代理，也不会删除或停止你的代理软件。

### 验证开发副本

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Project.ps1
```

## English

`Codex Proxy Guard` is a lightweight PowerShell watchdog for Windows 10/11. It discovers a working local proxy listener, keeps Codex's user-level proxy environment in sync, and restarts the Codex desktop app after a debounced proxy change or recovery.

It is intended for intermittent Codex desktop reconnects when a local proxy client changes port, restarts, or briefly loses its listener.

### What it does

- Discovers candidates from proxy configuration files, the Windows system-proxy setting, and local listeners.
- Recognizes common clients including v2rayN/Xray, Clash/Mihomo, sing-box, NekoRay, and Hiddify.
- Debounces changes before updating `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY` for the current user.
- Optionally restarts a configured proxy client after a confirmed outage, then restarts Codex when the listener recovers.
- Runs silently at sign-in, keeps one instance, rotates logs, and includes a status command.

### Safety

The guard never writes Windows system-proxy, PAC, DNS, firewall, or third-party proxy settings. It saves the pre-existing user environment values before its first update and restores them on uninstall. Runtime configuration, logs, and state stay under `%APPDATA%\CodexProxyGuard` and are not tracked by Git.

An open local TCP port only proves that the listener is reachable. It cannot prove the proxy's upstream route is healthy; continued reconnects with a healthy listener generally point to the proxy route or wider network.

### Install

Start your proxy client first, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The installer uses a currently running proxy client when it can find one. Provide explicit paths when necessary:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -ProxyProgramPath 'C:\Path\To\proxy-client.exe' `
  -ProxyConfigPath 'C:\Path\To\config.json'
```

The local configuration is created from `config.example.json`. See the Chinese configuration table above for the field descriptions; field names and behavior are identical.

### Status, logs, and uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:APPDATA\CodexProxyGuard\status.ps1"
Get-Content "$env:APPDATA\CodexProxyGuard\logs\guard.log" -Tail 100
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:APPDATA\CodexProxyGuard\uninstall.ps1"
```

Uninstall removes only this tool's startup entry, installation, and logs, then restores saved user proxy environment values. It does not alter Windows system-proxy settings or the proxy client.

## License

Released under the [MIT License](LICENSE).
