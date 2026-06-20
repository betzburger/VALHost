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

    void prepareToPlay (double /*sampleRate*/, int /*samplesPerBlock*/) override {}
    void releaseResources() override {}

    void processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer& /*midiMessages*/) override
    {
        if (mute)
        {
            buffer.clear();
            leftLevel.store (0.0f);
            rightLevel.store (0.0f);
            return;
        }

        if (gain != 1.0f)
            buffer.applyGain (gain);

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

    float gain = 1.0f;
    bool mute = false;
    bool solo = false;
    std::atomic<float> leftLevel { 0.0f };
    std::atomic<float> rightLevel { 0.0f };

private:
    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (FaderProcessor)
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
        if (onClose)
            onClose();
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

    // Plugin Editor Windows
    void showPluginEditor (int slotIndex);
    void hidePluginEditor (int slotIndex);
    bool isPluginEditorVisible (int slotIndex) const;

    // Signal Routing
    void updateGraphConnections();

    // Volume & Metering
    float getFaderGain() const { return faderProcessor != nullptr ? faderProcessor->gain : 1.0f; }
    void setFaderGain (float gain) { if (faderProcessor) faderProcessor->gain = gain; }
    bool getFaderMute() const { return faderProcessor != nullptr ? faderProcessor->mute : false; }
    void setFaderMute (bool mute) { if (faderProcessor) faderProcessor->mute = mute; }
    bool getFaderSolo() const { return faderProcessor != nullptr ? faderProcessor->solo : false; }
    void setFaderSolo (bool solo) { if (faderProcessor) faderProcessor->solo = solo; }
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

    // Active Plugin Nodes in slots: [0] = Instrument, [1..4] = Effects
    juce::AudioProcessorGraph::Node::Ptr activeNodes[totalSlots];

    // Open plugin editor windows
    std::unique_ptr<PluginWindow> activeWindows[totalSlots];

    // Helper to get cached scanned list file
    juce::File getDeadMansPedalFile();
    juce::File getSavedPluginListFile();

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (AudioEngine)
};
