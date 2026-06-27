import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

//==============================================================================
struct ScannedPlugin: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let format: String
    let isInstrument: Bool
}

//==============================================================================
class VALHostState: ObservableObject {
    @Published var cpuUsage: Float = 0.0
    @Published var statusMessage: String = "Initializing..."
    @Published var leftPeak: Float = 0.0
    @Published var rightPeak: Float = 0.0
    // Peak-hold markers: the highest recent level, frozen briefly then decaying.
    @Published var leftPeakHold: Float = 0.0
    @Published var rightPeakHold: Float = 0.0
    
    // Mixer State
    @Published var volume: Double = 1.0
    @Published var isMute: Bool = false

    // Slot Names
    @Published var instrumentName: String = "Select Instrument..."
    @Published var effectNames: [String] = Array(repeating: "Select Effect...", count: 4)
    @Published var isInstrumentLoaded: Bool = false
    @Published var isEffectLoaded: [Bool] = Array(repeating: false, count: 4)
    // Per-slot bypass, indexed by slot (0 = instrument, 1-4 = effects).
    @Published var isBypassed: [Bool] = Array(repeating: false, count: 5)
    @Published var selectedSlot: Int? = 0
    @Published var selectedPluginId: UUID? = nil

    // Plugin List
    @Published var plugins: [ScannedPlugin] = []
    @Published var instruments: [ScannedPlugin] = []
    @Published var effects: [ScannedPlugin] = []
    @Published var isScanning = false
    @Published var searchText = ""

    // MIDI Touch state
    @Published var activeTouches = Set<Int>()

    // Transient status messages (Save/Load/errors) are held visible for a few
    // seconds so the 30 FPS level-poll does not immediately overwrite them with
    // the idle "ready" message.
    private var statusHoldUntil: Date = .distantPast

    // Peak-hold ballistics: a new peak freezes the marker for `peakHoldTime`,
    // after which it falls back at `peakDecayDbPerSec` until it meets the signal.
    private let peakHoldTime: TimeInterval = 1.0
    private let peakDecayDbPerSec: Float = 20
    private var leftHoldUntil: Date = .distantPast
    private var rightHoldUntil: Date = .distantPast
    private var lastPeakUpdate: Date = .distantPast

    private var pollTimer: Timer?

    // Single shared instance: the SwiftUI views and the AppKit status-bar item
    // all observe the same state and the same polling.
    static let shared = VALHostState()

    // Set by ContentView; lets the AppKit menu-bar item recreate the main window
    // via SwiftUI's openWindow when no window object survives a close.
    var openMainWindowRequest: (() -> Void)?

    init() {
        // Own the 30 FPS level/CPU polling here (rather than in a view) so the
        // menu-bar meter keeps updating even when the main window is closed.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pollLevelsAndCpu()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func flashStatus(_ message: String, seconds: TimeInterval = 4) {
        statusMessage = message
        statusHoldUntil = Date().addingTimeInterval(seconds)
    }

    func refreshPlugins() {
        let names = VALHostEngine.sharedInstance().getScannedPluginNames() ?? []
        let formats = VALHostEngine.sharedInstance().getScannedPluginFormats() ?? []
        let instrumentsList = VALHostEngine.sharedInstance().getScannedPluginIsInstrument() ?? []
        
        var temp: [ScannedPlugin] = []
        for i in 0..<min(names.count, formats.count) {
            let isInst = i < instrumentsList.count ? instrumentsList[i].boolValue : false
            temp.append(ScannedPlugin(name: names[i], format: formats[i], isInstrument: isInst))
        }
        self.plugins = temp
        self.instruments = temp.filter { $0.isInstrument }
        self.effects = temp.filter { !$0.isInstrument }
        self.selectedPluginId = nil
    }

    func refreshSlots() {
        self.instrumentName = VALHostEngine.sharedInstance().getPluginName(atSlot: 0) ?? "Select Instrument..."
        self.isInstrumentLoaded = VALHostEngine.sharedInstance().isPluginLoaded(atSlot: 0)

        var tempNames: [String] = []
        var tempLoaded: [Bool] = []
        for i in 0..<4 {
            let slot = i + 1
            let name = VALHostEngine.sharedInstance().getPluginName(atSlot: Int32(slot)) ?? "Select Effect..."
            tempNames.append(name)
            tempLoaded.append(VALHostEngine.sharedInstance().isPluginLoaded(atSlot: Int32(slot)))
        }
        self.effectNames = tempNames
        self.isEffectLoaded = tempLoaded

        for i in 0..<5 {
            self.isBypassed[i] = VALHostEngine.sharedInstance().isBypassed(atSlot: Int32(i))
        }

        self.volume = Double(VALHostEngine.sharedInstance().getVolume())
        self.isMute = VALHostEngine.sharedInstance().getMute()
    }

    func loadPlugin(slot: Int, name: String) {
        if let idx = plugins.firstIndex(where: { $0.name == name }) {
            var err: NSString?
            let success = VALHostEngine.sharedInstance().loadPlugin(atSlot: Int32(slot), pluginIndex: Int32(idx), error: &err)
            if !success {
                self.flashStatus("Error loading plugin: \(err ?? "Unknown error")")
            }
            refreshSlots()
            saveLastSession()
        }
    }

    // Toggle bypass for a slot and persist it.
    func toggleBypass(slot: Int) {
        guard slot >= 0 && slot < isBypassed.count else { return }
        isBypassed[slot].toggle()
        VALHostEngine.sharedInstance().setBypass(atSlot: Int32(slot), bypassed: isBypassed[slot])
        saveLastSession()
    }

    // MIDI panic: release all (stuck/sustained) notes on every plugin.
    func panic() {
        VALHostEngine.sharedInstance().sendAllNotesOff()
        activeTouches.removeAll()
    }

    // MARK: - Auto-recall (restore the last session on next launch)
    private var lastSessionPath: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/VALHost"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/last_session.valhost"
    }

    func saveLastSession() {
        _ = VALHostEngine.sharedInstance().saveSession(toFile: lastSessionPath)
    }

    func loadLastSession() {
        guard FileManager.default.fileExists(atPath: lastSessionPath) else { return }
        var err: NSString?
        _ = VALHostEngine.sharedInstance().loadSession(fromFile: lastSessionPath, error: &err)
        refreshSlots()
    }

    func triggerScan() {
        self.isScanning = true
        self.statusMessage = "Scanning plugins..."
        
        VALHostEngine.sharedInstance().scanPlugins(progress: { [weak self] progressMsg in
            DispatchQueue.main.async {
                if let msg = progressMsg {
                    self?.statusMessage = "Scanning: \(msg)"
                }
            }
        }, completion: { [weak self] in
            DispatchQueue.main.async {
                self?.isScanning = false
                self?.refreshPlugins()
                if let total = self?.plugins.count {
                    self?.flashStatus("Scan complete. \(total) plug-ins found.")
                }
            }
        })
    }

    func pollLevelsAndCpu() {
        self.cpuUsage = VALHostEngine.sharedInstance().getCpuUsage()
        self.leftPeak = VALHostEngine.sharedInstance().getLeftLevel()
        self.rightPeak = VALHostEngine.sharedInstance().getRightLevel()

        // Mirror volume/mute changes that arrived from outside the app — e.g. the
        // macOS volume keys acting on VALDriver — so the fader and MUTE button
        // follow. The epsilon guard keeps a live drag from fighting the poll.
        let extVolume = Double(VALHostEngine.sharedInstance().getVolume())
        if abs(extVolume - self.volume) > 0.0005 {
            self.volume = extVolume
        }
        let extMute = VALHostEngine.sharedInstance().getMute()
        if extMute != self.isMute {
            self.isMute = extMute
        }

        updatePeakHolds()

        if !self.isScanning && Date() >= self.statusHoldUntil {
            self.statusMessage = "\(self.plugins.count) plug-ins scanned and ready."
        }
    }

    // Advance both peak-hold markers using real elapsed time, so the fall-back
    // speed is independent of frame jitter.
    private func updatePeakHolds() {
        let now = Date()
        let dt = lastPeakUpdate == .distantPast
            ? 0 : Float(now.timeIntervalSince(lastPeakUpdate))
        lastPeakUpdate = now
        (leftPeakHold, leftHoldUntil) = steppedHold(current: leftPeak, hold: leftPeakHold, holdUntil: leftHoldUntil, now: now, dt: dt)
        (rightPeakHold, rightHoldUntil) = steppedHold(current: rightPeak, hold: rightPeakHold, holdUntil: rightHoldUntil, now: now, dt: dt)
    }

    private func steppedHold(current: Float, hold: Float, holdUntil: Date, now: Date, dt: Float) -> (Float, Date) {
        if current >= hold {
            // New (or matched) peak — freeze the marker here.
            return (current, now.addingTimeInterval(peakHoldTime))
        }
        if now < holdUntil {
            return (hold, holdUntil)          // still within the hold window
        }
        // Hold expired: decay in dB, but never below the live signal.
        let decayedDb = MeterScale.db(forLinear: hold) - peakDecayDbPerSec * dt
        return (max(current, powf(10, decayedDb / 20)), holdUntil)
    }
}

//==============================================================================
// Shared, calibrated dBFS scale for the output meters.
enum MeterScale {
    static let minDb: Float = -60   // bottom of the meter
    static let maxDb: Float = 6     // top — headroom above 0 dBFS so "over" is visible
    static let yellowDb: Float = -6  // green -> yellow (approaching clipping)
    static let redDb: Float = 0     // yellow -> red (0 dBFS = clipping / over)
    static let marks: [Float] = [0, -6, -12, -18, -24, -30, -36, -42, -48, -54]

    static func fraction(forDb db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - minDb) / (maxDb - minDb))))
    }

    static func db(forLinear v: Float) -> Float {
        v <= 0.0000001 ? -120 : 20 * log10(v)
    }

    static func color(forDb db: Float) -> Color {
        if db >= redDb { return Color(red: 0.90, green: 0.16, blue: 0.13) }
        if db >= yellowDb { return Color(red: 0.95, green: 0.82, blue: 0.12) }
        return Color(red: 0.16, green: 0.78, blue: 0.27)
    }
}

//==============================================================================
// A single channel bar: fills left-to-right on the dBFS scale, coloured by
// fixed zones (green / yellow near clipping / red at and above 0 dBFS).
struct HorizontalLevelMeter: View {
    var val: Float
    var peakHold: Float = 0

    private var zonedGradient: LinearGradient {
        let y = MeterScale.fraction(forDb: MeterScale.yellowDb)
        let r = MeterScale.fraction(forDb: MeterScale.redDb)
        let green = Color(red: 0.16, green: 0.78, blue: 0.27)
        let yellow = Color(red: 0.95, green: 0.82, blue: 0.12)
        let red = Color(red: 0.90, green: 0.16, blue: 0.13)
        return LinearGradient(stops: [
            .init(color: green, location: 0),
            .init(color: green, location: y - 0.001),
            .init(color: yellow, location: y),
            .init(color: yellow, location: r - 0.001),
            .init(color: red, location: r),
            .init(color: red, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fillW = MeterScale.fraction(forDb: MeterScale.db(forLinear: val)) * width
            let holdDb = MeterScale.db(forLinear: peakHold)
            let holdX = MeterScale.fraction(forDb: holdDb) * width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.55))

                // Show the zoned ladder only up to the current level.
                zonedGradient
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle().frame(width: max(0, fillW))
                            Spacer(minLength: 0)
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 2))

                // Peak-hold marker: a thin line at the held level, coloured by zone.
                if holdDb > MeterScale.minDb {
                    Rectangle()
                        .fill(MeterScale.color(forDb: holdDb))
                        .frame(width: 2)
                        .offset(x: min(max(0, holdX - 1), width - 2))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

//==============================================================================
// Stereo output meter: two horizontal zoned bars (L over R) and a calibrated
// dBFS scale running the full width beneath them. Going wide gives each bar a
// long travel, so small level changes are easy to read.
struct HorizontalOutputMeterView: View {
    var leftPeak: Float
    var rightPeak: Float
    var leftHold: Float = 0
    var rightHold: Float = 0

    private let labelWidth: CGFloat = 12
    private let labelGap: CGFloat = 6
    private let barHeight: CGFloat = 12

    var body: some View {
        VStack(spacing: 5) {
            channelRow(label: "L", value: leftPeak, hold: leftHold)
            channelRow(label: "R", value: rightPeak, hold: rightHold)

            // Calibrated dBFS scale, aligned to the bars (offset past the labels).
            HStack(spacing: labelGap) {
                Spacer().frame(width: labelWidth)
                GeometryReader { geo in
                    ZStack {
                        ForEach(MeterScale.marks, id: \.self) { mark in
                            VStack(spacing: 1) {
                                Rectangle()
                                    .fill(mark >= 0 ? Color.red.opacity(0.7) : Color.gray.opacity(0.45))
                                    .frame(width: 1, height: 4)
                                Text(String(format: "%.0f", mark))
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundColor(mark >= 0 ? .red.opacity(0.8) : .gray.opacity(0.6))
                            }
                            .position(x: MeterScale.fraction(forDb: mark) * geo.size.width, y: 8)
                        }
                    }
                }
                .frame(height: 16)
            }
        }
    }

    private func channelRow(label: String, value: Float, hold: Float) -> some View {
        HStack(spacing: labelGap) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.gray.opacity(0.7))
                .frame(width: labelWidth)
            HorizontalLevelMeter(val: value, peakHold: hold)
                .frame(height: barHeight)
        }
    }
}

//==============================================================================
struct PianoKeyView: View {
    let note: Int
    let isBlack: Bool
    @Binding var activeTouches: Set<Int>

    var body: some View {
        let isPressed = activeTouches.contains(note)
        
        if isBlack {
            // Black Key Styling (Premium 3D Look)
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    isPressed ?
                    LinearGradient(colors: [Color.teal, Color.teal.opacity(0.7)], startPoint: .top, endPoint: .bottom) :
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.black, lineWidth: 1)
                )
                .overlay(
                    // Subtle bottom edge highlight to simulate 3D bevel
                    VStack {
                        Spacer()
                        Rectangle()
                            .fill(Color(white: 0.4).opacity(isPressed ? 0.0 : 0.5))
                            .frame(height: 2)
                    }
                    .padding(.bottom, 1)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 2, x: 1, y: 2)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPressed {
                                activeTouches.insert(note)
                                VALHostEngine.sharedInstance().sendMidiNoteOn(Int32(note), velocity: 100)
                            }
                        }
                        .onEnded { _ in
                            activeTouches.remove(note)
                            VALHostEngine.sharedInstance().sendMidiNoteOff(Int32(note))
                        }
                )
        } else {
            // White Key Styling (Premium 3D Look)
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    isPressed ?
                    LinearGradient(colors: [Color.teal.opacity(0.4), Color.teal.opacity(0.2)], startPoint: .top, endPoint: .bottom) :
                    LinearGradient(colors: [Color.white, Color(white: 0.94)], startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.35), lineWidth: 0.7)
                )
                .overlay(
                    // Inner shadow / bottom reflection to simulate key thickness
                    VStack {
                        Spacer()
                        Rectangle()
                            .fill(Color.gray.opacity(0.15))
                            .frame(height: 3)
                    }
                )
                .shadow(color: Color.black.opacity(0.1), radius: 1, x: 0, y: 1)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isPressed {
                                activeTouches.insert(note)
                                VALHostEngine.sharedInstance().sendMidiNoteOn(Int32(note), velocity: 100)
                            }
                        }
                        .onEnded { _ in
                            activeTouches.remove(note)
                            VALHostEngine.sharedInstance().sendMidiNoteOff(Int32(note))
                        }
                )
        }
    }
}

//==============================================================================
//==============================================================================
struct SlotRow: View {
    let slotIndex: Int
    let label: String
    let pluginName: String
    let isLoaded: Bool
    @ObservedObject var state: VALHostState
    
    var body: some View {
        let isSelected = state.selectedSlot == slotIndex
        let displayPluginName = isLoaded ? pluginName : "<empty>"
        
        HStack(spacing: 6) {
            // Clickable main body
            Button(action: {
                state.selectedSlot = slotIndex
            }) {
                HStack(spacing: 8) {
                    // Prefix tag
                    Text(label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.teal)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.teal.opacity(0.15)))
                    
                    Text(displayPluginName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isLoaded ? .white : .gray)
                        .lineLimit(1)
                    
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.teal.opacity(0.12) : Color.gray.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.teal : Color.gray.opacity(0.15), lineWidth: isSelected ? 1.5 : 1.0)
                )
            }
            .buttonStyle(.plain)

            // Bypass button — passes a loaded effect through unprocessed (keeps it
            // and its settings) for quick A/B; on the instrument slot it silences it.
            Button(action: {
                state.toggleBypass(slot: slotIndex)
            }) {
                Text("B")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 32)
            }
            .buttonStyle(.bordered)
            .tint(state.isBypassed[slotIndex] ? .orange : .gray)
            .disabled(!isLoaded)
            .help("Bypass this slot")

            // Edit button — opens the plugin's editor (the engine automatically uses
            // a safe generic editor for plugins whose native view would crash)
            Button(action: {
                VALHostEngine.sharedInstance().showPluginEditor(atSlot: Int32(slotIndex))
            }) {
                Text("E")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 32)
            }
            .buttonStyle(.bordered)
            .disabled(!isLoaded)
            .help("Open the plugin editor")

            // Unload button
            Button(action: {
                VALHostEngine.sharedInstance().unloadPlugin(atSlot: Int32(slotIndex))
                state.refreshSlots()
                state.saveLastSession()
            }) {
                Text("X")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 32)
            }
            .buttonStyle(.bordered)
            .disabled(!isLoaded)
        }
    }
}

//==============================================================================
struct CustomHorizontalFader: View {
    @Binding var value: Double // Range 0.0 to 1.25
    let onChanged: (Double) -> Void

    // Piecewise-linear dB scale defined by (position, dB) anchors, ascending.
    // Position 0 == true silence (-inf dB); each segment is linear in dB.
    //   left   : -inf .. -30 dB -> first 0.2 of the travel
    //   middle : -30 .. -6 dB   -> next 0.3
    //   right  : -6 .. +2 dB    -> right half, for fine control near unity gain
    private static let anchors: [(p: CGFloat, db: Double)] = [
        (0.0, -96),
        (0.2, -30),
        (0.5, -6),
        (1.0,  2),
    ]
    private static var minDb: Double { anchors.first!.db }
    private static var maxDb: Double { anchors.last!.db }
    private static var maxGain: Double { pow(10.0, maxDb / 20.0) }

    // dB tick marks drawn beneath the track.
    private static let ticks: [(db: Double, label: String)] = [
        (-96, "-∞"), (-48, "-48"), (-30, "-30"), (-24, "-24"), (-18, "-18"),
        (-12, "-12"), (-6, "-6"), (-3, "-3"), (0, "0"), (2, "+2"),
    ]

    // dB -> normalized fader position (0...1).
    private static func positionForDb(_ db: Double) -> CGFloat {
        if db <= minDb { return 0 }
        if db >= maxDb { return 1 }
        for i in 0..<(anchors.count - 1) {
            let lo = anchors[i], hi = anchors[i + 1]
            if db <= hi.db {
                let t = (db - lo.db) / (hi.db - lo.db)
                return lo.p + CGFloat(t) * (hi.p - lo.p)
            }
        }
        return 1
    }

    // normalized fader position (0...1) -> dB.
    private static func dbForPosition(_ p: CGFloat) -> Double {
        if p <= 0 { return minDb }
        if p >= 1 { return maxDb }
        for i in 0..<(anchors.count - 1) {
            let lo = anchors[i], hi = anchors[i + 1]
            if p <= hi.p {
                let t = Double((p - lo.p) / (hi.p - lo.p))
                return lo.db + t * (hi.db - lo.db)
            }
        }
        return maxDb
    }

    // Gain (linear) -> normalized fader position (0...1).
    private static func positionForGain(_ gain: Double) -> CGFloat {
        if gain <= 0 { return 0 }
        return positionForDb(20.0 * log10(gain))
    }

    // Normalized fader position (0...1) -> gain (linear).
    private static func gainForPosition(_ p: CGFloat) -> Double {
        if p <= 0 { return 0 }
        return pow(10.0, dbForPosition(p) / 20.0)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            // Handle X offset (logarithmic / dB-based position, left = silence).
            let normVal = Self.positionForGain(value)
            let handleWidth: CGFloat = 20
            let trackWidth = max(0, width - handleWidth)
            let xOffset = trackWidth * normVal

            VStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    // Fader track background
                    Capsule()
                        .fill(Color(white: 0.12))
                        .frame(height: 8)
                        .overlay(Capsule().stroke(Color.black.opacity(0.5), lineWidth: 1))
                        .padding(.horizontal, handleWidth / 2)

                    // Track highlight (from left up to current value)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.teal.opacity(0.6), Color.teal],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, trackWidth * normVal), height: 6)
                        .padding(.leading, handleWidth / 2)

                    // Fader Handle (Knob)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [Color(white: 0.45), Color(white: 0.28), Color(white: 0.18)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.black, lineWidth: 1.2)
                        )
                        .overlay(
                            // Center vertical stripe on handle
                            Rectangle()
                                .fill(Color.teal)
                                .frame(width: 2)
                        )
                        .shadow(color: Color.black.opacity(0.6), radius: 2, x: 0, y: 1.5)
                        .frame(width: handleWidth, height: 26)
                        .offset(x: xOffset)
                }
                .frame(height: 26)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let dragX = gesture.location.x - (handleWidth / 2)
                            let clampedX = max(0, min(dragX, trackWidth))
                            let percent = trackWidth > 0 ? (clampedX / trackWidth) : 0.0
                            let val = Self.gainForPosition(percent)
                            self.value = val
                            onChanged(val)
                        }
                )

                // dB scale ticks beneath the track
                ZStack {
                    ForEach(Self.ticks, id: \.db) { tick in
                        VStack(spacing: 1) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.5))
                                .frame(width: 1, height: 4)
                            Text(tick.label)
                                .font(.system(size: 7, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                        .position(x: handleWidth / 2 + trackWidth * Self.positionForDb(tick.db), y: 8)
                    }
                }
                .frame(height: 16)
            }
        }
    }
}

//==============================================================================
struct TopBarView: View {
    @ObservedObject var state: VALHostState
    let onLoad: () -> Void
    let onSave: () -> Void
    let onHelp: () -> Void
    var body: some View {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        
        return HStack {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("VALHost")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.teal)
                
                Text("v\(appVersion) (Build \(appBuild))  •  © Peter Betz  •  Powered by JUCE")
                    .font(.system(size: 9))
                    .foregroundColor(.gray.opacity(0.6))
            }
            
            Spacer()
            
            Button("Audio Settings") {
                VALHostEngine.sharedInstance().showAudioSettingsDialog()
            }
            .buttonStyle(.bordered)
            
            Button("Load") {
                onLoad()
            }
            .buttonStyle(.bordered)

            Button("Save") {
                onSave()
            }
            .buttonStyle(.bordered)

            Button(action: onHelp) {
                Label("Help", systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .tint(.teal)
            .help("Open the VALHost user guide")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

//==============================================================================
struct MixerStripView: View {
    @ObservedObject var state: VALHostState

    var body: some View {
        VStack(spacing: 12) {
            Text("CHANNEL STRIP")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.teal)
                .padding(.top, 4)

            // Slots (Instrument + Effects)
            VStack(spacing: 8) {
                // Instrument Slot (Index 0)
                SlotRow(
                    slotIndex: 0,
                    label: "INST",
                    pluginName: state.instrumentName,
                    isLoaded: state.isInstrumentLoaded,
                    state: state
                )
                
                Divider()
                    .background(Color.gray.opacity(0.15))
                    .padding(.vertical, 2)
                
                Text("EFFECTS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                
                // Effect Slots (Index 1 to 4)
                ForEach(0..<4) { i in
                    SlotRow(
                        slotIndex: i + 1,
                        label: "FX \(i + 1)",
                        pluginName: state.effectNames[i],
                        isLoaded: state.isEffectLoaded[i],
                        state: state
                    )
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 12)

            // Mute + MIDI Panic
            HStack(spacing: 8) {
                Button(action: {
                    state.isMute.toggle()
                    VALHostEngine.sharedInstance().setMute(state.isMute)
                    state.saveLastSession()
                }) {
                    Text("MUTE")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
                .tint(state.isMute ? .red : .gray)
                .buttonStyle(.borderedProminent)

                Button(action: {
                    state.panic()
                }) {
                    Text("PANIC")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 84)
                        .frame(height: 26)
                }
                .tint(.orange)
                .buttonStyle(.bordered)
                .help("MIDI panic — stop all stuck/hanging notes")
            }
            .padding(.horizontal, 8)

            // Volume Fader — full-width horizontal travel for precise setting
            VStack(spacing: 6) {
                HStack {
                    Text("VOLUME")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.gray)
                    Spacer()
                    Text(faderValueToDb(state.volume) <= -96.0
                         ? "-∞ dB"
                         : String(format: "%.1f dB", faderValueToDb(state.volume)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.teal)
                }
                CustomHorizontalFader(value: $state.volume) { val in
                    VALHostEngine.sharedInstance().setVolume(Float(val))
                }
                .frame(height: 48)
            }
            .padding(.horizontal, 16)

            // Peak Level Meter — full-width dBFS metering with calibrated scale
            VStack(spacing: 6) {
                HStack {
                    Text("OUTPUT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.gray)
                    Spacer()
                }
                HorizontalOutputMeterView(leftPeak: state.leftPeak, rightPeak: state.rightPeak,
                                          leftHold: state.leftPeakHold, rightHold: state.rightPeakHold)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .frame(width: 420)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15), lineWidth: 1.5))
    }
    
    // Helper to translate the linear fader gain to a decibel representation.
    // A gain of 0 (the very bottom of the fader) is true silence -> -inf dB.
    private func faderValueToDb(_ val: Double) -> Double {
        if val <= 0.0 { return -.infinity }
        return 20.0 * log10(val)
    }
}

//==============================================================================
struct SidebarView: View {
    @ObservedObject var state: VALHostState

    private var sidebarHint: String {
        guard let slot = state.selectedSlot else {
            return "Select a slot, then double-click a plugin to load it"
        }
        return slot == 0
            ? "Double-click to load an instrument into the INST slot"
            : "Double-click to load an effect into the selected FX slot"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("SCANNED PLUGINS")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.teal)
            
            TextField("Search plug-ins...", text: $state.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 4)

            Text(sidebarHint)
                .font(.system(size: 10))
                .foregroundColor(.gray.opacity(0.7))
                .padding(.bottom, 2)

            List {
                // Show only plugins that fit the selected slot: the Instrument slot
                // (0) lists instruments, the FX slots list effects.
                let base: [ScannedPlugin] = {
                    guard let slot = state.selectedSlot else { return state.plugins }
                    return slot == 0 ? state.instruments : state.effects
                }()
                let filtered = base.filter {
                    state.searchText.isEmpty ? true : (
                        $0.name.localizedCaseInsensitiveContains(state.searchText) ||
                        $0.format.localizedCaseInsensitiveContains(state.searchText)
                    )
                }
                ForEach(filtered) { plugin in
                    let isPluginSelected = state.selectedPluginId == plugin.id
                    HStack {
                        Text(plugin.name)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                        Spacer()
                        Text(plugin.format)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.teal.opacity(0.8))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.teal.opacity(0.1)))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isPluginSelected ? Color.teal.opacity(0.15) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isPluginSelected ? Color.teal : Color.clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if let slot = state.selectedSlot {
                            if slot == 0 && !plugin.isInstrument {
                                state.statusMessage = "Selected slot (Instrument) only accepts Instruments."
                            } else if slot > 0 && plugin.isInstrument {
                                state.statusMessage = "Selected slot (Effects) only accepts Effect plugins."
                            } else {
                                state.loadPlugin(slot: slot, name: plugin.name)
                                state.statusMessage = "Loaded \(plugin.name) into selected slot."
                                state.selectedPluginId = nil
                            }
                        } else {
                            state.statusMessage = "Please select an Instrument or Effect slot first."
                        }
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        state.selectedPluginId = plugin.id
                    })
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                }
            }
            .cornerRadius(4)
            .listStyle(.inset)
            .frame(height: 360)

            Button(action: {
                state.triggerScan()
            }) {
                Text(state.isScanning ? "Scanning..." : "Scan Plugins")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isScanning)
            .tint(.teal)
        }
        .padding(.vertical, 8)
    }
}

//==============================================================================
struct PianoKeyboardView: View {
    @ObservedObject var state: VALHostState

    var body: some View {
        ZStack(alignment: .topLeading) {
            // White Keys: 4 Octaves (C3 to C7) -> 29 white keys
            let whiteNotes = [
                48, 50, 52, 53, 55, 57, 59, // Octave 3
                60, 62, 64, 65, 67, 69, 71, // Octave 4
                72, 74, 76, 77, 79, 81, 83, // Octave 5
                84, 86, 88, 89, 91, 93, 95, // Octave 6
                96                          // C7
            ]
            
            HStack(spacing: 0) {
                ForEach(whiteNotes, id: \.self) { note in
                    PianoKeyView(note: note, isBlack: false, activeTouches: $state.activeTouches)
                }
            }
            .frame(width: 828, height: 75)

            // Black Keys: 4 Octaves -> 20 black keys
            let keyWidth: CGFloat = 828.0 / 29.0
            let blackKeyWidth: CGFloat = keyWidth * 0.6
            
            // Map of (note, divider index)
            let blackNotes: [(note: Int, dividerIndex: CGFloat)] = [
                (49, 1), (51, 2), (54, 4), (56, 5), (58, 6),       // Octave 3
                (61, 8), (63, 9), (66, 11), (68, 12), (70, 13),    // Octave 4
                (73, 15), (75, 16), (78, 18), (80, 19), (82, 20),  // Octave 5
                (85, 22), (87, 23), (90, 25), (92, 26), (94, 27)   // Octave 6
            ]

            ForEach(blackNotes, id: \.note) { item in
                PianoKeyView(note: item.note, isBlack: true, activeTouches: $state.activeTouches)
                    .frame(width: blackKeyWidth, height: 48)
                    .offset(x: item.dividerIndex * keyWidth - blackKeyWidth/2)
            }
        }
        .frame(width: 828, height: 75)
        .background(Color.black)
        .cornerRadius(4)
        .padding(.horizontal, 16)
    }
}

//==============================================================================
struct StatusBarView: View {
    @ObservedObject var state: VALHostState

    var body: some View {
        HStack {
            Text(state.statusMessage)
                .font(.system(size: 11))
                .foregroundColor(.gray)
            Spacer()
            Text("CPU: \(state.cpuUsage, specifier: "%.1f")%")
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }
}

//==============================================================================
// MARK: - Menu Bar (status item)
//==============================================================================

// Drop-down panel shown by the menu-bar status item (inside an NSPopover): live
// meter, the same volume fader as the main strip, a mute toggle and a button
// that brings the full window forward. `openMainWindow` is supplied by the
// AppDelegate because @Environment(\.openWindow) is not wired up inside a
// stand-alone NSHostingController.
struct MenuBarPanelView: View {
    @ObservedObject var state: VALHostState
    var openMainWindow: () -> Void = {}

    private var volumeDbText: String {
        let db = state.volume <= 0.0 ? -Double.infinity : 20.0 * log10(state.volume)
        return db <= -96.0 ? "-∞ dB" : String(format: "%.1f dB", db)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("VALHost")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.teal)
                Spacer()
                Text(volumeDbText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.teal)
            }

            HorizontalOutputMeterView(leftPeak: state.leftPeak, rightPeak: state.rightPeak,
                                      leftHold: state.leftPeakHold, rightHold: state.rightPeakHold)

            CustomHorizontalFader(value: $state.volume) { val in
                VALHostEngine.sharedInstance().setVolume(Float(val))
            }
            .frame(height: 48)

            HStack(spacing: 8) {
                Button(action: {
                    state.isMute.toggle()
                    VALHostEngine.sharedInstance().setMute(state.isMute)
                    state.saveLastSession()
                }) {
                    Text(state.isMute ? "Unmute" : "Mute")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .tint(state.isMute ? .red : .gray)
                .buttonStyle(.borderedProminent)

                Button(action: {
                    openMainWindow()
                }) {
                    Label("Open Window", systemImage: "macwindow")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .buttonStyle(.bordered)
                .tint(.teal)
            }

            Divider()

            Button("Quit VALHost") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.gray)
        }
        .padding(16)
        .frame(width: 300)
    }
}

//==============================================================================
struct ContentView: View {
    @ObservedObject var state: VALHostState
    @State private var showHelp = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            TopBarView(state: state,
                       onLoad: loadSession,
                       onSave: saveSession,
                       onHelp: { showHelp = true })

            Divider()
                .background(Color.gray.opacity(0.2))

            // Middle Content
            HStack(spacing: 16) {
                MixerStripView(state: state)
                SidebarView(state: state)
            }
            .padding(.horizontal, 16)

            PianoKeyboardView(state: state)

            StatusBarView(state: state)
        }
        .frame(minWidth: 860, maxWidth: 860, minHeight: 740, maxHeight: 740)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color(white: 0.08), Color(white: 0.12)]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onAppear {
            state.refreshPlugins()
            state.refreshSlots()
            state.loadLastSession()   // restore where you left off
            state.openMainWindowRequest = { openWindow(id: "main") }
        }
        .sheet(isPresented: $showHelp) {
            HelpView(isPresented: $showHelp)
        }
    }

    //==========================================================================
    private func saveSession() {
        let chooser = NSSavePanel()
        if let valhostType = UTType(filenameExtension: "valhost") {
            chooser.allowedContentTypes = [valhostType]
        }
        chooser.nameFieldStringValue = "session.valhost"
        chooser.begin { result in
            if result == .OK, let url = chooser.url {
                var path = url.path
                if !path.hasSuffix(".valhost") {
                    path += ".valhost"
                }
                if VALHostEngine.sharedInstance().saveSession(toFile: path) {
                    state.flashStatus("Saved session to \(url.lastPathComponent)")
                } else {
                    state.flashStatus("Failed to save session")
                }
            }
        }
    }

    private func loadSession() {
        let chooser = NSOpenPanel()
        if let valhostType = UTType(filenameExtension: "valhost") {
            chooser.allowedContentTypes = [valhostType]
        }
        chooser.allowsMultipleSelection = false
        chooser.begin { result in
            if result == .OK, let url = chooser.url {
                var err: NSString?
                if VALHostEngine.sharedInstance().loadSession(fromFile: url.path, error: &err) {
                    state.flashStatus("Loaded session from \(url.lastPathComponent)")
                    state.refreshSlots()
                } else {
                    state.flashStatus("Error loading session: \(err ?? "Unknown error")")
                }
            }
        }
    }
}

//==============================================================================
// MARK: - Help / User Guide
//==============================================================================
struct HelpView: View {
    @Binding var isPresented: Bool

    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.teal)
                Text("VALHost — User Guide")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.teal)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(white: 0.10))

            Divider().background(Color.gray.opacity(0.3))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {

                    para("VALHost is a lightweight audio plug-in host for macOS. It builds a single stereo channel strip: one instrument slot followed by four effect slots, a level fader with metering, and a stereo output. You can use it to play software instruments from a MIDI keyboard, or to run live or system audio through a chain of effect plug-ins.")

                    // 1 ---------------------------------------------------------
                    section("1.  How Audio Flows Through VALHost")
                    para("The signal path is a simple, fixed left-to-right chain:")
                    mono("[ Instrument  OR  Audio Input ]  →  FX 1  →  FX 2  →  FX 3  →  FX 4  →  Fader  →  Audio Output")
                    bullet("**Source.** If a plug-in is loaded in the **INST** slot, it becomes the sound source and is played by MIDI. If the instrument slot is empty, the **audio input** (your selected input device) becomes the source instead.")
                    bullet("**Effects.** Only loaded effect slots are active; the signal passes through them in order (FX 1 → FX 4). Empty slots are bypassed automatically.")
                    bullet("**MIDI.** Incoming MIDI is routed to every loaded plug-in, so instruments respond to notes and MIDI-controllable effects receive control data.")
                    bullet("**Fader.** The end of the chain runs through the level fader (gain, mute and the output meters) before reaching the output device.")
                    para("Everything is stereo (2 in / 2 out).")

                    // 2 ---------------------------------------------------------
                    section("2.  Supported Plug-in Formats")
                    para("VALHost loads the following macOS plug-in formats:")
                    bullet("**Audio Unit (AU)** — Apple's native format. File extension `.component`.")
                    bullet("**VST3** — Steinberg's current standard. File extension `.vst3`.")
                    bullet("**LV2** — the open plug-in standard. Bundle extension `.lv2`.")
                    sub("What about VST2 / VST?")
                    para("**VST2 (the classic “VST” / `.vst` format) is not supported.** Plug-in hosting for VST2 is disabled in this build. VST2 is a deprecated, legacy SDK that Steinberg no longer licenses, so VALHost intentionally hosts only the modern formats above. If a manufacturer ships both VST2 and VST3, install and use the **VST3** version. There is no VST1 support either; “VST” in this guide always means VST3.")

                    // 3 ---------------------------------------------------------
                    section("3.  Where Plug-ins Are Searched")
                    para("When you rescan, VALHost looks in the standard macOS plug-in locations for each format. Both your user folder and the system-wide folder are scanned:")

                    sub("Audio Unit (.component)")
                    mono("~/Library/Audio/Plug-Ins/Components\n/Library/Audio/Plug-Ins/Components")
                    para("Audio Units are also discovered through the macOS AudioComponent registry, so any correctly installed AU is found regardless of which of the two folders it lives in.")

                    sub("VST3 (.vst3)")
                    mono("~/Library/Audio/Plug-Ins/VST3\n/Library/Audio/Plug-Ins/VST3")

                    sub("LV2 (.lv2)")
                    mono("~/Library/Audio/Plug-Ins/LV2\n/Library/Audio/Plug-Ins/LV2")
                    para("In addition, any folders listed in the `LV2_PATH` environment variable are searched.")

                    para("`~` means your home folder (for example `/Users/yourname`). The leading `/Library` path is the shared, system-wide library that applies to all users. Install a plug-in into the matching folder for its format, then rescan.")

                    // 4 ---------------------------------------------------------
                    section("4.  Plug-in Compatibility")
                    bullet("**Architecture.** VALHost is a native **Apple Silicon (arm64)** application. It can only load plug-ins that provide an **arm64** build — i.e. native Apple Silicon or **Universal 2** plug-ins. Intel-only (x86_64) plug-ins will not load, because a single process cannot mix architectures. On an Intel Mac, plug-ins must provide an x86_64 build.")
                    bullet("**Bit depth.** Only 64-bit plug-ins are supported. Old 32-bit plug-ins cannot be loaded by any modern macOS host.")
                    bullet("**Format version.** Use **VST3**, **AU v2/v3**, or **LV2**. Manufacturer “VST2” downloads will be ignored — pick their VST3 or AU installer instead.")
                    bullet("**Validation.** Plug-ins that fail Apple's `auval` validation, or that are damaged/unsigned and blocked by macOS, may not appear after a scan. Make sure the plug-in is properly installed and, if needed, allowed in **System Settings ▸ Privacy & Security**.")

                    // 5 ---------------------------------------------------------
                    section("5.  Scanning & the Plug-in Cache")
                    para("VALHost remembers the plug-ins it has found so it does not have to rescan on every launch. The results are stored here:")
                    mono("~/Library/Application Support/VALHost/scanned_plugins.xml")
                    para("A scan also uses a “dead man's pedal” file to safely skip a plug-in that crashes mid-scan:")
                    mono("~/Library/Application Support/VALHost/scanner_pedal.xml")
                    para("After installing or updating plug-ins, run a rescan so the new versions appear. If the plug-in list ever looks wrong, you can quit VALHost, delete the two files above, and relaunch to force a clean rescan.")

                    // 6 ---------------------------------------------------------
                    section("6.  Audio Setup (Audio Settings)")
                    para("Click **Audio Settings** in the top bar to open the standard macOS audio configuration panel. There you choose:")
                    bullet("**Output device** — where VALHost sends the processed sound (your speakers, headphones or audio interface).")
                    bullet("**Input device** — where VALHost receives sound from (a microphone, an audio interface, or a virtual cable — see the next section).")
                    bullet("**Sample rate** and **buffer size (latency)** — smaller buffers mean lower latency but higher CPU load. 128–256 samples is a good starting point.")
                    para("**Microphone permission:** the first time VALHost uses an audio input, macOS asks for **Microphone** access — this is required for *any* input, including a virtual cable. Click **Allow**. You can change this later under **System Settings ▸ Privacy & Security ▸ Microphone**.")

                    // 7 ---------------------------------------------------------
                    section("7.  Processing Other Apps' Audio — Virtual Audio Cable (VALDriver)")
                    para("VALHost processes whatever arrives at its **audio input**. macOS does not normally let one app capture another app's playback, so to run audio from Spotify, a browser, a DAW, or the whole system through VALHost's effects, you need a **virtual audio cable**. VALHost's companion driver for this is **VALDriver** — a small, free, separately installed driver built for this purpose, available wherever you downloaded VALHost (BlackHole is a popular third-party alternative that does the same job — if you already use it, just substitute “BlackHole 2ch” for “VALHost 2ch” in the steps below).")

                    sub("Step 1 — Install VALDriver")
                    bullet("Download and install **VALDriver** — it installs in seconds and needs no restart.")
                    bullet("After installation it appears as a new audio device named **“VALHost 2ch.”** No audio is audible through it directly — it is a virtual pipe between apps. (This is the separate driver device, not the VALHost app itself — the name is similar on purpose, since the driver was made for VALHost.)")

                    sub("Step 2 — Send the source audio INTO VALDriver")
                    para("Decide what you want to process:")
                    bullet("**Whole system audio:** open **System Settings ▸ Sound ▸ Output** and select **VALHost 2ch**. Everything your Mac plays now flows into VALDriver (and is silent on your speakers until VALHost passes it on — that is expected).")
                    bullet("**A single app (e.g. a DAW):** set that app's own audio **output** to **VALHost 2ch** in its preferences, and leave the macOS system output on your speakers.")

                    sub("Step 3 — Set VALHost's input and output")
                    para("Open **Audio Settings** in VALHost and set:")
                    bullet("**Input = VALHost 2ch** — this is the audio coming from the source app/system, via VALDriver.")
                    bullet("**Output = your real device** — e.g. *MacBook Pro Speakers*, your headphones, or your audio interface. This is what you will actually hear.")
                    mono("Source app / System  →  VALDriver (“VALHost 2ch”)  →  VALHost (Input)\nVALHost effects + fader  →  VALHost (Output)  →  Speakers / Headphones")
                    para("That's it — audio from the source now passes through VALHost's plug-in chain and out to your speakers.")

                    sub("Step 4 (optional) — Hear system audio AND keep monitoring")
                    para("If you routed the **whole system** into VALDriver, your normal alerts and other apps also go silent except through VALHost. If you want a copy to reach your speakers directly as well, create a **Multi-Output Device**:")
                    bullet("Open **Audio MIDI Setup** (in /Applications/Utilities).")
                    bullet("Click **+** ▸ **Create Multi-Output Device**, then tick both **VALHost 2ch** and your **speakers/headphones**.")
                    bullet("Set that Multi-Output Device as the macOS **system output**. VALDriver still feeds VALHost, while your speakers get the dry copy.")
                    para("For most effect-processing use, Step 3 alone is enough; the Multi-Output Device is only needed for special monitoring setups.")

                    sub("Avoiding feedback loops")
                    bullet("**Never set VALHost's output to VALHost 2ch** while it is also its input — that creates an infinite loop and a loud howl.")
                    bullet("Keep the source going **into** VALDriver and VALHost coming **out** to a real device. Input and output must be different devices.")

                    // 8 ---------------------------------------------------------
                    section("8.  Using VALHost as an Instrument Host")
                    bullet("Load a software instrument (AU/VST3/LV2 synth or sampler) into the **INST** slot.")
                    bullet("Connect a MIDI keyboard, or select a MIDI input in **Audio Settings**. You can also use the on-screen keyboard at the bottom of the window — or play with your **computer keyboard** (A W S E D F… for the white/black keys, **Z / X** to shift octave down/up).")
                    bullet("Add effects in **FX 1–4** to process the instrument (reverb, EQ, compression, etc.).")
                    bullet("When an instrument is loaded, the audio input is ignored — the instrument is the source.")

                    // 9 ---------------------------------------------------------
                    section("9.  The Channel Strip")
                    bullet("**Slots.** Click a slot to choose a plug-in for it. The instrument list shows only instruments; effect slots show only effects.")
                    bullet("**Bypass (B).** Temporarily passes a loaded effect through unprocessed — without unloading it or losing its settings — so you can A/B the sound with and without it. On the instrument slot, B silences the instrument.")
                    bullet("**Editor (E).** Open a plug-in's own interface from its slot. If a plug-in has no usable native UI, VALHost shows a generic parameter editor instead.")
                    bullet("**Fader.** The level fader is calibrated in decibels with a natural feel: the **+2 dB … −6 dB** region occupies the top half of the travel for fine control near unity gain, **−6 … −30 dB** the next portion, and **−30 dB … −∞** the bottom. The very bottom is true silence (**−∞ dB**).")
                    bullet("**Mute.** Silences the output instantly.")
                    bullet("**Panic.** Sends an all-notes-off / all-sound-off to every plug-in — use it if a software instrument leaves a note hanging.")
                    bullet("**Meters.** The stereo meters show output level in dBFS. The scale turns yellow approaching −6 dBFS and red at 0 dBFS (clipping). A peak-hold marker briefly freezes the highest recent level.")

                    // 10 --------------------------------------------------------
                    section("10.  Saving & Loading Sessions")
                    para("Use **Save** and **Load** in the top bar to store and recall a complete setup — which plug-ins are loaded in each slot, their settings, bypass, and the fader/mute state — as a `.valhost` file.")
                    para("VALHost also **remembers your last setup automatically** and restores it the next time you launch, so you pick up right where you left off.")

                    // 11 --------------------------------------------------------
                    section("11.  Troubleshooting")
                    bullet("**No sound:** check that the correct **Output** device is selected, the **fader is up**, and **Mute** is off. If processing input, confirm the **Input** device and that audio is actually reaching VALDriver.")
                    bullet("**A plug-in doesn't appear:** confirm it's installed in the correct folder for its format (Section 3), is **arm64/Universal**, then rescan. Delete the cache files (Section 5) to force a clean scan.")
                    bullet("**Input is silent:** make sure macOS granted **Microphone** permission, and that the source app/system output is set to **VALHost 2ch** (VALDriver).")
                    bullet("**Loud howling / feedback:** your input and output are the same device — set VALHost's output to a real speaker/headphone device, not back into VALDriver.")
                    bullet("**Crackles / dropouts:** increase the **buffer size** in Audio Settings.")

                    // Footer ----------------------------------------------------
                    Divider().background(Color.gray.opacity(0.2)).padding(.vertical, 10)
                    Text("VALHost v\(appVersion) (Build \(appBuild))   •   © Peter Betz   •   Powered by JUCE")
                        .font(.system(size: 9))
                        .foregroundColor(.gray.opacity(0.6))
                        .padding(.bottom, 8)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .textSelection(.enabled)
            }
            .background(
                LinearGradient(gradient: Gradient(colors: [Color(white: 0.09), Color(white: 0.13)]),
                               startPoint: .top, endPoint: .bottom)
            )
        }
        .frame(width: 680, height: 700)
    }

    // MARK: Styled building blocks
    private func section(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.teal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }

    private func sub(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(white: 0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func para(_ s: String) -> some View {
        Text(.init(s))
            .font(.system(size: 11.5))
            .foregroundColor(Color(white: 0.80))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(.teal)
            Text(.init(s))
                .font(.system(size: 11.5))
                .foregroundColor(Color(white: 0.80))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func mono(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(.teal)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.teal.opacity(0.15), lineWidth: 1))
            .padding(.vertical, 4)
    }
}
