import Cocoa
import ScreenCaptureKit.SCShareableContent

// macOS has some privacy restrictions. The user needs to grant certain permissions, app by app, in System Preferences > Security & Privacy
class SystemPermissions {
    static var preStartupPermissionsPassed = false
    private static var timer: DispatchSourceTimer!
    private static var timerIsFrequent = false
    // After permissions are granted at startup, we listen for `com.apple.accessibility.api`
    // on the distributed notification center to learn about revocation, instead of polling
    // every 5s. The notification name is undocumented by Apple and its firing behaviour across
    // every System Settings action (toggle off, remove from list, etc.) is not reliably
    // characterised in public sources, so we also keep a sparse 60s backstop timer below.
    // Infra requirements: NSDistributedNotificationCenter since 10.15 ignores nil-name
    // observers (we pass a name) and since macOS 15 silently fails for unsigned binaries
    // (AltTab is Developer ID signed). macOS 13+ has a known bug where `AXIsProcessTrusted`
    // can return stale values right after a toggle; we call `AccessibilityPermission.update()`
    // which re-runs the API rather than caching.
    private static let axRevokeNotificationName = "com.apple.accessibility.api"
    private static var distributedObserver: NSObjectProtocol?

    static func ensurePermissionsAreGranted() {
        timer = DispatchSource.makeTimerSource(queue: BackgroundWork.permissionsCheckOnTimerQueue.strongUnderlyingQueue)
        timer.setEventHandler(handler: checkPermissionsOnTimer)
        setImmediateTimer()
        timer.resume()
    }

    private static func startListeningForDistributedRevoke() {
        guard distributedObserver == nil else { return }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(axRevokeNotificationName),
            object: nil,
            queue: nil
        ) { _ in
            BackgroundWork.permissionsCheckOnTimerQueue.addOperation {
                if AccessibilityPermission.update() == .notGranted {
                    Logger.error { "Accessibility permission revoked (distributed notification); restarting" }
                    DispatchQueue.main.async { App.restart() }
                }
            }
        }
    }

    private static func checkPermissionsOnTimer() {
        AccessibilityPermission.update()
        let isPermissionsWindowVisible = PermissionsWindow.shared?.isVisible ?? false
        if !preStartupPermissionsPassed || isPermissionsWindowVisible {
            ScreenRecordingPermission.update()
        }
        Logger.debug { "accessibility:\(AccessibilityPermission.status) screenRecording:\(ScreenRecordingPermission.status)" }
        if !preStartupPermissionsPassed {
            checkPermissionsPreStartup()
        } else {
            checkPermissionsPostStartup()
            if isPermissionsWindowVisible && !timerIsFrequent {
                setFrequentTimer()
            } else if !isPermissionsWindowVisible && timerIsFrequent {
                setInfrequentTimer()
            }
        }
        DispatchQueue.main.async {
            Menubar.togglePermissionCallout(ScreenRecordingPermission.status != .granted)
            if PermissionsWindow.shared != nil {
                PermissionsWindow.updatePermissionViews()
            }
        }
    }

    private static func checkPermissionsPreStartup() {
        let axGranted = AccessibilityPermission.status != .notGranted
        let srOk = ScreenRecordingPermission.status != .notGranted
        if axGranted && srOk {
            DispatchQueue.main.async {
                preStartupPermissionsPassed = true
                PermissionsWindow.shared?.close()
                setInfrequentTimer()
                startListeningForDistributedRevoke()
                App.continueAppLaunchAfterPermissionsAreGranted()
            }
        } else if !axGranted {
            // macOS 13+ can return stale not-granted from the trust API even when the
            // permission is enabled in System Settings. Wait for a few timer ticks
            // (each ~5s) before showing the system dialog so the improved detect()
            // has a chance to self-correct via its real-AX-call fallback.
            AccessibilityPermission.consecutiveNotGrantedDetectionCount += 1
            let threshold = 3
            Logger.error {
                "Accessibility not granted (attempt \(AccessibilityPermission.consecutiveNotGrantedDetectionCount)/\(threshold))"
            }
            if AccessibilityPermission.consecutiveNotGrantedDetectionCount >= threshold {
                // Prompt system dialog on main thread (only works on main thread)
                DispatchQueue.main.async {
                    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary)
                }
                AccessibilityPermission.markSystemDialogShown()
            }
        }
    }

    private static func checkPermissionsPostStartup() {
        if AccessibilityPermission.status == .notGranted {
            Logger.error { "Accessibility permission revoked while AltTab was running; restarting" }
            DispatchQueue.main.async { App.restart() }
        }
    }

    // Post-startup, with the distributed-notification listener wired up, we only need a sparse
    // backstop poll. The notification's firing behaviour isn't fully characterised, so the 60s
    // timer is the recovery path for cases where it doesn't fire.
    static func setInfrequentTimer() {
        timerIsFrequent = false
        if preStartupPermissionsPassed && distributedObserver != nil {
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
            return
        }
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
    }

    static func setFrequentTimer() {
        timerIsFrequent = true
        timer.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(500))
    }

    private static func setImmediateTimer() {
        timerIsFrequent = false
        timer.schedule(deadline: .now(), repeating: .never, leeway: .never)
    }
}

class AccessibilityPermission {
    static var status = PermissionStatus.notGranted
    /// macOS 13+ has a known bug where `AXIsProcessTrustedWithOptions` can return stale
    /// values. We count consecutive detections where the API claims .notGranted while we
    /// haven't yet prompted the user. Only after this threshold do we actually show the
    /// system dialog — which gives the API time to self-correct.
    fileprivate static var consecutiveNotGrantedDetectionCount = 0
    /// Reset by `checkPermissionsPreStartup` when it shows the system dialog.
    static func markSystemDialogShown() { consecutiveNotGrantedDetectionCount = 0 }

    @discardableResult
    static func update() -> PermissionStatus {
        status = detect()
        return status
    }

    private static func detect() -> PermissionStatus {
        // Layer 1: the official API (fast, but can lie on macOS 13+)
        if AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue(): false] as CFDictionary) {
            return .granted
        }
        // Layer 2: try a real AX call. If we can read an attribute from the system-wide
        // accessibility object, the permission is genuinely granted regardless of what
        // the trust API says.
        if probeRealAccessibilityAccess() {
            return .granted
        }
        // Layer 3: legacy AXIsProcessTrusted (deprecated but more reliable on 13+)
        if AXIsProcessTrusted() {
            return .granted
        }
        return .notGranted
    }

    /// Attempt a trivial accessibility operation. Success = permission is truly granted.
    private static func probeRealAccessibilityAccess() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        if err == .success, focusedApp != nil {
            return true
        }
        // AXError.apiDisabled (-25204) or AXError.notImplemented (-25206) — definitely no access
        // any other error (including err == .cannotComplete) — could be transient,
        // treat as no access but don't cache
        return false
    }
}

class ScreenRecordingPermission {
    static var status = PermissionStatus.notGranted

    @discardableResult
    static func update() -> PermissionStatus {
        status = detect()
        return status
    }

    private static func detect() -> PermissionStatus {
        if #available(macOS 10.15, *) {
            guard !Preferences.screenRecordingPermissionSkipped else { return .skipped }
            return isGrantedOnSomeDisplay() ? .granted : .notGranted
        }
        return .granted
    }

    // workaround: public API CGPreflightScreenCaptureAccess and private API SLSRequestScreenCaptureAccess exist, but
    // their return value is not updated during the app lifetime
    // note: shows the system prompt if there's no permission
    private static func isGrantedOnSomeDisplay() -> Bool {
        if #available(macOS 12.3, *) {
            return checkWithSCShareableContent()
        } else {
            let mainDisplayID = CGMainDisplayID()
            if checkWithCGDisplayStream(mainDisplayID) {
                return true
            }
            // maybe the main screen can't produce a CGDisplayStream, but another screen can
            // a positive on any screen must mean that the permission is granted; we try on the other screens
            for screen in NSScreen.screens {
                if let id = screen.number(), id != mainDisplayID {
                    if checkWithCGDisplayStream(id) {
                        return true
                    }
                }
            }
            return false
        }
    }

    @available(macOS 12.3, *)
    private static func checkWithSCShareableContent() -> Bool {
        return runWithTimeout { completion in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { shareableContent, error in
                // this callback runs on a GCD queue, not on the thread that called getWithCompletionHandler
                if #available(macOS 14.0, *), let shareableContent, error == nil {
                    BackgroundWork.screenshotsQueue.addOperation {
                        WindowCaptureScreenshots.cachedSCWindows.withLock { $0 = shareableContent.windows }
                    }
                }
                completion(error != nil ? false : (shareableContent != nil))
            }
        }
    }

    private static func checkWithCGDisplayStream(_ id: CGDirectDisplayID) -> Bool {
        return runWithTimeout { completion in
            // this initializer can actually block for a while
            // it's undocumented but has been proven by spindumps shared by AltTab users
            let displayStream = CGDisplayStream(
                dispatchQueueDisplay: id,
                outputWidth: 1,
                outputHeight: 1,
                pixelFormat: Int32(kCVPixelFormatType_32BGRA),
                properties: nil,
                queue: .global()
            ) { _, _, _, _ in }
            completion(displayStream != nil)
        }
    }

    private static func runWithTimeout(_ block: @escaping (@escaping (Bool) -> Void) -> Void) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        BackgroundWork.permissionsSystemCallsQueue.addOperation {
            block { r in
                result = r
                semaphore.signal()
            }
        }
        let timeoutResult = semaphore.wait(timeout: .now() + 6)
        if timeoutResult == .timedOut {
            Logger.error { "Screen-recording permission call timed out after 6s" }
            return false
        }
        return result
    }
}
