## AutoSidecar 0.1.0 beta 1

Native macOS menu-bar app for Sidecar, with USB auto-connect and manual USB or wireless connections.

### What is included

- Connect iPad / Disconnect follows the actual Sidecar connection state.
- Manual Connect and Disconnect use the CLI commands and do not change the background service.
- Start Service / Stop Service independently control USB and wake auto-connect.
- Graphical pairing, resolution, HiDPI, display layout, optional Dock profiles, and virtual-display refresh rate.
- English and Simplified Chinese, following the macOS app language.
- Minimal app icon. Closing Settings keeps the service running; Quit disconnects and cleans up.

### Install

Download `AutoSidecar-0.1.0-arm64.dmg`, drag AutoSidecar into Applications, then open it.
Choose your iPad in Settings and enable launch at login if desired. Prepare a physical monitor or remote access for initial setup or migration. Replace an older installed copy rather than running the app from the disk image, then eject the disk image.

### Compatibility and validation

- Apple Silicon (arm64); macOS 13+ for the UI. Private Sidecar APIs may vary by OS version.
- A Sidecar-compatible Mac and iPad are required. Automatic connection uses USB; manual connection also supports wireless Sidecar when available.
- Runs after user login, not at the login or FileVault unlock screen.
- A refresh-rate setting above 60 Hz is experimental and does not prove delivered Sidecar frame rate.
- Stopping the service releases its headless display and may interrupt an iPad-only desktop.
- Automated configuration, Dock, wake, installer, preferences, menu, and service lifecycle checks passed. Local hardware use confirmed USB auto-connect and a manual wireless connection; broad device/OS acceptance remains incomplete. This is a prerelease.
- Application and DMG are signed with Developer ID Application. The download is notarized by Apple, carries a stapled ticket, and passes Gatekeeper assessment. `SHA256SUMS` covers the final DMG.

### Privacy

No enrolled device configuration, USB serial, Sidecar device identifier, local logs, credentials, or signing private keys are included. Configuration and logs are created on each user's own Mac. The Apple signature exposes the developer certificate's public identity as expected for a signed macOS application.

---

极简原生 macOS 菜单栏应用，支持 USB 自动连接，以及 USB / 无线随航手动连接。

- 根据实际连接状态显示“连接 iPad”或“断开”。
- 手动连接、断开与“启动服务 / 停止服务”相互独立。
- 支持图形化绑定、显示与 Dock 设置，界面跟随系统语言，提供中文和英文。
- 下载 DMG，将应用拖入“应用程序”后打开；更新时替换旧版本并弹出安装盘。

仅提供 Apple Silicon 构建，界面要求 macOS 13+。首次设置请准备实体显示器或远程访问；不支持登录前和 FileVault 解锁界面。停止服务会释放虚拟屏幕，仅用 iPad 显示时可能影响桌面。测试覆盖自动化用例及有限本机使用，尚未完成跨机型和系统版本验收，因此作为预发布版本提供。

应用和 DMG 使用 Developer ID 签名，并经过 Apple 公证。安装包不含开发机的设备绑定、配置、日志、凭据或私钥；签名证书中的公开开发者身份仍可查看。
