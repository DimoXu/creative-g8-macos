# Creative G8 for macOS

适用于 macOS 的创新 Creative Sound Blaster G8 音量控制兼容工具。在兼容输出模式下，提供键盘音量键、静音键、菜单栏控制和自动隐藏的简易音量条。

A lightweight macOS volume-control companion for the Creative Sound Blaster G8, with media-key support, menu-bar controls, and a compact volume panel for a configured compatibility output.

这是第三方辅助工具，与 Creative 官方无关联。它控制现有音频设备的音量，不安装音频驱动，也不修改声卡固件或 DSP。

## 当前版本

**1.2 / build 5**，版本标签 `v1.2-build.5`。

该版本已由使用者在本机 G8 配置上确认好用，包括修复调节时的短暂静音。验证范围和版本变更见 [CHANGELOG.md](CHANGELOG.md)。

## 功能

- 音量加减键每次调整 3 个百分点的目标音量；长按连续调整。实际读数受设备音量量化影响。
- 支持静音键、菜单栏滑块和独立简易音量条。
- 简易条显示当前百分比与静音状态；最后操作约 4 秒后隐藏，拖动期间保持显示，松手后重新计时。
- 正常非零调节直接写入并逐声道回读，不再为每次加减主动切换静音。
- 归零使用硬件静音，不向 USB 音量属性写入零或极低标量；取消静音从 3% 开始。
- 回读异常时尝试静音并锁定控制，可在主窗口中执行“错误后重新检查”。
- 切换到其他输出时停止接管音量键；关闭主窗口后继续在菜单栏运行。

## 适用配置

- macOS 13 或更高版本。当前下载应用为 **Apple Silicon / arm64** 构建；Intel Mac 尚未验证。
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

未授予辅助功能权限时，应用会使用备用媒体键监听；此时不能阻止系统原有音量浮层。工具只识别音量加、减和静音媒体事件，不记录普通键盘输入，不联网，也不自动设置开机启动。

## 从源码构建

需要 Xcode Command Line Tools、`zsh`，以及安装流程使用的 `python3`。无需第三方 Swift 依赖。

```sh
./build-g8-volume.sh
```

脚本执行编译、签名检查、逻辑自测、UI 自测和当前设备状态读取，成功后将应用路径写入 `build/verified-app-path`。完整脚本的最后一步需要连接 G8 并使用上述兼容输出；UI 自测会短暂显示测试窗口，不写入硬件音量。

构建并安装到 `~/Applications/G8 Volume.app`：

```sh
./build-g8-volume.sh --install
```

该命令验证产物后停止本工具的旧进程、替换应用并重新启动。原应用备份保存在本次构建暂存目录中。

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

## 源码

- `G8VolumeKeys.swift`：AppKit 界面、媒体键处理、CoreAudio 控制和自测。
- `G8VolumeKeys-Info.plist`：应用元数据与版本。
- `build-g8-volume.sh`：构建、验证和安装。
- `CHANGELOG.md`：版本记录。
