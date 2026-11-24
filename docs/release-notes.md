## AutoSidecar 0.1.0 beta 1

A minimal native macOS menu-bar app for automatically connecting a USB iPad with Sidecar, including when no physical monitor is attached.

- Menu-bar status for the background service and launch at login.
- Graphical iPad pairing and settings for resolution, HiDPI, display layout, optional Dock profiles, and virtual-display refresh rate.
- English and Simplified Chinese, following the macOS app language.
- Quit stops the owned background service and cleans up the Sidecar session and virtual display. Closing Settings keeps it running.
- Existing CLI and saved configuration remain supported; the app can migrate the old LaunchAgent.

### Install

Download the DMG, drag AutoSidecar to Applications, and open it. Choose your iPad in Settings and enable launch at login. Prepare a physical monitor or remote access for initial setup or migration.

### Compatibility and limits

- Initial binary: Apple Silicon (arm64). UI requires macOS 13+; older OS compatibility with private APIs has not been verified.
- Runs after user login; it cannot show the login or FileVault unlock screen.
- Sidecar-compatible devices and a USB data cable are required.
- A virtual display rate above 60 Hz is experimental and does not establish Sidecar's delivered frame rate.
- Automated tests cover config/lifecycle fixtures. Physical-device acceptance is still pending; this is a prerelease.

### Signing and validation

The DMG and application are signed with Developer ID Application and notarized by Apple. The notarization log reports no issues. The DMG includes a stapled ticket and passes Gatekeeper assessment. SHA256SUMS covers the final stapled DMG.

### Draft readiness

Physical-device acceptance and upstream licensing confirmation remain pending. This release is a draft; do not publish until these are resolved.

---

极简原生 macOS 菜单栏版本：查看后台服务和登录启动状态，图形化绑定 iPad、修改显示和 Dock 设置。界面跟随系统语言，支持简体中文和英文。

安装：将 DMG 中的 AutoSidecar 拖入“应用程序”后打开。首次设置或接管旧版时，请准备实体显示器或远程访问。仅在登录后运行，不支持登录前或 FileVault 解锁画面。首版仅提供 Apple Silicon 构建，真实硬件验收仍待完成。
