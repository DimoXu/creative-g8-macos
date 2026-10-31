import AppKit
import ApplicationServices
import CoreAudio
import Foundation

private let physicalName = "Sound Blaster G8 USB-1"
private let compatibleName = "G8 JSTV 兼容输出"
private let bundleID = "local.codex.g8-volume-keys"
private let volumeStep: Float32 = 0.03

private struct PendingSlider {
    var value: Float32?
    mutating func cancelForDiscreteAction() { value = nil }
    mutating func take() -> Float32? {
        defer { value = nil }
        return value
    }
}

private enum G8Error: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

private struct StereoVolume {
    let left: Float32
    let right: Float32
    var level: Float32 { max(left, right) }
    var percent: Int { Int((level * 100).rounded()) }

    func adjusted(by delta: Float32) -> StereoVolume {
        let target = min(1, max(0, level + delta))
        guard level > 0 else { return StereoVolume(left: target, right: target) }
        let ratio = target / level
        return StereoVolume(left: left * ratio, right: right * ratio)
    }

    func setLevel(_ target: Float32) -> StereoVolume {
        let target = min(1, max(0, target))
        guard level > 0 else { return StereoVolume(left: target, right: target) }
        let ratio = target / level
        return StereoVolume(left: left * ratio, right: right * ratio)
    }
}

private enum MediaKey: UInt32 {
    // Verified against IOKit/hidsystem/ev_keymap.h.
    case up = 0, down = 1, mute = 7
}

private struct MediaKeyPress {
    let key: MediaKey
    let isDown: Bool
    let isRepeat: Bool

    static func decode(type: UInt, subtype: Int16, data: Int) -> MediaKeyPress? {
        // Only NX_SYSDEFINED / NX_SUBTYPE_AUX_CONTROL_BUTTONS, never ordinary typing.
        guard type == NSEvent.EventType.systemDefined.rawValue, subtype == 8 else { return nil }
        let bits = UInt32(truncatingIfNeeded: data)
        guard let key = MediaKey(rawValue: (bits >> 16) & 0xffff) else { return nil }
        let state = (bits >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        return MediaKeyPress(key: key, isDown: state == 0x0a, isRepeat: bits & 1 != 0)
    }

    var shouldAct: Bool { isDown && !(key == .mute && isRepeat) }
}

private struct AudioSnapshot {
    let device: AudioDeviceID
    let outputName: String
    let compatible: Bool
    let volume: StereoVolume
    let muted: Bool
    var displayedVolume: StereoVolume { muted ? StereoVolume(left: 0, right: 0) : volume }
    var muteToggleTarget: StereoVolume {
        muted ? StereoVolume(left: volumeStep, right: volumeStep) : StereoVolume(left: 0, right: 0)
    }
}

private protocol VolumeDevice: AnyObject {
    func snapshot() throws -> AudioSnapshot
    func setMuted(_ muted: Bool, device: AudioDeviceID) throws
    func setChannel(_ channel: UInt32, level: Float32, device: AudioDeviceID) throws
}

private func applySafeVolume(_ next: StereoVolume, before: AudioSnapshot,
                             device: VolumeDevice, leaveMuted: Bool = false) throws -> AudioSnapshot {
    guard before.compatible, next.left.isFinite, next.right.isFinite,
          (0...1).contains(next.left), (0...1).contains(next.right) else {
        throw G8Error.message("输出或目标音量无效")
    }
    func checked(_ state: AudioSnapshot, muted: Bool) throws {
        guard state.device == before.device, state.compatible, state.muted == muted else {
            throw G8Error.message("输出或静音状态变化，已停止调整")
        }
    }
    func verifyVolume(_ state: AudioSnapshot, expected: StereoVolume, muted: Bool) throws {
        try checked(state, muted: muted)
        guard min(state.volume.left, state.volume.right) >= 0.005,
              abs(state.volume.left - expected.left) < 0.01,
              abs(state.volume.right - expected.right) < 0.01,
              !(expected.left < before.volume.left && state.volume.left > before.volume.left + 0.001),
              !(expected.right < before.volume.right && state.volume.right > before.volume.right + 0.001) else {
            throw G8Error.message("音量回读异常，保持静音；请检查 G8")
        }
    }
    do {
        // Ordinary nonzero adjustments must not interrupt playback with a mute cycle.
        if !before.muted, !leaveMuted,
           min(before.volume.left, before.volume.right) >= 0.005,
           min(next.left, next.right) >= 0.005 {
            var after = before
            if next.left != before.volume.left {
                try device.setChannel(1, level: next.left, device: before.device)
                after = try device.snapshot()
                try verifyVolume(after, expected: StereoVolume(left: next.left, right: before.volume.right),
                                 muted: false)
            }
            if next.right != before.volume.right {
                try device.setChannel(2, level: next.right, device: before.device)
                after = try device.snapshot()
                try verifyVolume(after, expected: next, muted: false)
            }
            return after
        }
        try device.setMuted(true, device: before.device)
        let silenced = try device.snapshot()
        try checked(silenced, muted: true)
        // Do not send zero/sub-percent values to the USB volume controls.
        // A displayed zero is hardware mute; the last safe scalar is retained.
        if min(next.left, next.right) < 0.005 { return silenced }
        try device.setChannel(1, level: next.left, device: before.device)
        try device.setChannel(2, level: next.right, device: before.device)
        let verified = try device.snapshot()
        try verifyVolume(verified, expected: next, muted: true)
        if verified.volume.percent == 0 { return verified }
        if leaveMuted { return verified }
        try device.setMuted(false, device: before.device)
        let after = try device.snapshot()
        try verifyVolume(after, expected: next, muted: false)
        return after
    } catch {
        // Never roll back to a louder value after a failed decrease.
        try? device.setMuted(true, device: before.device)
        throw error
    }
}

private final class G8Hardware: VolumeDevice {
    private func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: element)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw G8Error.message("\(operation)失败（CoreAudio \(status)）")
        }
    }

    private func number<T: Numeric>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: UInt32 = 0, initial: T
    ) throws -> T {
        var property = address(selector, scope: scope, element: element)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "读取设备")
        guard size == MemoryLayout<T>.size else { throw G8Error.message("音频属性大小异常") }
        return value
    }

    private func name(_ object: AudioObjectID) throws -> String {
        var property = address(kAudioObjectPropertyName)
        var reference: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &reference), "读取名称")
        guard let reference else { throw G8Error.message("设备名称为空") }
        // CoreAudio explicitly transfers ownership of this CFString to the caller.
        return reference.takeRetainedValue() as String
    }

    private func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> [UInt32] {
        var property = address(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "读取设备列表")
        guard size % 4 == 0, size <= 65536 else { throw G8Error.message("设备列表大小异常") }
        guard size > 0 else { return [] }
        var result = [UInt32](repeating: 0, count: Int(size / 4))
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, "读取设备列表")
        return Array(result.prefix(Int(size / 4)))
    }

    private func writable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32) throws {
        var property = address(selector, scope: kAudioObjectPropertyScopeOutput, element: element)
        var result = DarwinBoolean(false)
        try check(AudioObjectIsPropertySettable(device, &property, &result), "检查音量控制")
        guard result.boolValue else { throw G8Error.message("G8 音量控制当前不可写") }
    }

    private func write<T: Numeric>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: T) throws {
        var property = address(selector, scope: kAudioObjectPropertyScopeOutput, element: element)
        var value = value
        let status = withUnsafeBytes(of: &value) {
            AudioObjectSetPropertyData(device, &property, 0, nil, UInt32($0.count), $0.baseAddress!)
        }
        try check(status, "调整 G8")
    }

    private func applyVolume(_ next: StereoVolume, to before: AudioSnapshot) throws -> AudioSnapshot {
        try applySafeVolume(next, before: before, device: self)
    }

    func setMuted(_ muted: Bool, device: AudioDeviceID) throws {
        try writable(device, kAudioDevicePropertyMute, 0)
        try write(device, kAudioDevicePropertyMute, 0, UInt32(muted ? 1 : 0))
    }

    func setChannel(_ channel: UInt32, level: Float32, device: AudioDeviceID) throws {
        try writable(device, kAudioDevicePropertyVolumeScalar, channel)
        try write(device, kAudioDevicePropertyVolumeScalar, channel, level)
    }

    func snapshot() throws -> AudioSnapshot {
        let devices = try objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        let matches = devices.filter { (try? name($0)) == physicalName }
        guard matches.count == 1, let device = matches.first else {
            throw G8Error.message("未找到唯一的 \(physicalName)")
        }
        let alive: UInt32 = try number(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))
        let transport: UInt32 = try number(device, kAudioDevicePropertyTransportType, initial: UInt32(0))
        guard alive == 1, transport == kAudioDeviceTransportTypeUSB else {
            throw G8Error.message("G8 USB 设备尚未就绪")
        }
        let output: UInt32 = try number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: UInt32(0))
        let outputName = try name(output)
        let members = (try? objects(output, kAudioAggregateDevicePropertyActiveSubDeviceList)) ?? []
        let compatible = outputName == compatibleName && members == [device]
        let left: Float32 = try number(device, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: 1, initial: Float32(0))
        let right: Float32 = try number(device, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: 2, initial: Float32(0))
        guard left.isFinite, right.isFinite, (0...1).contains(left), (0...1).contains(right) else {
            throw G8Error.message("G8 返回了无效音量")
        }
        let muted: UInt32 = try number(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0))
        return AudioSnapshot(device: device, outputName: outputName, compatible: compatible,
                             volume: StereoVolume(left: left, right: right), muted: muted != 0)
    }

    func adjust(by delta: Float32) throws -> AudioSnapshot {
        let before = try snapshot()
        guard before.compatible else { throw G8Error.message("未使用 G8 兼容输出，不接管音量") }
        guard delta.isFinite, abs(delta) <= 0.051 else { throw G8Error.message("无效音量步长") }
        let next = before.displayedVolume.adjusted(by: delta)
        return try applyVolume(next, to: before)
    }

    func setVolume(to level: Float32) throws -> AudioSnapshot {
        let before = try snapshot()
        guard before.compatible else { throw G8Error.message("未使用 G8 兼容输出，不接管音量") }
        guard level.isFinite, (0...1).contains(level) else {
            throw G8Error.message("无效音量值")
        }
        return try applyVolume(before.displayedVolume.setLevel(level), to: before)
    }

    func toggleMute() throws -> AudioSnapshot {
        let before = try snapshot()
        guard before.compatible else { throw G8Error.message("未使用 G8 兼容输出，不接管静音") }
        // Never trust a retained hardware scalar after mute, restart or an error.
        let next = before.muteToggleTarget
        return try applyVolume(next, to: before)
    }
}

private final class TrackingSlider: NSSlider {
    var trackingChanged: (() -> Void)?
    private(set) var tracking = false {
        didSet { trackingChanged?() }
    }
    override func mouseDown(with event: NSEvent) {
        withTracking { super.mouseDown(with: event) }
    }
    func withTracking(_ action: () -> Void) {
        tracking = true
        defer { tracking = false }
        action()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hardware = G8Hardware()
    private let audioQueue = DispatchQueue(label: "local.codex.g8-volume.audio")
    private var safetyLocked = false // Accessed only on audioQueue.
    private var controlsLocked = false
    private var reading = false
    private var pendingSlider = PendingSlider()
    private var hud: NSPanel!
    private var hudSlider: TrackingSlider!
    private var hudValue: NSTextField!
    private var hudDismiss: Timer?
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let volumeLabel = NSTextField(labelWithString: "读取 G8 中…")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var sliderItem: NSMenuItem!
    private var volumeSlider: TrackingSlider!
    private var sliderValueLabel: NSTextField!
    private var stateMenu: NSMenuItem!
    private var lowerButton: NSButton!
    private var raiseButton: NSButton!
    private var muteButton: NSButton!
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var compatible = false
    private var pendingActions = 0
    private var lastAction: TimeInterval = 0
    private var lastHandledEventTimestamp: TimeInterval = -1
    private var mediaKeyCount = 0
    private var permissionRequested = false
    private var updatingSlider = false
    private var outputListener: AudioObjectPropertyListenerBlock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        buildWindow()
        buildHUD()
        // No automatic permission request, volume change, audio routing, or login item.
        refresh()
        showWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        var property = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.pendingSlider.cancelForDiscreteAction()
            self?.compatible = false
            self?.refresh()
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        hudDismiss?.invalidate()
        removeTap()
        removeFallbackMonitors()
        if let listener = outputListener {
            var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                       mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
        }
    }

    private func menuItem(_ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if action == nil { item.isEnabled = false }
        return item
    }

    private func buildMenu() {
        // Use a square SF Symbol so the menu bar shows only a familiar volume icon.
        // A newly created status item is inserted at the system status-item edge;
        // macOS still allows the user to fine-tune its exact order with ⌘-drag.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "G8VolumeStatusItem"
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.toolTip = "G8 音量"
        let menu = NSMenu()
        let sliderContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        let sliderIcon = NSImageView()
        sliderIcon.image = NSImage(
            systemSymbolName: "speaker.wave.2.fill",
            accessibilityDescription: "G8 音量"
        )
        sliderIcon.image?.isTemplate = true
        sliderIcon.imageScaling = NSImageScaling.scaleProportionallyDown
        sliderIcon.translatesAutoresizingMaskIntoConstraints = false
        sliderIcon.setContentHuggingPriority(.required, for: .horizontal)
        sliderIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        volumeSlider = TrackingSlider(value: 0, minValue: 0, maxValue: 1,
                                target: self, action: #selector(sliderChanged(_:)))
        volumeSlider.isContinuous = true
        volumeSlider.sliderType = .linear
        volumeSlider.numberOfTickMarks = 0
        volumeSlider.controlSize = .small
        volumeSlider.setAccessibilityLabel("G8 输出音量")
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false

        sliderValueLabel = NSTextField(labelWithString: "—")
        sliderValueLabel.isBezeled = false
        sliderValueLabel.drawsBackground = false
        sliderValueLabel.alignment = .right
        sliderValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sliderValueLabel.isEditable = false
        sliderValueLabel.isSelectable = false
        sliderValueLabel.translatesAutoresizingMaskIntoConstraints = false
        sliderValueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sliderValueLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        sliderIcon.translatesAutoresizingMaskIntoConstraints = true
        volumeSlider.translatesAutoresizingMaskIntoConstraints = true
        sliderValueLabel.translatesAutoresizingMaskIntoConstraints = true
        sliderIcon.frame = NSRect(x: 12, y: 11, width: 18, height: 18)
        volumeSlider.frame = NSRect(x: 38, y: 7, width: 210, height: 26)
        volumeSlider.autoresizingMask = [.width]
        sliderValueLabel.frame = NSRect(x: 256, y: 11, width: 50, height: 18)
        sliderValueLabel.autoresizingMask = [.minXMargin]
        sliderContainer.addSubview(sliderIcon)
        sliderContainer.addSubview(volumeSlider)
        sliderContainer.addSubview(sliderValueLabel)
        sliderItem = NSMenuItem()
        sliderItem.view = sliderContainer
        menu.addItem(sliderItem)

        stateMenu = menuItem("等待键盘授权", nil)
        menu.addItem(stateMenu)
        menu.addItem(.separator())
        menu.addItem(menuItem("降低音量（3%）", #selector(lower)))
        menu.addItem(menuItem("提高音量（3%）", #selector(raiseVolume)))
        menu.addItem(menuItem("静音 / 取消静音", #selector(mute)))
        menu.addItem(.separator())
        menu.addItem(menuItem("显示控制与授权窗口", #selector(showWindow)))
        menu.addItem(menuItem("显示 G8 简易音量条", #selector(showCompact)))
        menu.addItem(menuItem("退出（不改变输出）", #selector(quit)))
        statusItem.menu = menu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "G8 音量键控制"
        window.isReleasedWhenClosed = false
        window.center()
        let title = NSTextField(labelWithString: "键盘控制 G8，保留 JSTV 兼容输出")
        title.font = .boldSystemFont(ofSize: 18)
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
        lowerButton = NSButton(title: "降低音量", target: self, action: #selector(lower))
        raiseButton = NSButton(title: "提高音量", target: self, action: #selector(raiseVolume))
        muteButton = NSButton(title: "静音 / 取消静音", target: self, action: #selector(mute))
        for button in [lowerButton!, raiseButton!] {
            button.isContinuous = true
            button.setPeriodicDelay(0.4, interval: 0.12)
        }
        let controls = NSStackView(views: [lowerButton, raiseButton, muteButton])
        controls.spacing = 12
        let permission = NSButton(title: "启用键盘音量键（辅助功能授权）", target: self, action: #selector(requestPermission))
        let retry = NSButton(title: "错误后重新检查", target: self, action: #selector(retryHardware))
        let compact = NSButton(title: "显示简易音量条", target: self, action: #selector(showCompact))
        let info = NSTextField(wrappingLabelWithString:
            "仅处理音量加、减、静音媒体键，不记录普通按键，不联网。\n切换到其他输出时自动让回系统控制；未设置开机自启。\n关闭窗口后仍在菜单栏运行；退出即可停止接管。")
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        let stack = NSStackView(views: [title, volumeLabel, stateLabel, controls, compact, permission, retry, info, errorLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22)
        ])
    }

    private func buildHUD() {
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 70),
                      styleMask: [.titled, .closable, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        hud.title = "G8 实际音量"
        hud.isReleasedWhenClosed = false
        hud.hidesOnDeactivate = false
        hud.level = .floating
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hudValue = NSTextField(labelWithString: "读取中…")
        hudValue.frame = NSRect(x: 14, y: 42, width: 292, height: 20)
        hudValue.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        hudSlider = TrackingSlider(value: 0, minValue: 0, maxValue: 1,
                                  target: self, action: #selector(sliderChanged(_:)))
        hudSlider.frame = NSRect(x: 14, y: 10, width: 292, height: 26)
        hudSlider.isContinuous = true
        hudSlider.trackingChanged = { [weak self] in
            guard let self, self.hud.isVisible else { return }
            self.showHUD()
        }
        hudSlider.setAccessibilityLabel("G8 简易音量条")
        hud.contentView!.addSubview(hudValue)
        hud.contentView!.addSubview(hudSlider)
        if let frame = NSScreen.main?.visibleFrame {
            hud.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 344, y: frame.maxY - 18))
        }
    }

    @objc private func showHUD() {
        hud.orderFrontRegardless()
        hudDismiss?.invalidate()
        hudDismiss = nil
        guard !hudSlider.tracking else { return }
        hudDismiss = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hudDismiss = nil
            self.hud.orderOut(nil)
        }
        RunLoop.main.add(hudDismiss!, forMode: .common)
    }

    @objc private func showCompact() {
        window.orderOut(nil)
        showHUD()
    }

    private func installTapIfAuthorized() {
        guard AXIsProcessTrusted() else {
            removeTap()
            installFallbackMonitors()
            return
        }
        if let current = tap, !CFMachPortIsValid(current) { removeTap() }
        guard tap == nil else {
            if let tap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            removeFallbackMonitors()
            return
        }
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = app.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return app.handle(event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { installFallbackMonitors(); return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)!
        tap = created
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        removeFallbackMonitors()
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    private func installFallbackMonitors() {
        guard globalMonitor == nil && localMonitor == nil else { return }
        // This fallback keeps the already-authorized helper usable after an app
        // update changes its ad-hoc code signature. If Accessibility is trusted,
        // the CGEvent tap above is used instead and these monitors are removed.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            _ = self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    private func removeFallbackMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event) else { return false }
        return handle(ns)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard compatible,
              let press = MediaKeyPress.decode(type: event.type.rawValue, subtype: event.subtype.rawValue, data: event.data1)
        else { return false }
        guard press.shouldAct else { return true }
        guard abs(event.timestamp - lastHandledEventTimestamp) >= 0.001 else { return true }
        lastHandledEventTimestamp = event.timestamp
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAction >= 0.06, pendingActions < 8 else { return true }
        lastAction = now
        // Never make potentially blocking USB/CoreAudio calls inside the event tap.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mediaKeyCount += 1
            let fine = event.modifierFlags.contains([.shift, .option])
            self.perform(press.key, step: fine ? 0.01 : volumeStep)
        }
        return true
    }

    private func perform(_ key: MediaKey, step: Float32 = volumeStep) {
        pendingSlider.cancelForDiscreteAction()
        submit {
            switch key {
            case .up: return try self.hardware.adjust(by: step)
            case .down: return try self.hardware.adjust(by: -step)
            case .mute: return try self.hardware.toggleMute()
            }
        }
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        guard !updatingSlider, compatible else { return }
        pendingSlider.value = Float32(sender.doubleValue)
        flushSlider()
    }

    private func flushSlider() {
        guard pendingActions == 0, let level = pendingSlider.take() else { return }
        submit { try self.hardware.setVolume(to: level) }
    }

    private func submit(_ operation: @escaping () throws -> AudioSnapshot) {
        guard compatible, pendingActions < 8 else { return }
        pendingActions += 1
        audioQueue.async {
            let result = Result {
                guard !self.safetyLocked else {
                    throw G8Error.message("安全保护已锁定，请点击「错误后重新检查」")
                }
                return try operation()
            }
            if case .failure = result { self.safetyLocked = true }
            DispatchQueue.main.async {
                self.pendingActions -= 1
                switch result {
                case .success(let state):
                    self.errorLabel.stringValue = ""
                    self.render(state)
                    self.showHUD()
                case .failure(let error):
                    self.pendingSlider.cancelForDiscreteAction()
                    self.controlsLocked = true
                    self.errorLabel.stringValue = error.localizedDescription
                    self.compatible = false
                    self.render(nil)
                    self.showWindow()
                }
                self.flushSlider()
            }
        }
    }

    @objc private func retryHardware() {
        guard pendingActions == 0 else { return }
        pendingSlider.cancelForDiscreteAction()
        controlsLocked = false
        errorLabel.stringValue = ""
        audioQueue.async {
            self.safetyLocked = false
            DispatchQueue.main.async { self.refresh() }
        }
    }

    private func refresh() {
        installTapIfAuthorized()
        guard !reading, pendingActions == 0 else { return }
        reading = true
        audioQueue.async {
            let result = Result { try self.hardware.snapshot() }
            DispatchQueue.main.async {
                self.reading = false
                guard self.pendingActions == 0 else { return }
                switch result {
                case .success(let state): self.render(state)
                case .failure(let error):
                    self.errorLabel.stringValue = error.localizedDescription
                    self.render(nil)
                }
            }
        }
    }

    private func render(_ state: AudioSnapshot?) {
        if let state {
            compatible = state.compatible && !controlsLocked
            let label = "\(state.displayedVolume.percent)%\(state.muted ? " · 静音" : "")"
            updateStatusIcon(state)
            updateSlider(state)
            volumeLabel.stringValue = "G8 音量：\(label)"
            hudValue.stringValue = "G8  \(label)"
            if !hudSlider.tracking { hudSlider.doubleValue = Double(state.displayedVolume.level) }
        } else {
            compatible = false
            updateStatusIcon(nil)
            updateSlider(nil)
            volumeLabel.stringValue = "G8 未就绪"
            hudValue.stringValue = "G8 未就绪"
        }
        lowerButton.isEnabled = compatible
        raiseButton.isEnabled = compatible
        muteButton.isEnabled = compatible
        hudSlider.isEnabled = compatible
        let enabled = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        let state: String
        if controlsLocked {
            state = "安全保护已锁定 · 请重新检查"
        } else if !compatible {
            state = "当前不是 G8 兼容输出：不接管键盘"
        } else if !AXIsProcessTrusted() {
            state = "需辅助功能授权 · 备用监听收到 \(mediaKeyCount) 次，不能隐藏系统浮层"
        } else if !enabled {
            state = "已获授权，但媒体键监听未启动；请退出后重开"
        } else {
            state = "键盘监听已就绪 · 收到媒体键 \(mediaKeyCount) 次"
        }
        stateLabel.stringValue = state
        stateMenu.title = state
    }

    private func updateSlider(_ state: AudioSnapshot?) {
        updatingSlider = true
        if let state {
            if !volumeSlider.tracking { volumeSlider.doubleValue = Double(state.displayedVolume.level) }
            sliderValueLabel.stringValue = "\(state.displayedVolume.percent)%"
            volumeSlider.isEnabled = compatible
        } else {
            volumeSlider.doubleValue = 0
            sliderValueLabel.stringValue = "—"
            volumeSlider.isEnabled = false
        }
        updatingSlider = false
    }

    private func updateStatusIcon(_ state: AudioSnapshot?) {
        let symbolName: String
        let accessibilityDescription: String
        if let state {
            if state.muted {
                symbolName = "speaker.slash.fill"
                accessibilityDescription = "G8 已静音"
            } else if state.volume.level <= 0.001 {
                symbolName = "speaker.fill"
                accessibilityDescription = "G8 音量 0%"
            } else if state.volume.percent <= 33 {
                symbolName = "speaker.wave.1.fill"
                accessibilityDescription = "G8 音量 \(state.volume.percent)%"
            } else if state.volume.percent <= 66 {
                symbolName = "speaker.wave.2.fill"
                accessibilityDescription = "G8 音量 \(state.volume.percent)%"
            } else {
                symbolName = "speaker.wave.3.fill"
                accessibilityDescription = "G8 音量 \(state.volume.percent)%"
            }
        } else {
            symbolName = "speaker.slash.fill"
            accessibilityDescription = "G8 未就绪"
        }

        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.title = ""
        statusItem.button?.toolTip = accessibilityDescription
        statusItem.length = NSStatusItem.squareLength
    }

    @objc private func requestPermission() {
        guard !AXIsProcessTrusted() else { refresh(); return }
        // Only the user's explicit button press triggers a TCC authorization prompt.
        if !permissionRequested {
            permissionRequested = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func lower() { perform(.down) }
    @objc private func raiseVolume() { perform(.up) }
    @objc private func mute() { perform(.mute) }
    @objc private func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    func testUI() {
        buildMenu()
        buildWindow()
        buildHUD()
        let fixture = AudioSnapshot(device: 1, outputName: compatibleName, compatible: true,
                                    volume: StereoVolume(left: 0.27, right: 0.27), muted: false)
        render(fixture)
        let menuView = sliderItem.view!
        menuView.layoutSubtreeIfNeeded()
        precondition(sliderValueLabel.stringValue == "27%")
        precondition(hudValue.stringValue == "G8  27%")
        precondition(volumeSlider.frame.width >= 180 && sliderValueLabel.frame.width == 50)
        precondition(menuView.bounds.contains(sliderValueLabel.convert(sliderValueLabel.bounds, to: menuView)))
        precondition(menuView.bounds.contains(volumeSlider.convert(volumeSlider.bounds, to: menuView)))
        precondition(!menuView.hasAmbiguousLayout)
        precondition(hudSlider.doubleValue == Double(fixture.volume.level))
        if let view = hud.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/g8-hud-ui-test.png"))
        }
        render(AudioSnapshot(device: 1, outputName: compatibleName, compatible: true,
                             volume: fixture.volume, muted: true))
        precondition(sliderValueLabel.stringValue == "0%" && hudSlider.doubleValue == 0)
        precondition(hudValue.stringValue.contains("静音"))
        testHUDDismissal()
        render(nil)
        precondition(!volumeSlider.isEnabled && !hudSlider.isEnabled)
        print("PASS: UI geometry, percent, mute and unavailable states; no audio writes or event listeners")
    }

    private func testHUDDismissal() {
        func wait(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        }
        showCompact()
        precondition(hud.isVisible, "compact entry must show HUD")
        wait(4.3)
        precondition(!hud.isVisible, "compact entry must auto-dismiss")

        showHUD()
        wait(2)
        showHUD()
        wait(2.3)
        precondition(hud.isVisible, "repeated operation must reset dismissal")
        wait(2)
        precondition(!hud.isVisible, "HUD must dismiss after last operation")

        showCompact()
        hudSlider.withTracking {
            showHUD()
            wait(4.3)
            precondition(hudSlider.tracking && hud.isVisible, "held slider must stay visible past timeout")
        }
        precondition(!hudSlider.tracking && hud.isVisible, "release must leave HUD visible")
        precondition(hudDismiss?.isValid == true, "release must rearm dismissal")
        wait(2)
        precondition(hud.isVisible, "release must allow a fresh four seconds")
        wait(2.3)
        precondition(!hud.isVisible, "released slider must eventually dismiss")
        print("PASS: HUD compact auto-dismiss, repeated-operation reset, held tracking and release timeout")
    }
}

private func selfTest() {
    var count = 0
    func verify(_ value: Bool, _ label: String) {
        guard value else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        count += 1
    }
    func decode(_ key: UInt32, _ state: UInt32, _ repeatBit: UInt32 = 0, subtype: Int16 = 8, type: UInt = 14) -> MediaKeyPress? {
        MediaKeyPress.decode(type: type, subtype: subtype, data: Int((key << 16) | (state << 8) | repeatBit))
    }
    verify(decode(0, 10)?.key == .up, "volume up")
    verify(decode(1, 10)?.key == .down, "volume down")
    verify(decode(7, 10)?.key == .mute, "mute key is 7")
    verify(decode(2, 10) == nil, "brightness is not mute")
    verify(decode(16, 10) == nil, "play/pause passes through")
    verify(decode(0, 10, subtype: 7) == nil, "unrelated system subtype")
    verify(decode(0, 10, type: 10) == nil, "ordinary typing ignored")
    verify(decode(0, 0) == nil, "invalid key state")
    verify(decode(1, 10, 1)?.shouldAct == true, "volume repeat")
    verify(decode(7, 10, 1)?.shouldAct == false, "mute repeat ignored")
    verify(decode(7, 11)?.shouldAct == false, "key up ignored")
    let both = StereoVolume(left: 0.4, right: 0.4).adjusted(by: -0.05)
    verify(abs(both.left - 0.35) < 0.0001 && abs(both.right - 0.35) < 0.0001, "safe decrement")
    let balance = StereoVolume(left: 0.2, right: 0.4).adjusted(by: 0.05)
    verify(abs(balance.left / balance.right - 0.5) < 0.0001, "balance preserved")
    verify(StereoVolume(left: 0.98, right: 0.98).adjusted(by: 0.05).level == 1, "upper clamp")
    verify(StereoVolume(left: 0.02, right: 0.02).adjusted(by: -0.05).level == 0, "lower clamp")
    verify(StereoVolume(left: 0, right: 0).adjusted(by: 0.05).level == 0.05, "raise from zero")
    var pending = PendingSlider(value: 0.9)
    pending.cancelForDiscreteAction()
    verify(pending.take() == nil, "mute cancels stale slider value")
    pending.value = 0.1
    verify(pending.take() == 0.1 && pending.take() == nil, "new slider intent consumed once")
    final class FakeDevice: VolumeDevice {
        var left: Float32 = 0.04
        var right: Float32 = 0.04
        var muted = false
        var compatible = true
        var deviceID: AudioDeviceID = 1
        var failure = ""
        var events: [String] = []
        func snapshot() throws -> AudioSnapshot {
            if failure == "readback" && events.contains("channel1") {
                throw G8Error.message("injected readback failure")
            }
            return AudioSnapshot(device: deviceID, outputName: compatibleName, compatible: compatible,
                                 volume: StereoVolume(left: left, right: right), muted: muted)
        }
        func setMuted(_ value: Bool, device: AudioDeviceID) throws {
            events.append(value ? "mute" : "unmute")
            if failure == "mute" && value { throw G8Error.message("injected mute failure") }
            if failure != "ignored mute" { muted = value }
            if failure == "unmute jump" && !value { left = 1; right = 1 }
        }
        func setChannel(_ channel: UInt32, level: Float32, device: AudioDeviceID) throws {
            events.append("channel\(channel)")
            guard level >= 0.005 && level <= 1 else { throw G8Error.message("unsafe scalar") }
            if failure == "channel\(channel)" { throw G8Error.message("injected channel failure") }
            if failure == "route" { compatible = false }
            if failure == "device" { deviceID = 2 }
            if failure == "unexpected mute" { muted = true }
            if failure == "ignored channel" { return }
            if failure == "other channel jump" { right = 1 }
            let actual = failure == "jump" ? Float32(1) : failure == "zero" ? 0 : level
            if channel == 1 { left = actual } else { right = actual }
        }
    }
    for target: Float32 in [0, 0.001, 0.0049] {
        let device = FakeDevice()
        do {
            let after = try applySafeVolume(StereoVolume(left: target, right: target),
                                           before: device.snapshot(), device: device)
            verify(after.muted && after.displayedVolume.percent == 0, "near zero is muted")
            verify(device.events == ["mute"], "zero never writes dangerous hardware scalar")
        } catch { verify(false, "zero transaction \(error)") }
    }
    do {
        let device = FakeDevice()
        let before = try device.snapshot()
        let after = try applySafeVolume(before.volume.adjusted(by: -volumeStep), before: before, device: device)
        verify(abs(after.volume.level - 0.01) < 0.0001, "3 percent decrease")
        verify(device.events == ["channel1", "channel2"], "ordinary decrease never toggles mute")
        _ = try applySafeVolume(StereoVolume(left: 0, right: 0), before: after, device: device)
        let zero = try device.snapshot()
        device.events.removeAll()
        let raised = try applySafeVolume(zero.displayedVolume.adjusted(by: volumeStep), before: zero, device: device)
        verify(abs(raised.volume.level - 0.03) < 0.0001 && !raised.muted, "raise from muted zero to 3 percent")
        verify(device.events == ["mute", "channel1", "channel2", "unmute"], "unmute still verifies under mute")
        device.left = 1
        device.right = 1
        device.muted = true
        let failedState = try device.snapshot()
        let recovered = try applySafeVolume(failedState.muteToggleTarget, before: failedState, device: device)
        verify(recovered.volume.level == volumeStep && !recovered.muted, "unmute never restores untrusted 100 percent after error or restart")
    } catch { verify(false, "safe transaction \(error)") }
    for failure in ["mute", "ignored mute", "channel1", "channel2", "jump", "route", "unmute jump"] {
        let device = FakeDevice()
        device.failure = failure
        let target: Float32 = failure == "mute" || failure == "ignored mute" ? 0 : 0.01
        device.muted = target > 0
        do {
            _ = try applySafeVolume(StereoVolume(left: target, right: target),
                                    before: device.snapshot(), device: device)
            verify(false, "must reject \(failure)")
        } catch {
            verify(!device.events.contains("unmute") || failure == "unmute jump", "no unmute after \(failure)")
            if failure != "mute" && failure != "ignored mute" {
                verify(device.muted, "fail closed after \(failure)")
            }
            verify(device.events.last == "mute", "attempt safety mute after \(failure)")
        }
    }
    for failure in ["channel1", "channel2", "jump", "route", "device", "readback",
                    "zero", "other channel jump", "unexpected mute", "ignored channel"] {
        let device = FakeDevice()
        device.failure = failure
        do {
            _ = try applySafeVolume(StereoVolume(left: 0.01, right: 0.01),
                                    before: device.snapshot(), device: device)
            verify(false, "live adjustment must reject \(failure)")
        } catch {
            verify(device.muted && device.events.last == "mute", "live failure must mute: \(failure)")
            verify(!device.events.contains("unmute"), "live failure must never unmute: \(failure)")
            if failure != "channel2" {
                verify(!device.events.contains("channel2"), "verify first channel before second: \(failure)")
            }
        }
    }
    for start: Float32 in [0.005, 0.01, 0.03, 0.04, 0.5, 1] {
        for delta in [-volumeStep, volumeStep] {
            let device = FakeDevice()
            device.left = start
            device.right = start
            do {
                let before = try device.snapshot()
                let next = before.volume.adjusted(by: delta)
                let after = try applySafeVolume(next, before: before, device: device)
                if next.level < 0.005 {
                    verify(after.muted && device.events == ["mute"], "zero boundary only mutes")
                } else {
                    verify(!after.muted && after.volume.level == next.level, "nonzero boundary readback")
                    verify(!device.events.contains("mute") && !device.events.contains("unmute"),
                           "nonzero adjustments and upper clamp stay uninterrupted")
                }
            } catch { verify(false, "live boundary \(start) \(delta): \(error)") }
        }
    }
    do {
        let device = FakeDevice()
        let after = try applySafeVolume(StereoVolume(left: 0.01, right: 0.01),
                                        before: device.snapshot(), device: device, leaveMuted: true)
        verify(after.muted && device.events == ["mute", "channel1", "channel2"],
               "muted hardware test must never use live path")
        device.events.removeAll()
        device.muted = false
        device.left = 0.02
        device.right = 0.04
        let before = try device.snapshot()
        let balanced = try applySafeVolume(before.volume.adjusted(by: -0.01), before: before, device: device)
        verify(abs(balanced.volume.left / balanced.volume.right - 0.5) < 0.0001,
               "live writes preserve stereo balance")
        verify(device.events == ["channel1", "channel2"], "asymmetric live adjustment does not mute")
    } catch { verify(false, "muted and asymmetric transactions: \(error)") }
    for start in stride(from: Float32(0), through: 1, by: 0.001) {
        let v = StereoVolume(left: start * 0.8, right: start)
        let next = v.adjusted(by: -volumeStep)
        verify(next.left <= v.left + 0.000001 && next.right <= v.right + 0.000001,
               "decrease never increases either channel")
    }
    print("PASS: \(count) pure tests; no audio writes or global events")
}

private func testMutedHardware() throws {
    let hardware = G8Hardware()
    let original = try hardware.snapshot()
    guard original.compatible, original.muted,
          min(original.volume.left, original.volume.right) >= volumeStep else {
        throw G8Error.message("实机测试要求兼容输出已静音，原音量至少 3%；不会自动取消静音")
    }
    for level: Float32 in [0.03, 0.01, 0.005, 0, 0] {
        let before = try hardware.snapshot()
        let after = try applySafeVolume(StereoVolume(left: level, right: level),
                                        before: before, device: hardware, leaveMuted: true)
        guard after.muted else { throw G8Error.message("测试中静音状态丢失") }
        print("PASS muted target=\(level) readback=\(after.volume.left),\(after.volume.right) muted=\(after.muted)")
    }
    _ = try applySafeVolume(original.volume, before: hardware.snapshot(), device: hardware, leaveMuted: true)
    print("PASS: original scalar restored under mute; output remains muted")
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else if CommandLine.arguments.contains("--ui-self-test") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    AppDelegate().testUI()
} else if CommandLine.arguments.contains("--test-muted-hardware") {
    do { try testMutedHardware() }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--status") {
    do {
        let s = try G8Hardware().snapshot()
        print("output=\(s.outputName) compatible=\(s.compatible) left=\(s.volume.left) right=\(s.volume.right) muted=\(s.muted)")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        other.activate(options: [.activateAllWindows])
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
