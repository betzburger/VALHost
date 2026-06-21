#include "AudioEngine.h"
#include <thread>

//==============================================================================
AudioEngine::AudioEngine()
{
    // Register formats
    formatManager.addDefaultFormats();
}

AudioEngine::~AudioEngine()
{
    shutdown();
}

void AudioEngine::init()
{
    // Ensure parent directory exists for support files
    getSavedPluginListFile().getParentDirectory().createDirectory();

    // Load built-in + learned knowledge of which plugin editors crash, and promote
    // any crash from the previous session (left-over sentinel) into the learned list.
    loadCrashKnowledge();

    // Try to load cached plugin list
    auto listFile = getSavedPluginListFile();
    if (listFile.existsAsFile())
    {
        std::unique_ptr<juce::XmlElement> xml (juce::XmlDocument::parse (listFile));
        if (xml != nullptr)
            knownPlugins.recreateFromXml (*xml);
    }

    // Initialize audio device manager
    juce::String audioInitError = deviceManager.initialiseWithDefaultDevices (2, 2);
    deviceManager.addChangeListener (this);

    // Setup Audio Graph
    audioGraph = std::make_unique<juce::AudioProcessorGraph>();
    
    double sampleRate = 44100.0;
    int blockSize = 512;
    int numInputs = 2;
    int numOutputs = 2;
    if (auto* device = deviceManager.getCurrentAudioDevice())
    {
        sampleRate = device->getCurrentSampleRate();
        blockSize = device->getCurrentBufferSizeSamples();
        numInputs = std::max (2, device->getActiveInputChannels().countNumberOfSetBits());
        numOutputs = std::max (2, device->getActiveOutputChannels().countNumberOfSetBits());
    }
    audioGraph->setPlayConfigDetails (numInputs, numOutputs, sampleRate, blockSize);
    
    // Add IO Nodes
    using AudioGraphIOProcessor = juce::AudioProcessorGraph::AudioGraphIOProcessor;
    audioInputNode  = audioGraph->addNode (std::make_unique<AudioGraphIOProcessor> (AudioGraphIOProcessor::audioInputNode));
    audioOutputNode = audioGraph->addNode (std::make_unique<AudioGraphIOProcessor> (AudioGraphIOProcessor::audioOutputNode));
    midiInputNode   = audioGraph->addNode (std::make_unique<AudioGraphIOProcessor> (AudioGraphIOProcessor::midiInputNode));

    // Add Fader Node
    faderNode = audioGraph->addNode (std::make_unique<FaderProcessor>());
    faderProcessor = dynamic_cast<FaderProcessor*> (faderNode->getProcessor());

    // Setup player
    graphPlayer = std::make_unique<juce::AudioProcessorPlayer>();
    graphPlayer->setProcessor (audioGraph.get());
    keyboardState.addListener (this);

    // Set audio callback
    deviceManager.addAudioCallback (graphPlayer.get());
    deviceManager.addMidiInputDeviceCallback ({}, graphPlayer.get());

    updateGraphConnections();
}

void AudioEngine::shutdown()
{
    keyboardState.removeListener (this);

    // Stop audio callback first
    deviceManager.removeAudioCallback (graphPlayer.get());
    deviceManager.removeMidiInputDeviceCallback ({}, graphPlayer.get());

    // Close windows
    for (int i = 0; i < totalSlots; ++i)
        activeWindows[i] = nullptr;

    // Unload all plugins
    for (int i = 0; i < totalSlots; ++i)
        unloadPlugin (i);

    // Clear graph
    if (audioGraph)
    {
        audioGraph->clear();
        audioGraph = nullptr;
    }
    
    graphPlayer = nullptr;
    faderProcessor = nullptr;
    deviceManager.removeChangeListener (this);
}

class PluginScannerTimer : public juce::Timer
{
public:
    PluginScannerTimer (AudioEngine& engine,
                        std::function<void(const juce::String&)> progressCallback,
                        std::function<void()> completionCallback)
        : owner (engine),
          onProgress (std::move (progressCallback)),
          onComplete (std::move (completionCallback))
    {
        owner.getSavedPluginListFile().getParentDirectory().createDirectory();
        formatIndex = 0;
        prepareNextFormat();
        startTimer (1); // Run on the message thread
    }

    ~PluginScannerTimer() override = default;

    void timerCallback() override
    {
        if (scanner == nullptr)
        {
            stopTimer();
            onComplete();
            delete this;
            return;
        }

        juce::String pluginName;
        if (scanner->scanNextFile (true, pluginName))
        {
            if (pluginName.isNotEmpty())
                onProgress (pluginName);
        }
        else
        {
            formatIndex++;
            prepareNextFormat();
        }
    }

private:
    void prepareNextFormat()
    {
        auto& fm = owner.getFormatManager();
        if (formatIndex < fm.getNumFormats())
        {
            auto* format = fm.getFormat (formatIndex);
            scanner = std::make_unique<juce::PluginDirectoryScanner> (
                owner.getKnownPlugins(),
                *format,
                format->getDefaultLocationsToSearch(),
                true,
                owner.getDeadMansPedalFile()
            );
        }
        else
        {
            scanner = nullptr;
            auto listXml = owner.getKnownPlugins().createXml();
            if (listXml != nullptr)
                listXml->writeTo (owner.getSavedPluginListFile());
        }
    }

    AudioEngine& owner;
    std::function<void(const juce::String&)> onProgress;
    std::function<void()> onComplete;
    int formatIndex = 0;
    std::unique_ptr<juce::PluginDirectoryScanner> scanner;
};

void AudioEngine::scanPlugins (std::function<void(const juce::String&)> onProgress,
                               std::function<void()> onComplete)
{
    new PluginScannerTimer (*this, std::move (onProgress), std::move (onComplete));
}

bool AudioEngine::loadPlugin (int slotIndex, const juce::PluginDescription& desc, juce::String& errorMessage)
{
    if (slotIndex < 0 || slotIndex >= totalSlots)
    {
        errorMessage = "Invalid slot index.";
        return false;
    }

    unloadPlugin (slotIndex);

    double sampleRate = 44100.0;
    int blockSize = 512;
    if (auto* device = deviceManager.getCurrentAudioDevice())
    {
        sampleRate = device->getCurrentSampleRate();
        blockSize = device->getCurrentBufferSizeSamples();
    }

    std::unique_ptr<juce::AudioPluginInstance> instance = formatManager.createPluginInstance (
        desc, sampleRate, blockSize, errorMessage);

    if (instance == nullptr)
        return false;

    // Configure sample rate / block size, leaving the plugin's own channel layout
    // intact. NOTE: do NOT call setPlayConfigDetails() with getBusCount() here —
    // its first two arguments are *channel* counts, not *bus* counts. Passing bus
    // counts forces a wrong (mono) layout on stereo plugins.
    instance->setRateAndBufferSizeDetails (sampleRate, blockSize);

    // Fully initialise the plugin now, before its editor can ever be opened. For
    // Audio Units, JUCE only calls AudioUnitInitialize() and builds the parameter
    // list inside prepareToPlay() — so if we relied on the graph (which is only
    // prepared once the audio device starts), an editor opened beforehand would
    // read parameters from an uninitialised unit and crash on first draw. That is
    // exactly what happens with Apple's Graphic EQ. prepareToPlay() starts with
    // releaseResources(), so the graph re-preparing the node later is harmless.
    instance->prepareToPlay (sampleRate, blockSize);

    // Add to graph
    activeNodes[slotIndex] = audioGraph->addNode (std::move (instance));

    updateGraphConnections();
    return true;
}

void AudioEngine::unloadPlugin (int slotIndex)
{
    if (slotIndex < 0 || slotIndex >= totalSlots)
        return;

    // Tear the editor window down through hidePluginEditor so it gets the same
    // crash-sentinel protection as a normal close.
    hidePluginEditor (slotIndex);

    if (activeNodes[slotIndex] != nullptr)
    {
        audioGraph->removeNode (activeNodes[slotIndex].get());
        activeNodes[slotIndex] = nullptr;
    }

    updateGraphConnections();
}

bool AudioEngine::isPluginLoaded (int slotIndex) const
{
    if (slotIndex < 0 || slotIndex >= totalSlots)
        return false;
    return activeNodes[slotIndex] != nullptr;
}

juce::String AudioEngine::getPluginName (int slotIndex) const
{
    if (isPluginLoaded (slotIndex))
        return activeNodes[slotIndex]->getProcessor()->getName();
    return "Empty";
}

//==============================================================================
namespace
{
    // Identifiers of plugins whose *native* editor view is known to crash the host.
    // For Audio Units this string is the component identity (type/subtype/manufacturer)
    // and is identical on every Mac, so it is safe to ship as built-in knowledge.
    // Promote entries here from the learned list (crashing_editors.txt) as they are
    // discovered during testing.
    const char* const kKnownCrashingEditorSeed[] =
    {
        "AudioUnit:Effects/aufx,greq,appl",   // Apple AUGraphicEQ
        "AudioUnit:Effects/aufx,bpas,appl",   // Apple AUBandpass
        "AudioUnit:Effects/aufx,dcmp,appl",   // Apple AUDynamicsProcessor
        "AudioUnit:Effects/aufx,dely,appl",   // Apple AUDelay
        "AudioUnit:Effects/aufx,filt,appl",   // Apple AUFilter
        "AudioUnit:Effects/aufx,hpas,appl",   // Apple AUHighpass
        "AudioUnit:Effects/aufx,hshf,appl",   // Apple AUHighShelfFilter
        "AudioUnit:Effects/aufx,lpas,appl",   // Apple AULowpass
        "AudioUnit:Effects/aufx,lshf,appl",   // Apple AULowShelfFilter
        "AudioUnit:Effects/aufx,mcmp,appl",   // Apple AUMultibandCompressor
        "AudioUnit:Effects/aufx,pmeq,appl",   // Apple AUParametricEQ
        "AudioUnit:Effects/aufx,raac,appl",   // Apple AURoundTripAAC (crashes on close)
        "AudioUnit:Effects/aufx,lmtr,appl",   // Apple AUPeakLimiter
    };

    juce::String getEditorIdentifier (juce::AudioProcessor* processor)
    {
        if (auto* instance = dynamic_cast<juce::AudioPluginInstance*> (processor))
            return instance->getPluginDescription().fileOrIdentifier;

        return {};
    }
}

juce::File AudioEngine::getLearnedCrashFile()
{
    return juce::File::getSpecialLocation (juce::File::userApplicationDataDirectory)
        .getChildFile ("Application Support/VALHost/crashing_editors.txt");
}

juce::File AudioEngine::getPendingEditorFile()
{
    return juce::File::getSpecialLocation (juce::File::userApplicationDataDirectory)
        .getChildFile ("Application Support/VALHost/pending_editor.txt");
}

void AudioEngine::armCrashSentinel (const juce::String& identifier)
{
    if (identifier.isEmpty())
        return;

    auto f = getPendingEditorFile();
    f.getParentDirectory().createDirectory();
    f.replaceWithText (identifier);
}

void AudioEngine::disarmCrashSentinel (const juce::String& identifier)
{
    auto f = getPendingEditorFile();

    // Only clear the sentinel if it still refers to the editor we opened — another
    // editor opened in the meantime may have armed its own.
    if (f.existsAsFile() && f.loadFileAsString().trim() == identifier)
        f.deleteFile();
}

void AudioEngine::rememberCrashingEditor (const juce::String& identifier)
{
    if (identifier.isEmpty() || crashingEditorIds.contains (identifier))
        return;

    crashingEditorIds.add (identifier);

    auto f = getLearnedCrashFile();
    f.getParentDirectory().createDirectory();
    f.appendText (identifier + juce::newLine);
}

void AudioEngine::loadCrashKnowledge()
{
    crashingEditorIds.clearQuick();

    // 1. Built-in seed list (ships with the app).
    for (auto* id : kKnownCrashingEditorSeed)
        crashingEditorIds.add (id);

    // 2. A leftover sentinel means the previous session crashed while opening that
    //    editor — promote it to the learned list permanently.
    auto pending = getPendingEditorFile();
    if (pending.existsAsFile())
    {
        auto crashed = pending.loadFileAsString().trim();
        pending.deleteFile();
        rememberCrashingEditor (crashed);
    }

    // 3. Previously learned identifiers.
    auto learned = getLearnedCrashFile();
    if (learned.existsAsFile())
    {
        juce::StringArray lines;
        lines.addLines (learned.loadFileAsString());

        for (auto& line : lines)
            if (line.trim().isNotEmpty())
                crashingEditorIds.addIfNotAlreadyThere (line.trim());
    }
}

bool AudioEngine::shouldUseGenericEditor (juce::AudioProcessor* processor) const
{
    return crashingEditorIds.contains (getEditorIdentifier (processor));
}

void AudioEngine::showPluginEditor (int slotIndex)
{
    if (slotIndex < 0 || slotIndex >= totalSlots)
        return;

    if (activeNodes[slotIndex] == nullptr)
        return;

    if (activeWindows[slotIndex] != nullptr)
    {
        activeWindows[slotIndex]->toFront (true);
        return;
    }

    auto* processor = activeNodes[slotIndex]->getProcessor();
    const juce::String pluginId = getEditorIdentifier (processor);

    std::unique_ptr<juce::AudioProcessorEditor> editor;
    bool sentinelArmed = false;

    if (! shouldUseGenericEditor (processor) && processor->hasEditor())
    {
        // We have not verified this native view yet. Arm the crash sentinel so that
        // if drawing it kills the app, the next launch learns to avoid it.
        armCrashSentinel (pluginId);
        editor.reset (processor->createEditorIfNeeded());

        if (editor != nullptr)
            sentinelArmed = true;
        else
            disarmCrashSentinel (pluginId); // no native view after all
    }

    // Fall back to JUCE's generic editor whenever there is no usable native view,
    // or when we deliberately avoid a crash-prone one. This guarantees an editor
    // always opens without ever crashing the host.
    if (editor == nullptr)
        editor = std::make_unique<juce::GenericAudioProcessorEditor> (*processor);

    activeWindows[slotIndex] = std::make_unique<PluginWindow> (
        activeNodes[slotIndex].get(),
        std::move (editor),
        [this, slotIndex]() { hidePluginEditor (slotIndex); }
    );

    editorIsNative[slotIndex] = sentinelArmed;

    // The native view survived creation and will draw on the next run-loop cycle.
    // Clear the sentinel after a short delay; if the app crashes first, it persists
    // and the plugin is learned as a crasher on the next launch.
    if (sentinelArmed)
        juce::Timer::callAfterDelay (2000, [pluginId]() { AudioEngine::disarmCrashSentinel (pluginId); });
}

void AudioEngine::hidePluginEditor (int slotIndex)
{
    if (slotIndex < 0 || slotIndex >= totalSlots)
        return;

    if (activeWindows[slotIndex] == nullptr)
        return;

    // A few plugins crash while their *native* editor is torn down (they load and
    // run fine, then die on close). Arm the crash sentinel around the teardown so
    // this is learned just like a crash on open; we disarm shortly after if it
    // closes cleanly. Generic editors are safe, so they are not armed.
    juce::String pluginId;
    if (editorIsNative[slotIndex] && activeNodes[slotIndex] != nullptr)
        pluginId = getEditorIdentifier (activeNodes[slotIndex]->getProcessor());

    armCrashSentinel (pluginId);

    editorIsNative[slotIndex] = false;
    activeWindows[slotIndex] = nullptr;

    if (pluginId.isNotEmpty())
        juce::Timer::callAfterDelay (2000, [pluginId]() { AudioEngine::disarmCrashSentinel (pluginId); });
}

bool AudioEngine::isPluginEditorVisible (int slotIndex) const
{
    if (slotIndex < 0 || slotIndex >= totalSlots)
        return false;
    return activeWindows[slotIndex] != nullptr;
}

void AudioEngine::updateGraphConnections()
{
    if (audioGraph == nullptr)
        return;

    for (auto& c : audioGraph->getConnections())
        audioGraph->removeConnection (c);

    // 1. Connect MIDI Input node to all plugin nodes
    for (int i = 0; i < totalSlots; ++i)
    {
        if (activeNodes[i] != nullptr)
        {
            audioGraph->addConnection ({ { midiInputNode->nodeID, juce::AudioProcessorGraph::midiChannelIndex },
                                         { activeNodes[i]->nodeID, juce::AudioProcessorGraph::midiChannelIndex } });
        }
    }

    // 2. Identify the active audio source: Instrument Node, or Audio Input Node
    juce::AudioProcessorGraph::Node::Ptr currentSource = nullptr;
    if (activeNodes[instrumentSlot] != nullptr)
        currentSource = activeNodes[instrumentSlot];
    else
        currentSource = audioInputNode;

    // 3. Connect the audio source through active effect slots sequentially
    juce::AudioProcessorGraph::Node::Ptr lastNode = currentSource;
    for (int i = 1; i < totalSlots; ++i)
    {
        if (activeNodes[i] != nullptr)
        {
            // Connect lastNode outputs to activeNodes[i] inputs
            for (int ch = 0; ch < 2; ++ch)
            {
                audioGraph->addConnection ({ { lastNode->nodeID, ch },
                                             { activeNodes[i]->nodeID, ch } });
            }
            lastNode = activeNodes[i];
        }
    }

    // 4. Connect the end of the chain to the faderNode
    for (int ch = 0; ch < 2; ++ch)
    {
        audioGraph->addConnection ({ { lastNode->nodeID, ch },
                                     { faderNode->nodeID, ch } });
    }

    // 5. Connect faderNode to the Audio Output node
    for (int ch = 0; ch < 2; ++ch)
    {
        audioGraph->addConnection ({ { faderNode->nodeID, ch },
                                     { audioOutputNode->nodeID, ch } });
    }
}

bool AudioEngine::saveSession (const juce::File& file)
{
    juce::DynamicObject::Ptr state = new juce::DynamicObject();
    state->setProperty ("volume", getFaderGain());
    state->setProperty ("mute", getFaderMute());
    state->setProperty ("solo", getFaderSolo());

    juce::Array<juce::var> slotsArray;
    for (int i = 0; i < totalSlots; ++i)
    {
        juce::DynamicObject::Ptr slotObj = new juce::DynamicObject();
        if (activeNodes[i] != nullptr)
        {
            auto* proc = activeNodes[i]->getProcessor();
            slotObj->setProperty ("loaded", true);
            if (auto* instance = dynamic_cast<juce::AudioPluginInstance*> (proc))
            {
                auto desc = instance->getPluginDescription();
                slotObj->setProperty ("name", desc.name);
                slotObj->setProperty ("uid", desc.uniqueId);
                slotObj->setProperty ("format", desc.pluginFormatName);
                slotObj->setProperty ("file", desc.fileOrIdentifier);
            }
            else
            {
                slotObj->setProperty ("name", proc->getName());
                slotObj->setProperty ("uid", 0);
                slotObj->setProperty ("format", "Unknown");
                slotObj->setProperty ("file", "");
            }

            juce::MemoryBlock mem;
            proc->getStateInformation (mem);
            slotObj->setProperty ("state", mem.toBase64Encoding());
        }
        else
        {
            slotObj->setProperty ("loaded", false);
        }
        slotsArray.add (juce::var (slotObj));
    }
    state->setProperty ("slots", slotsArray);

    juce::var stateVar (state);
    juce::String jsonStr = juce::JSON::toString (stateVar);
    return file.replaceWithText (jsonStr);
}

bool AudioEngine::loadSession (const juce::File& file, juce::String& errorMessage)
{
    juce::var parsedJson = juce::JSON::parse (file);
    if (parsedJson.isUndefined())
    {
        errorMessage = "Failed to parse session file.";
        return false;
    }

    auto* state = parsedJson.getDynamicObject();
    if (state == nullptr)
    {
        errorMessage = "Invalid session format.";
        return false;
    }

    setFaderGain ((float) state->getProperty ("volume"));
    setFaderMute ((bool) state->getProperty ("mute"));
    setFaderSolo ((bool) state->getProperty ("solo"));

    auto* slots = state->getProperty ("slots").getArray();
    if (slots != nullptr)
    {
        for (int i = 0; i < juce::jmin (slots->size(), totalSlots); ++i)
        {
            auto* slotObj = (*slots)[i].getDynamicObject();
            if (slotObj && (bool) slotObj->getProperty ("loaded"))
            {
                juce::PluginDescription desc;
                desc.name = slotObj->getProperty ("name").toString();
                desc.uniqueId = (int) slotObj->getProperty ("uid");
                desc.pluginFormatName = slotObj->getProperty ("format").toString();
                desc.fileOrIdentifier = slotObj->getProperty ("file").toString();

                juce::String err;
                if (loadPlugin (i, desc, err))
                {
                    juce::String stateBase64 = slotObj->getProperty ("state").toString();
                    juce::MemoryBlock mem;
                    if (mem.fromBase64Encoding (stateBase64))
                    {
                        if (activeNodes[i] != nullptr)
                            activeNodes[i]->getProcessor()->setStateInformation (mem.getData(), (int) mem.getSize());
                    }
                }
                else
                {
                    errorMessage += "Failed to load " + desc.name + ": " + err + "\n";
                }
            }
            else
            {
                unloadPlugin (i);
            }
        }
    }

    updateGraphConnections();
    return true;
}

void AudioEngine::changeListenerCallback (juce::ChangeBroadcaster* /*source*/)
{
    // Handle sample rate or buffer size changes
    double sampleRate = 44100.0;
    int blockSize = 512;
    int numInputs = 2;
    int numOutputs = 2;
    if (auto* device = deviceManager.getCurrentAudioDevice())
    {
        sampleRate = device->getCurrentSampleRate();
        blockSize = device->getCurrentBufferSizeSamples();
        numInputs = std::max (2, device->getActiveInputChannels().countNumberOfSetBits());
        numOutputs = std::max (2, device->getActiveOutputChannels().countNumberOfSetBits());
    }
    
    if (audioGraph)
    {
        audioGraph->setPlayConfigDetails (numInputs, numOutputs, sampleRate, blockSize);
        audioGraph->prepareToPlay (sampleRate, blockSize);
        updateGraphConnections();
    }
}

juce::File AudioEngine::getDeadMansPedalFile()
{
    return juce::File::getSpecialLocation (juce::File::userApplicationDataDirectory)
        .getChildFile ("Application Support/VALHost/scanner_pedal.xml");
}

juce::File AudioEngine::getSavedPluginListFile()
{
    return juce::File::getSpecialLocation (juce::File::userApplicationDataDirectory)
        .getChildFile ("Application Support/VALHost/scanned_plugins.xml");
}

//==============================================================================
void AudioEngine::handleNoteOn (juce::MidiKeyboardState* /*state*/, int midiChannel, int midiNoteNumber, float velocity)
{
    if (graphPlayer)
    {
        juce::MidiMessage m (juce::MidiMessage::noteOn (midiChannel, midiNoteNumber, velocity));
        m.setTimeStamp (juce::Time::getMillisecondCounterHiRes() * 0.001);
        graphPlayer->getMidiMessageCollector().addMessageToQueue (m);
    }
}

void AudioEngine::handleNoteOff (juce::MidiKeyboardState* /*state*/, int midiChannel, int midiNoteNumber, float velocity)
{
    if (graphPlayer)
    {
        juce::MidiMessage m (juce::MidiMessage::noteOff (midiChannel, midiNoteNumber, velocity));
        m.setTimeStamp (juce::Time::getMillisecondCounterHiRes() * 0.001);
        graphPlayer->getMidiMessageCollector().addMessageToQueue (m);
    }
}
