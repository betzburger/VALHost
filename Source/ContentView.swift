import SwiftUI
import UniformTypeIdentifiers
import Combine

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
    
    // Mixer State
    @Published var volume: Double = 1.0
    @Published var isMute: Bool = false
    @Published var isSolo: Bool = false
    
    // Slot Names
    @Published var instrumentName: String = "Select Instrument..."
    @Published var effectNames: [String] = Array(repeating: "Select Effect...", count: 4)
    @Published var isInstrumentLoaded: Bool = false
    @Published var isEffectLoaded: [Bool] = Array(repeating: false, count: 4)
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
        
        self.volume = Double(VALHostEngine.sharedInstance().getVolume())
        self.isMute = VALHostEngine.sharedInstance().getMute()
        self.isSolo = VALHostEngine.sharedInstance().getSolo()
    }

    func loadPlugin(slot: Int, name: String) {
        if let idx = plugins.firstIndex(where: { $0.name == name }) {
            var err: NSString?
            let success = VALHostEngine.sharedInstance().loadPlugin(atSlot: Int32(slot), pluginIndex: Int32(idx), error: &err)
            if !success {
                self.statusMessage = "Error loading plugin: \(err ?? "Unknown error")"
            }
            refreshSlots()
        }
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
                    self?.statusMessage = "Scan complete. \(total) plug-ins found."
                }
            }
        })
    }

    func pollLevelsAndCpu() {
        self.cpuUsage = VALHostEngine.sharedInstance().getCpuUsage()
        self.leftPeak = VALHostEngine.sharedInstance().getLeftLevel()
        self.rightPeak = VALHostEngine.sharedInstance().getRightLevel()
        
        if !self.isScanning {
            self.statusMessage = "\(self.plugins.count) plug-ins scanned and ready."
        }
    }
}

//==============================================================================
struct VerticalLevelMeter: View {
    var val: Float
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.4))
                
                // Active bar with gradient
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [.red, .orange, .green]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: max(0, min(CGFloat(val) * geometry.size.height, geometry.size.height)))
            }
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
            
            // Edit button (plugin's native editor)
            Button(action: {
                VALHostEngine.sharedInstance().showPluginEditor(atSlot: Int32(slotIndex))
            }) {
                Text("E")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 32)
            }
            .buttonStyle(.bordered)
            .disabled(!isLoaded)
            .help("Open the plugin's own editor window")

            // Generic editor (JUCE sliders) — use if a plugin's own window misbehaves
            Button(action: {
                VALHostEngine.sharedInstance().showGenericPluginEditor(atSlot: Int32(slotIndex))
            }) {
                Text("G")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 32)
            }
            .buttonStyle(.bordered)
            .disabled(!isLoaded)
            .help("Open a generic slider editor (use if the plugin's own window crashes, e.g. Apple's Graphic EQ)")

            // Unload button
            Button(action: {
                VALHostEngine.sharedInstance().unloadPlugin(atSlot: Int32(slotIndex))
                state.refreshSlots()
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
struct CustomVerticalFader: View {
    @Binding var value: Double // Range 0.0 to 1.25
    let onChanged: (Double) -> Void
    
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let faderRange: ClosedRange<Double> = 0.0...1.25
            
            // Calculate handle Y offset
            let normVal = CGFloat((value - faderRange.lowerBound) / (faderRange.upperBound - faderRange.lowerBound))
            let handleHeight: CGFloat = 18
            let trackHeight = max(0, height - handleHeight)
            let yOffset = trackHeight * (1.0 - normVal)
            
            ZStack(alignment: .top) {
                // Fader Track background
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.12))
                    .frame(width: 8, height: height)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.black.opacity(0.5), lineWidth: 1)
                    )
                
                // Track highlight (from bottom to current value)
                VStack {
                    Spacer()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [Color.teal, Color.teal.opacity(0.6)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 6, height: max(0, trackHeight * normVal))
                }
                .padding(.bottom, handleHeight / 2)
                .frame(height: height)
                
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
                        // Center horizontal stripe on handle
                        Rectangle()
                            .fill(Color.teal)
                            .frame(height: 2)
                    )
                    .shadow(color: Color.black.opacity(0.6), radius: 2, x: 0, y: 1.5)
                    .frame(width: 26, height: handleHeight)
                    .offset(y: yOffset)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                let dragY = gesture.location.y - (handleHeight / 2)
                                let clampedY = max(0, min(dragY, trackHeight))
                                let percent = trackHeight > 0 ? (1.0 - (clampedY / trackHeight)) : 0.0
                                let val = faderRange.lowerBound + Double(percent) * (faderRange.upperBound - faderRange.lowerBound)
                                self.value = val
                                onChanged(val)
                            }
                    )
            }
            .frame(width: 26)
        }
    }
}

//==============================================================================
struct TopBarView: View {
    @ObservedObject var state: VALHostState
    let onLoad: () -> Void
    let onSave: () -> Void
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

            // Mute / Solo
            HStack(spacing: 8) {
                Button(action: {
                    state.isMute.toggle()
                    VALHostEngine.sharedInstance().setMute(state.isMute)
                }) {
                    Text("MUTE")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
                .tint(state.isMute ? .red : .gray)
                .buttonStyle(.borderedProminent)

                Button(action: {
                    state.isSolo.toggle()
                    VALHostEngine.sharedInstance().setSolo(state.isSolo)
                }) {
                    Text("SOLO")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
                .tint(state.isSolo ? .orange : .gray)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 8)

            // Fader + Meter Row
            HStack(spacing: 16) {
                Spacer()
                
                // Custom Vertical Fader (Teal Highlight, 3D Handle, Vertical Drag)
                VStack(spacing: 4) {
                    Text(String(format: "%.1f dB", faderValueToDb(state.volume)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    CustomVerticalFader(value: $state.volume) { val in
                        VALHostEngine.sharedInstance().setVolume(Float(val))
                    }
                    .frame(height: 140)
                }
                .frame(width: 44)

                // Peak Level Meter
                VStack(spacing: 4) {
                    Text("METER")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 3) {
                        VerticalLevelMeter(val: state.leftPeak)
                        VerticalLevelMeter(val: state.rightPeak)
                    }
                    .frame(width: 24, height: 140)
                    .padding(.vertical, 2)
                }
                
                Spacer()
            }
            .frame(height: 165)
        }
        .frame(width: 420)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15), lineWidth: 1.5))
    }
    
    // Helper to translate slider/fader range (0.0 to 1.25) to a decibel representation
    private func faderValueToDb(_ val: Double) -> Double {
        if val <= 0.0001 { return -96.0 }
        let db = 20.0 * log10(val)
        return db
    }
}

//==============================================================================
struct SidebarView: View {
    @ObservedObject var state: VALHostState

    var body: some View {
        VStack(spacing: 8) {
            Text("SCANNED PLUGINS")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.teal)
            
            TextField("Search plug-ins...", text: $state.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 4)

            Text("Double-click to load a plugin into the selected effects slot")
                .font(.system(size: 10))
                .foregroundColor(.gray.opacity(0.7))
                .padding(.bottom, 2)

            List {
                let filtered = state.plugins.filter {
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
struct ContentView: View {
    @StateObject private var state = VALHostState()
    
    // Polling timer (30 FPS)
    let timer = Timer.publish(every: 0.033, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            TopBarView(state: state, onLoad: loadSession, onSave: saveSession)

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
        }
        .onReceive(timer) { _ in
            state.pollLevelsAndCpu()
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
                    state.statusMessage = "Saved session to \(url.lastPathComponent)"
                } else {
                    state.statusMessage = "Failed to save session"
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
                    state.statusMessage = "Loaded session from \(url.lastPathComponent)"
                    state.refreshSlots()
                } else {
                    state.statusMessage = "Error loading session: \(err ?? "Unknown error")"
                }
            }
        }
    }
}
