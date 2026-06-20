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
struct EffectSlotRow: View {
    let index: Int
    @ObservedObject var state: VALHostState

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button("[None]") {
                    VALHostEngine.sharedInstance().unloadPlugin(atSlot: Int32(index + 1))
                    state.refreshSlots()
                }
                ForEach(state.effects) { plugin in
                    Button("\(plugin.name) (\(plugin.format))") {
                        state.loadPlugin(slot: index + 1, name: plugin.name)
                    }
                }
            } label: {
                Text(state.effectNames[index])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(height: 28)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))

            Button("E") {
                VALHostEngine.sharedInstance().showPluginEditor(atSlot: Int32(index + 1))
            }
            .disabled(!state.isEffectLoaded[index])
            .frame(width: 24, height: 28)
            .buttonStyle(.bordered)

            Button("X") {
                VALHostEngine.sharedInstance().unloadPlugin(atSlot: Int32(index + 1))
                state.refreshSlots()
            }
            .disabled(!state.isEffectLoaded[index])
            .frame(width: 24, height: 28)
            .buttonStyle(.bordered)
        }
    }
}

//==============================================================================
struct TopBarView: View {
    @ObservedObject var state: VALHostState
    let onLoad: () -> Void
    let onSave: () -> Void
    
    var body: some View {
        HStack {
            Text("VALHost")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.teal)
            
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
        VStack(spacing: 10) {
            Text("CHANNEL STRIP")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.teal)
                .padding(.top, 4)

            // Instrument Slot
            VStack(alignment: .leading, spacing: 4) {
                Text("INSTRUMENT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)
                
                HStack(spacing: 4) {
                    Menu {
                        Button("[None]") {
                            VALHostEngine.sharedInstance().unloadPlugin(atSlot: 0)
                            state.refreshSlots()
                        }
                        ForEach(state.instruments) { plugin in
                            Button("\(plugin.name) (\(plugin.format))") {
                                state.loadPlugin(slot: 0, name: plugin.name)
                            }
                        }
                    } label: {
                        Text(state.instrumentName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(height: 28)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))

                    Button("E") {
                        VALHostEngine.sharedInstance().showPluginEditor(atSlot: 0)
                    }
                    .disabled(!state.isInstrumentLoaded)
                    .frame(width: 24, height: 28)
                    .buttonStyle(.bordered)

                    Button("X") {
                        VALHostEngine.sharedInstance().unloadPlugin(atSlot: 0)
                        state.refreshSlots()
                    }
                    .disabled(!state.isInstrumentLoaded)
                    .frame(width: 24, height: 28)
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 8)

            // Effects Slots
            VStack(alignment: .leading, spacing: 4) {
                Text("EFFECTS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)

                ForEach(0..<4) { i in
                    EffectSlotRow(index: i, state: state)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 8)

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
            HStack(spacing: 12) {
                // Vertical Fader
                Slider(value: $state.volume, in: 0.0...1.25, onEditingChanged: { _ in
                    VALHostEngine.sharedInstance().setVolume(Float(state.volume))
                })
                .controlSize(.small)
                .rotationEffect(.degrees(-90))
                .frame(width: 40, height: 160)

                // Peak Level Meter
                HStack(spacing: 2) {
                    VerticalLevelMeter(val: state.leftPeak)
                    VerticalLevelMeter(val: state.rightPeak)
                }
                .frame(width: 24, height: 140)
                .padding(.vertical, 10)
            }
            .frame(height: 160)
        }
        .frame(width: 230)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15), lineWidth: 1.5))
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

            List {
                let filtered = state.plugins.filter {
                    state.searchText.isEmpty ? true : (
                        $0.name.localizedCaseInsensitiveContains(state.searchText) ||
                        $0.format.localizedCaseInsensitiveContains(state.searchText)
                    )
                }
                ForEach(filtered) { plugin in
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
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
            }
            .cornerRadius(4)
            .listStyle(.inset)
            .frame(height: 380)

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
            .frame(width: 548, height: 75)

            // Black Keys: 4 Octaves -> 20 black keys
            let keyWidth: CGFloat = 548.0 / 29.0
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
        .frame(width: 548, height: 75)
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
        .frame(width: 580, height: 660)
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
