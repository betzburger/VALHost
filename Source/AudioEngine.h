#pragma once

#include <JuceHeader.h>

//==============================================================================
/** A simple AudioProcessor that sits at the end of the chain to control volume,
    mute, and measure the output levels.
*/
class FaderProcessor : public juce::AudioProcessor
{
public:
    FaderProcessor()
        : AudioProcessor (BusesProperties()
                            .withInput  ("Input",  juce::AudioChannelSet::stereo(), true)
                            .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
    {}

    ~FaderProcessor() override = default;

    void prepareToPlay (double /*sampleRate*/, int /*samplesPerBlock*/) override
    {
        appliedGain = mute.load() ? 0.0f : gain.load();
    }
    void releaseResources() override {}

    void processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& /*midiMessages*/) override
    {
        // Mute is just a target gain of 0. Any change of the target is ramped over
        // one block, so fader moves and (un)muting never click or zipper.
        const float target = mute.load() ? 0.0f : gain.load();

        if (target == 0.0f && appliedGain == 0.0f)
        {
            buffer.clear();
            leftLevel.store (0.0f);
            rightLevel.store (0.0f);
            return;
        }

        if (target != appliedGain)
            buffer.applyGainRamp (0, buffer.getNumSamples(), appliedGain, target);
        else if (target != 1.0f)
            buffer.applyGain (target);

        appliedGain = target;

        auto numSamples = buffer.getNumSamples();
        if (numSamples > 0)
        {
            if (buffer.getNumChannels() > 0)
                leftLevel.store (buffer.getMagnitude (0, 0, numSamples));
            else
                leftLevel.store (0.0f);

            if (buffer.getNumChannels() > 1)
                rightLevel.store (buffer.getMagnitude (1, 0, numSamples));
            else
                rightLevel.store (leftLevel.load());
        }
        else
        {
            leftLevel.store (0.0f);
            rightLevel.store (0.0f);
        }
    }

    const juce::String getName() const override { return "Fader"; }
    bool acceptsMidi() const override { return false; }
    bool producesMidi() const override { return false; }
    bool isMidiEffect() const override { return false; }
    double getTailLengthSeconds() const override { return 0.0; }

    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}

    void getStateInformation (juce::MemoryBlock&) override {}
    void setStateInformation (const void*, int) override {}

    bool hasEditor() const override { return false; }
    juce::AudioProcessorEditor* createEditor() override { return nullptr; }

    // Startup gain. MUST stay in sync with the taper anchors below and with
    // VALDriver's kStartupVolumeScalar: position 0.2 == -30 dB == 20 % on the
    // system volume slider. Anything higher means VALHost boots into a loud
    // state before a session (if any) has been restored.
    static constexpr float startupGain = 0.0316227766f;   // 10 ^ (-30 / 20)

    std::atomic<float> gain { startupGain };
    std::atomic<bool> mute { false };
    std::atomic<float> leftLevel { 0.0f };
    std::atomic<float> rightLevel { 0.0f };

private:
    float appliedGain = startupGain;   // audio thread only: gain at the end of the last block

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (FaderProcessor)
};

//==============================================================================
/** Generates the "Test" tone for the settings dialog.

    JUCE's own device-selector test tone is mixed into the device output *after*
    the audio callbacks, so it bypasses the whole graph — and therefore the
    master fader — and always plays at full scale. This processor produces the
    identical signal (440 Hz, 0.5 amplitude, 1 s, faded) but sits *upstream* of
    the fader node, so the tone is exactly as loud as the current volume setting.
*/
class TestToneProcessor : public juce::AudioProcessor
{
public:
    TestToneProcessor()
        : AudioProcessor (BusesProperties()
                            .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
    {}

    ~TestToneProcessor() override = default;

    // Message thread: queue one tone. The audio thread picks it up on the next
    // block, so no locking is needed.
    void trigger() { triggers.fetch_add (1); }

    void prepareToPlay (double newSampleRate, int) override { sampleRate = newSampleRate; }
    void releaseResources() override {}

    void processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&) override
    {
        const int numSamples = buffer.getNumSamples();
        buffer.clear();

        if (triggers.exchange (0) > 0)
        {
            playing = true;
            position = 0;
        }

        if (! playing)
            return;

        const double sr = sampleRate > 0.0 ? sampleRate : 44100.0;
        const int total = (int) sr;                 // 1 second
        const int fadeIn = total / 10;
        const int fadeOutStart = total - total / 4;
        const double phasePerSample = juce::MathConstants<double>::twoPi * 440.0 / sr;

        for (int i = 0; i < numSamples; ++i)
        {
            if (position >= total)
            {
                playing = false;
                break;
            }

            float envelope = 1.0f;
            if (position < fadeIn)
                envelope = (float) position / (float) fadeIn;
            else if (position >= fadeOutStart)
                envelope = (float) (total - position) / (float) (total - fadeOutStart);

            const float sample = 0.5f * envelope * (float) std::sin (phasePerSample * position);

            for (int ch = 0; ch < buffer.getNumChannels(); ++ch)
                buffer.setSample (ch, i, sample);

            ++position;
        }
    }

    const juce::String getName() const override { return "Test Tone"; }
    bool acceptsMidi() const override { return false; }
    bool producesMidi() const override { return false; }
    bool isMidiEffect() const override { return false; }
    double getTailLengthSeconds() const override { return 0.0; }
    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}
    void getStateInformation (juce::MemoryBlock&) override {}
    void setStateInformation (const void*, int) override {}
    bool hasEditor() const override { return false; }
    juce::AudioProcessorEditor* createEditor() override { return nullptr; }

private:
    std::atomic<int> triggers { 0 };
    bool playing = false;          // audio thread only
    int position = 0;              // audio thread only
    double sampleRate = 44100.0;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (TestToneProcessor)
};

//==============================================================================
/** Class representing a plugin editor window.
*/
class PluginWindow : public juce::DocumentWindow
{
public:
    PluginWindow (juce::AudioProcessorGraph::Node* node,
                  std::unique_ptr<juce::AudioProcessorEditor> editor,
                  std::function<void()> onCloseCallback)
        : DocumentWindow (node->getProcessor()->getName(),
                          juce::Colours::darkgrey,
                          DocumentWindow::allButtons),
          onClose (std::move (onCloseCallback))
    {
        setUsingNativeTitleBar (true);
        setContentOwned (editor.release(), true);
        setResizable (true, false);
        setDropShadowEnabled (true);
        setVisible (true);
    }

    void closeButtonPressed() override
    {
        // This is called from inside the window, and onClose() destroys this very
        // window. Deleting it synchronously here is a use-after-free that crashes
        // on some plugins. Hide it now for responsiveness and defer the teardown
        // until we have safely returned from this callback.
        setVisible (false);

        if (onClose)
            juce::MessageManager::callAsync (onClose);
    }

private:
    std::function<void()> onClose;
    JUCE_DECLARE_NON_COPYABLE (PluginWindow)
};

//==============================================================================
/** The central AudioEngine class that manages audio IO, plugin scanning,
    graph routing, and session state.
*/
class PluginScannerTimer;

class AudioEngine : public juce::ChangeListener,
                    private juce::MidiKeyboardStateListener
{
    friend class PluginScannerTimer;
public:
    AudioEngine();
    ~AudioEngine() override;

    void init();
    void shutdown();

    // Re-open the audio input device with stereo input. Called once microphone
    // permission has been granted: the prompt is requested explicitly by the app
    // delegate (AVCaptureDevice), but init() runs before permission exists, so the
    // first open silently falls back to output-only. This re-opens with input and
    // refreshes the graph. Must be called on the message thread.
    void reopenAudioInput();

    // Plugin Scanning
    void scanPlugins (std::function<void(const juce::String&)> onProgress,
                      std::function<void()> onComplete);

    const juce::KnownPluginList& getKnownPlugins() const { return knownPlugins; }
    juce::KnownPluginList& getKnownPlugins() { return knownPlugins; }

    // Plugin Slots (0 = Instrument, 1-4 = Effects)
    bool loadPlugin (int slotIndex, const juce::PluginDescription& desc, juce::String& errorMessage);
    void unloadPlugin (int slotIndex);
    bool isPluginLoaded (int slotIndex) const;
    juce::String getPluginName (int slotIndex) const;

    // Plugin Editor Windows. Shows the plugin's native view, but transparently
    // falls back to JUCE's generic slider editor for plugins whose native view
    // would crash (see shouldUseGenericEditor) or that have no editor of their own.
    void showPluginEditor (int slotIndex);
    void hidePluginEditor (int slotIndex);
    bool isPluginEditorVisible (int slotIndex) const;

    // Per-slot bypass. Effect slots pass audio through unprocessed; the
    // instrument slot is silenced. Keeps the plugin and its state loaded.
    void setSlotBypassed (int slotIndex, bool bypassed);
    bool isSlotBypassed (int slotIndex) const;

    // MIDI panic: send all-notes-off / all-sound-off / sustain-off to every
    // plugin on every channel, releasing any stuck or sustained notes.
    void sendPanic();

    // Signal Routing
    void updateGraphConnections();

    // Volume & Metering
    float getFaderGain() const { return faderProcessor != nullptr ? faderProcessor->gain.load() : FaderProcessor::startupGain; }
    void setFaderGain (float gain) { if (faderProcessor) faderProcessor->gain.store (gain); }
    bool getFaderMute() const { return faderProcessor != nullptr ? faderProcessor->mute.load() : false; }
    void setFaderMute (bool mute) { if (faderProcessor) faderProcessor->mute.store (mute); }

    // Volume/mute changes that originate in VALHost (the UI fader, a loaded
    // session). These apply the change locally *and* mirror it onto VALDriver's
    // volume control, so the system volume HUD and the macOS volume keys stay in
    // sync. Changes that arrive the other way (a key press -> VALDriver) are
    // applied by the property listener and must NOT be echoed back here.
    void setVolumeFromUI (float gain);
    void setMuteFromUI (bool mute);

    // Play the master test tone (440 Hz). It runs through the graph *and* the
    // master fader, so it is exactly as loud as the current volume setting —
    // unlike JUCE's device-selector tone, which is mixed into the device output
    // after the callbacks and always plays at full scale.
    void playTestTone();
    float getLeftLevel() const { return faderProcessor != nullptr ? faderProcessor->leftLevel.load() : 0.0f; }
    float getRightLevel() const { return faderProcessor != nullptr ? faderProcessor->rightLevel.load() : 0.0f; }

    // Hardware
    juce::AudioDeviceManager& getAudioDeviceManager() { return deviceManager; }
    juce::MidiKeyboardState& getMidiKeyboardState() { return keyboardState; }
    juce::AudioPluginFormatManager& getFormatManager() { return formatManager; }

    // Save / Load Sessions
    bool saveSession (const juce::File& file);
    bool loadSession (const juce::File& file, juce::String& errorMessage);

    // AudioDeviceManager change listener
    void changeListenerCallback (juce::ChangeBroadcaster* source) override;

    static constexpr int instrumentSlot = 0;
    static constexpr int numEffectSlots = 4;
    static constexpr int totalSlots = 5; // Slot 0 = Instrument, 1-4 = Effects

private:
    // MidiKeyboardStateListener callbacks
    void handleNoteOn (juce::MidiKeyboardState* state, int midiChannel, int midiNoteNumber, float velocity) override;
    void handleNoteOff (juce::MidiKeyboardState* state, int midiChannel, int midiNoteNumber, float velocity) override;

    juce::AudioDeviceManager deviceManager;
    juce::MidiKeyboardState keyboardState;

    juce::AudioPluginFormatManager formatManager;
    juce::KnownPluginList knownPlugins;

    std::unique_ptr<juce::AudioProcessorGraph> audioGraph;
    std::unique_ptr<juce::AudioProcessorPlayer> graphPlayer;

    // Graph IO Nodes
    juce::AudioProcessorGraph::Node::Ptr audioInputNode;
    juce::AudioProcessorGraph::Node::Ptr audioOutputNode;
    juce::AudioProcessorGraph::Node::Ptr midiInputNode;

    // Fader / Master Output Node
    juce::AudioProcessorGraph::Node::Ptr faderNode;
    FaderProcessor* faderProcessor = nullptr; // Pointer to processor inside faderNode

    // Test-tone generator, mixed into the fader node's input (see
    // TestToneProcessor). Always present in the graph, silent when idle.
    juce::AudioProcessorGraph::Node::Ptr testToneNode;

    // Active Plugin Nodes in slots: [0] = Instrument, [1..4] = Effects
    juce::AudioProcessorGraph::Node::Ptr activeNodes[totalSlots];

    // Open plugin editor windows
    std::unique_ptr<PluginWindow> activeWindows[totalSlots];

    // Whether the editor open in each slot is the plugin's native view (true) or
    // JUCE's generic editor (false). Only native views get crash-sentinel
    // protection when they are torn down.
    bool editorIsNative[totalSlots] = {};

    //==============================================================================
    // System-volume link to VALDriver.
    //
    // When VALDriver ("VALHost 2ch") is the macOS default output, the volume keys
    // act on its volume/mute control. VALDriver owns the single shared value (a
    // 0..1 scalar that doubles as the fader position); VALHost mirrors it both
    // ways and applies the actual gain. If the driver is not installed every
    // method below is a graceful no-op and the fader still works locally.
   #if JUCE_MAC
    // System-volume link. All CoreAudio/HAL work lives in SystemVolumeLink (a
    // JUCE-free translation unit) so this header never pulls in CoreAudio types.
    void syncVolumeToDriver();                  // push current gain + mute onto VALDriver

    // Volume taper shared with VALDriver and the SwiftUI fader (must match the
    // anchors in CustomHorizontalFader / VALDriver.c).
    static float gainForPosition (float pos);   // 0..1 scalar -> linear gain
    static float positionForGain (float gain);  // linear gain -> 0..1 scalar

    std::unique_ptr<class SystemVolumeLink> systemVolumeLink;
   #endif

    // Helper to get cached support files
    juce::File getDeadMansPedalFile();
    juce::File getSavedPluginListFile();
    juce::File getAudioSettingsFile();
    void saveAudioSettings();

    //==============================================================================
    // Crash-safe plugin editors.
    //
    // Some plugins' native editor views crash the host on first draw and the crash
    // cannot be caught (it happens deep inside AppKit's draw cycle), so we must
    // decide *before* opening whether to show the native view or fall back to
    // JUCE's generic slider editor. We know the answer from two sources:
    //   1. A built-in seed list of identifiers we have confirmed to crash (shipped
    //      with the app, so users never start from zero).
    //   2. A self-learning list: before opening an unverified native view we write
    //      its identifier to a sentinel file; a timer clears it once the view has
    //      drawn safely. If the app crashed first, the sentinel survives and on the
    //      next launch that identifier is promoted to the learned list for good.

    // Populate crashingEditorIds from the seed list, the persisted learned list,
    // and any sentinel left over from a crash in the previous session.
    void loadCrashKnowledge();

    // True if this plugin's native editor is known to crash and must be avoided.
    bool shouldUseGenericEditor (juce::AudioProcessor* processor) const;

    // Add an identifier to the learned list (in memory and on disk).
    void rememberCrashingEditor (const juce::String& identifier);

    static juce::File getLearnedCrashFile();
    static juce::File getPendingEditorFile();
    static void armCrashSentinel (const juce::String& identifier);
    static void disarmCrashSentinel (const juce::String& identifier);

    // Union of the built-in seed list and the learned list.
    juce::StringArray crashingEditorIds;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (AudioEngine)
};
