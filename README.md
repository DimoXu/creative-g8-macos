# Creative G8 for macOS

适用于 macOS 的创新 Creative Sound Blaster G8 音量控制兼容工具。在兼容输出模式下，提供键盘音量键、静音键、菜单栏控制和自动隐藏的简易音量条。

A lightweight macOS volume-control companion for the Creative Sound Blaster G8, with media-key support, menu-bar controls, and a compact volume panel for a configured compatibility output.

这是第三方辅助工具，与 Creative 官方无关联。它控制现有音频设备的音量，不安装音频驱动，也不修改声卡固件或 DSP。

## 当前版本

**应用：1.2 / build 5**（`v1.2-build.5`）；**恢复工具：recovery-v1**。

[下载应用](https://github.com/DimoXu/creative-g8-macos/releases/tag/v1.2-build.5) · [下载恢复工具](https://github.com/DimoXu/creative-g8-macos/releases/tag/recovery-v1) · [版本记录](CHANGELOG.md)

保留使用者确认好用的 build 5 应用，单独提供可选的登录启动和异常退出恢复脚本。恢复工具不重新编译、替换或签名应用，也不改变音量事务；它不是新的 build 6。

## 功能

- 音量加减键每次调整 3 个百分点的目标音量；长按连续调整。实际读数受设备音量量化影响。
- 支持静音键、菜单栏滑块和独立简易音量条。
- 简易条显示当前百分比与静音状态；最后操作约 4 秒后隐藏，拖动期间保持显示，松手后重新计时。
- 正常非零调节直接写入并逐声道回读，不再为每次加减主动切换静音。
- 归零使用硬件静音，不向 USB 音量属性写入零或极低标量；取消静音从 3% 开始。
- 回读异常时尝试静音并锁定控制，可在主窗口中执行“错误后重新检查”。
- 切换到其他输出时停止接管音量键；关闭主窗口后继续在菜单栏运行。

## 适用配置

- **现有 build 5 下载包的 Mach-O 最低部署目标为 macOS 27.0，架构为 Apple Silicon / arm64**；本机验证系统为 macOS 27.0.1。未提供可验证的 macOS 13–26 或 Intel 兼容产物。旧版说明写过 13+，现已纠正；应用包内历史 `LSMinimumSystemVersion=13.0` 也不能降低二进制实际要求。
- 物理设备名称为 `Sound Blaster G8 USB-1`。
- 默认输出必须是名为 `G8 JSTV 兼容输出` 的聚集设备，且其活动子设备只有上述 G8。

设备名称和输出结构目前在源码中固定检查。这是针对已配置兼容输出的工具，尚未提供通用设备选择或自动配置向导。

如果需要手动建立对应输出，可在“音频 MIDI 设置”中创建聚集设备，仅选择 G8 作为子设备，并将其命名为 `G8 JSTV 兼容输出`，然后设为默认声音输出。应用本身不会创建该路由；其他采样率、通道和时钟配置需按实际设备环境核对。

## 安装与使用

1. 下载对应版本的 `G8-Volume-v1.2-build.5-macos-arm64.zip` 并解压。
2. 将 `G8 Volume.app` 放入 `~/Applications`，然后打开应用。
3. 在主窗口核对输出已就绪及音量读数。
4. 使用“启用键盘音量键（辅助功能授权）”按钮，按系统提示在“隐私与安全性 → 辅助功能”中允许应用控制媒体键。
5. 使用键盘音量键、菜单栏控制或“显示简易音量条”。

发布应用使用本地临时签名，未经过 Apple Developer ID 签名和公证。下载后 macOS 可能要求在“隐私与安全性”中确认打开；源码构建也是可选安装方式。

未授予辅助功能权限时，应用会尝试备用媒体键监听；此时不能阻止系统原有音量浮层，实际可用性取决于系统授权状态。工具只识别音量加、减和静音媒体事件，不记录普通键盘输入，不联网。应用本身不设置开机启动；下面的恢复工具须主动安装后才生效。

### 可选：登录启动与异常恢复

如果音量键和简易条同时失效，先检查应用是否仍在运行。build 5 本身不会自动启动或保活。下载并解压 `G8-Recovery-recovery-v1.zip`，在解压目录打开终端（或在克隆仓库根目录运行）；先安装上述应用到 `~/Applications/G8 Volume.app`，再执行：

```sh
python3 manage-g8-startup.py install
python3 manage-g8-startup.py status
```

需要可运行的 Python 3（例如 Xcode Command Line Tools 提供的 `python3`）；脚本只依赖标准库。应用系统要求仍以上述 build 5 下载产物为准。安装时验证 bundle ID 和签名完整性（并非 Developer ID 身份认证或固定摘要白名单），停止该安装路径的当前用户旧进程，再交由 macOS `launchd` 托管。失败时尝试还原旧配置和原运行状态；若回滚也失败，会明确报错并提示手动打开应用。若服务已加载但应用已停止，安装会在改动前拒绝：请先执行 `start` 或 `remove`，以免失败回滚重新启动你已主动退出的应用。

启用后，macOS 在登录时启动应用，并在信号终止或非零退出后自动恢复；launchd 设置 10 秒节流，实际恢复时间由系统决定，并非故障发生后固定等待 10 秒。菜单中的正常“退出（不改变输出）”不会被自动拉起；下次登录仍启动。关闭主窗口不是退出，菜单栏仍继续工作。正常退出后本次会话若要重新恢复托管运行，请用以下命令（不要同时启动多个副本）：

```sh
python3 manage-g8-startup.py start
```

关闭此功能并停止托管进程（不删除应用）：

```sh
python3 manage-g8-startup.py remove
```

配置位于 `~/Library/LaunchAgents/local.codex.g8-volume-keys.recovery.plist`，标准输出／错误日志位于 `~/Library/Logs/G8VolumeKeys/`。仅在当前用户图形会话中运行，不需要管理员权限，不绕过辅助功能授权。系统设置中也可能将其列为后台项目；被系统禁用时需自行恢复允许，脚本不会强行覆盖禁用状态。安装后可用 `status` 查看 `state = running` 与 PID；出现报错不要只凭“Installed”字样判断应用已就绪。登录／异常恢复仍会按原版行为显示主窗口，不是静默后台重启。

重新安装／替换／删除应用前，先执行 `remove`；安装完成后再执行 `install`，避免恢复机制与安装器争抢进程。新构建脚本会在构建前和替换前拒绝仍存在的恢复配置。请串行运行这些命令，不要同时运行多个安装器或恢复管理命令；目前没有跨命令事务锁。重新编译可能需要再次核对系统授权。原版主窗内“未设置开机自启”是 build 5 自身说明，不反映此可选外部配置。

**恢复不等于根因修复**：本机曾在音量键与窗口同时失效时确认应用未运行，但该次退出原因尚不明确；只有较早版本的历史崩溃报告，不能据此断言当前版本的退出原因。此机制不能修复主线程卡死、授权失效、USB 断连或音频设备异常，也不会在你主动正常退出后强行重开。重复异常应结合 `status`、上述日志和 `~/Library/Logs/DiagnosticReports/` 中对应报告调查。分享报告前请删除本机路径和个人信息。

## 从源码构建

需要 Xcode Command Line Tools、`zsh`，以及安装流程使用的 `python3`。无需第三方 Swift 依赖。

脚本沿用本机 SDK 的默认部署目标，没有承诺通过源码构建即可支持 macOS 13。构建后可用 `xcrun vtool -show-build <应用内的可执行文件路径>` 核对 Mach-O 最低系统版本；旧系统支持需要单独设置部署目标并实机验证。

```sh
./build-g8-volume.sh
```

脚本执行编译、签名检查、逻辑自测、UI 自测和当前设备状态读取，成功后将应用路径写入 `build/verified-app-path`。完整脚本的最后一步需要连接 G8 并使用上述兼容输出；UI 自测会短暂显示测试窗口，不写入硬件音量。

构建并安装到 `~/Applications/G8 Volume.app`：

```sh
./build-g8-volume.sh --install
```

该命令验证产物后停止本工具的旧进程、替换应用并启动，**不会自动安装恢复工具**。若已启用恢复配置，先执行 `python3 manage-g8-startup.py remove`，构建安装完成后再按需执行 `install`。原应用备份保存在本次构建暂存目录中。

也可直接编译：

```sh
xcrun swiftc -O -warnings-as-errors \
  -framework AppKit -framework ApplicationServices -framework CoreAudio \
  G8VolumeKeys.swift -o /tmp/G8VolumeKeys
/tmp/G8VolumeKeys --self-test
/tmp/G8VolumeKeys --ui-self-test
```

## 验证与限制

当前版本通过 1102 项纯逻辑断言，以及界面状态和自动隐藏回归。部分断言为边界取样，并不代表 1102 个独立场景。另已完成本机 G8 实际音量操作、签名及安装产物一致性检查，并收到使用者的实际听感确认。

尚未覆盖所有 G8 固件、macOS 版本、Intel Mac 或长期运行场景。正常非零调节的异常保护在回读后执行，无法保证阻止设备驱动本身的瞬态异常；硬件静音保护也依赖设备正确执行静音指令。

恢复工具的配置和失败回滚有独立单元测试，运行 `python3 manage-g8-startup.py self-test`，不写系统配置、不启动应用、不调音量。异常退出恢复已在本机实际验证，前后声卡状态不变；相同 launchd 配置的零退出夹具在 14 秒观察期内未被重启。这不等于已实测应用菜单退出端到端链路（本轮未安全取得菜单栏操作入口）。登录加载的配置检查不等于已重启机器验收；长期稳定性也不因单次恢复测试而得到证明。

## 公开源码与许可

本仓库公开提供源码和下载，不代表 Creative 官方支持或完整的 G8 驱动替代品。当前尚未指定开源许可证；公开可见不等于授予任意复制、修改或再分发的许可。报告问题时请说明 macOS 版本、应用版本、设备／输出配置及是否启用恢复工具，不要上传含私人内容的完整系统日志。

## 源码

- `G8VolumeKeys.swift`：AppKit 界面、媒体键处理、CoreAudio 控制和自测。
- `G8VolumeKeys-Info.plist`：应用元数据与版本。
- `build-g8-volume.sh`：构建、验证和安装。
- `CHANGELOG.md`：版本记录。
- `manage-g8-startup.py`：安装、检查、启动或移除用户级 launchd 管理。
