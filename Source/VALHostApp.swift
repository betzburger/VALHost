import SwiftUI
import AppKit
import AVFoundation

//==============================================================================
// AppKit-backed menu-bar item. SwiftUI's MenuBarExtra does not reliably create
// a status item on this macOS, so we drive a real NSStatusItem ourselves: its
// button image is a live mini meter redrawn on a timer, and clicking it shows
// an NSPopover hosting the SwiftUI control panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var redrawTimer: Timer?
    private var mainWindow: NSWindow?

    // Computer-keyboard-as-piano state.
    private var keyMonitor: Any?
    private var keyboardBaseNote = 60                 // C4; shifted by Z / X
    private var pressedKeys: [String: Int] = [:]      // key char -> note currently held

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureMicrophoneAccess()
        setupStatusItem()
        setupComputerKeyboard()
        // Capture the main window once SwiftUI has created it and keep it alive
        // across closes, so "Open Window" can always re-show it.
        DispatchQueue.main.async { [weak self] in self?.captureMainWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        VALHostState.shared.saveLastSession()
    }

    //--------------------------------------------------------------------------
    // Microphone access. The input device ("VALHost 2ch" and any real input) is a
    // microphone as far as macOS is concerned, so without TCC permission CoreAudio
    // hands the host nothing but silence. Opening the device via JUCE does NOT
    // reliably raise the system prompt, so request it explicitly here. The engine
    // was already initialised in VALHostApp.init() — before permission existed —
    // so on a fresh grant we re-open the input to make the signal actually flow.
    private func ensureMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break   // init() already opened the input with permission present
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        VALHostEngine.sharedInstance().reopenAudioInput()
                    } else {
                        self.showMicrophoneDeniedAlert()
                    }
                }
            }
        case .denied, .restricted:
            showMicrophoneDeniedAlert()
        @unknown default:
            break
        }
    }

    private func showMicrophoneDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Kein Mikrofon-Zugriff"
        alert.informativeText = "VALHost braucht Mikrofon-Zugriff, um das Eingangssignal "
            + "(z. B. von VALHost 2ch) zu verarbeiten. Bitte unter Datenschutz & "
            + "Sicherheit > Mikrofon für VALHost aktivieren und VALHost neu starten."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Systemeinstellungen öffnen")
        alert.addButton(withTitle: "Später")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func captureMainWindow(retriesLeft: Int = 25) {
        if let w = NSApp.windows.first(where: {
            $0.styleMask.contains(.titled)
                && !($0.contentViewController is NSHostingController<MenuBarPanelView>)
        }) {
            w.isReleasedWhenClosed = false   // survive a close so we can re-show it
            mainWindow = w
            return
        }
        // The SwiftUI window may not exist yet right after launch — keep trying.
        if retriesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.captureMainWindow(retriesLeft: retriesLeft - 1)
            }
        }
    }

    //--------------------------------------------------------------------------
    // Computer keyboard as a piano (GarageBand-style layout). A/W/S/E/... play a
    // chromatic run; Z / X shift the octave down / up. Only active while VALHost
    // is the front app, and ignored while typing in a text field.
    private static let keyToSemitone: [String: Int] = [
        "a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6,
        "g": 7, "y": 8, "h": 9, "u": 10, "j": 11, "k": 12,
        "o": 13, "l": 14, "p": 15
    ]

    private func setupComputerKeyboard() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Don't steal keys while the user is typing (e.g. the plugin search field).
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText || responder is NSTextView {
            return event
        }
        // Leave shortcuts (⌘, ⌃, ⌥, fn) untouched.
        if !event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty {
            return event
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else {
            return event
        }

        // Octave shift.
        if key == "z" || key == "x" {
            if event.type == .keyDown && !event.isARepeat {
                keyboardBaseNote = key == "z" ? max(0, keyboardBaseNote - 12)
                                              : min(108, keyboardBaseNote + 12)
            }
            return nil
        }

        guard let semitone = Self.keyToSemitone[key] else {
            return event   // not a piano key — pass it on
        }

        switch event.type {
        case .keyDown:
            if event.isARepeat || pressedKeys[key] != nil { return nil }
            let note = max(0, min(127, keyboardBaseNote + semitone))
            pressedKeys[key] = note
            VALHostState.shared.activeTouches.insert(note)
            VALHostEngine.sharedInstance().sendMidiNoteOn(Int32(note), velocity: 100)
        case .keyUp:
            if let note = pressedKeys.removeValue(forKey: key) {
                VALHostState.shared.activeTouches.remove(note)
                VALHostEngine.sharedInstance().sendMidiNoteOff(Int32(note))
            }
        default:
            break
        }
        return nil
    }

    //--------------------------------------------------------------------------
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.meterImage()
            button.imagePosition = .imageOnly
            button.toolTip = "VALHost output level — click for volume & window"
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView(state: .shared,
                                       openMainWindow: { [weak self] in self?.showMainWindow() })
        )

        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.statusItem?.button?.image = Self.meterImage()
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMainWindow() {
        popover.performClose(nil)
        // Bring the app to the front. The old activate(ignoringOtherApps:) is a
        // no-op on recent macOS, so use the modern API where available.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let w = mainWindow ?? NSApp.windows.first(where: {
            $0.styleMask.contains(.titled)
                && !($0.contentViewController is NSHostingController<MenuBarPanelView>)
        }) {
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
        } else {
            // No surviving window object — ask SwiftUI to recreate it.
            VALHostState.shared.openMainWindowRequest?()
        }
    }

    //--------------------------------------------------------------------------
    // Live mini stereo meter (L / R) drawn into an NSImage for the status button.
    private static func meterImage() -> NSImage {
        let size = NSSize(width: 26, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()

        let s = VALHostState.shared
        let levels: [Float] = [s.leftPeak, s.rightPeak]
        let barW: CGFloat = 4, gap: CGFloat = 3
        let blockW = barW * CGFloat(levels.count) + gap * CGFloat(levels.count - 1)
        let x0 = (size.width - blockW) / 2

        let h = size.height - 2                 // drawable bar height
        // Zone boundaries as bar heights (same calibration as the big meter).
        let greenTop = CGFloat(MeterScale.fraction(forDb: MeterScale.yellowDb)) * h
        let yellowTop = CGFloat(MeterScale.fraction(forDb: MeterScale.redDb)) * h

        for (i, v) in levels.enumerated() {
            let x = x0 + CGFloat(i) * (barW + gap)
            let barRect = NSRect(x: x, y: 1, width: barW, height: h)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)

            // Always-visible track so the item reads as a meter even in silence.
            NSColor.gray.withAlphaComponent(0.4).setFill()
            barPath.fill()

            let fillTop = max(2, CGFloat(MeterScale.fraction(forDb: MeterScale.db(forLinear: v))) * h)

            // Clip to the rounded bar, then paint zoned bands (green / yellow /
            // red) only up to the current level — so just the top of a hot
            // signal turns yellow/red, exactly like the main meter.
            NSGraphicsContext.saveGraphicsState()
            barPath.addClip()
            if s.isMute {
                NSColor.gray.setFill()
                NSRect(x: x, y: 1, width: barW, height: fillTop).fill()
            } else {
                band(x: x, w: barW, from: 0, to: greenTop, fillTop: fillTop,
                     color: NSColor(red: 0.16, green: 0.78, blue: 0.27, alpha: 1))
                band(x: x, w: barW, from: greenTop, to: yellowTop, fillTop: fillTop,
                     color: NSColor(red: 0.95, green: 0.82, blue: 0.12, alpha: 1))
                band(x: x, w: barW, from: yellowTop, to: h, fillTop: fillTop,
                     color: NSColor(red: 0.90, green: 0.16, blue: 0.13, alpha: 1))
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        image.unlockFocus()
        image.isTemplate = false   // keep the zone colours
        return image
    }

    // Paint one zone band [lo, hi] (relative to the bar bottom at y=1), but only
    // up to `fillTop`. No-op if the level hasn't reached this band.
    private static func band(x: CGFloat, w: CGFloat, from lo: CGFloat, to hi: CGFloat,
                             fillTop: CGFloat, color: NSColor) {
        let top = min(hi, fillTop)
        guard top > lo else { return }
        color.setFill()
        NSRect(x: x, y: 1 + lo, width: w, height: top - lo).fill()
    }
}

//==============================================================================
@main
struct VALHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Initialize JUCE C++ Engine and its Cocoa wrapper
        VALHostEngine.sharedInstance().initializeEngine()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(state: .shared)
                .navigationTitle("VALHost")
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
    }
}
