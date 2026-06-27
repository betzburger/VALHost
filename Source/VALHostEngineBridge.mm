#import "VALHostEngineBridge.h"
#include "AudioEngine.h"
#include "JuceInitializer.h"

@implementation VALHostEngine
{
    std::unique_ptr<JuceInitializer> _juceInit;
    std::unique_ptr<AudioEngine> _audioEngine;
}

+ (instancetype)sharedInstance
{
    static VALHostEngine* shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[VALHostEngine alloc] init];
    });
    return shared;
}

- (void)initializeEngine
{
    if (!_juceInit)
    {
        _juceInit = std::make_unique<JuceInitializer>();
    }
    if (!_audioEngine)
    {
        _audioEngine = std::make_unique<AudioEngine>();
        _audioEngine->init();
    }
}

- (void)reopenAudioInput
{
    if (_audioEngine) _audioEngine->reopenAudioInput();
}

- (void)shutdownEngine
{
    if (_audioEngine)
    {
        _audioEngine->shutdown();
        _audioEngine = nullptr;
    }
    if (_juceInit)
    {
        _juceInit = nullptr;
    }
}

// Scans
- (void)scanPluginsWithProgress:(void (^)(NSString*))progressBlock
                     completion:(void (^)(void))completionBlock
{
    if (!_audioEngine) return;

    void (^progress)(NSString*) = [progressBlock copy];
    void (^complete)(void) = [completionBlock copy];

    _audioEngine->scanPlugins(
        [progress](const juce::String& name) {
            progress([NSString stringWithUTF8String:name.toRawUTF8()]);
        },
        [complete]() {
            complete();
        }
    );
}

- (NSArray<NSString*>*)getScannedPluginNames
{
    if (!_audioEngine) return @[];
    NSMutableArray* arr = [NSMutableArray array];
    auto types = _audioEngine->getKnownPlugins().getTypes();
    for (auto& desc : types)
    {
        [arr addObject:[NSString stringWithUTF8String:desc.name.toRawUTF8()]];
    }
    return arr;
}

- (NSArray<NSString*>*)getScannedPluginFormats
{
    if (!_audioEngine) return @[];
    NSMutableArray* arr = [NSMutableArray array];
    auto types = _audioEngine->getKnownPlugins().getTypes();
    for (auto& desc : types)
    {
        [arr addObject:[NSString stringWithUTF8String:desc.pluginFormatName.toRawUTF8()]];
    }
    return arr;
}

- (NSArray<NSNumber*>*)getScannedPluginIsInstrument
{
    if (!_audioEngine) return @[];
    NSMutableArray* arr = [NSMutableArray array];
    auto types = _audioEngine->getKnownPlugins().getTypes();
    for (auto& desc : types)
    {
        [arr addObject:@(desc.isInstrument)];
    }
    return arr;
}

// Slot management
- (BOOL)loadPluginAtSlot:(int)slotIndex pluginIndex:(int)pluginIndex error:(NSString**)outError
{
    if (!_audioEngine) return NO;
    auto types = _audioEngine->getKnownPlugins().getTypes();
    if (pluginIndex < 0 || pluginIndex >= (int)types.size())
    {
        if (outError) *outError = @"Plugin index out of bounds";
        return NO;
    }

    auto desc = types[pluginIndex];
    juce::String err;
    if (_audioEngine->loadPlugin(slotIndex, desc, err))
    {
        return YES;
    }
    else
    {
        if (outError) *outError = [NSString stringWithUTF8String:err.toRawUTF8()];
        return NO;
    }
}

- (void)unloadPluginAtSlot:(int)slotIndex
{
    if (_audioEngine) _audioEngine->unloadPlugin(slotIndex);
}

- (BOOL)isPluginLoadedAtSlot:(int)slotIndex
{
    return _audioEngine ? _audioEngine->isPluginLoaded(slotIndex) : NO;
}

- (NSString*)getPluginNameAtSlot:(int)slotIndex
{
    if (!_audioEngine) return @"Empty";
    return [NSString stringWithUTF8String:_audioEngine->getPluginName(slotIndex).toRawUTF8()];
}

- (void)showPluginEditorAtSlot:(int)slotIndex
{
    if (_audioEngine)
    {
        juce::MessageManager::callAsync([self, slotIndex]() {
            if (self->_audioEngine) self->_audioEngine->showPluginEditor(slotIndex);
        });
    }
}

- (void)hidePluginEditorAtSlot:(int)slotIndex
{
    if (_audioEngine)
    {
        juce::MessageManager::callAsync([self, slotIndex]() {
            if (self->_audioEngine) self->_audioEngine->hidePluginEditor(slotIndex);
        });
    }
}

// Per-slot bypass
- (void)setBypassAtSlot:(int)slotIndex bypassed:(BOOL)bypassed
{
    if (_audioEngine) _audioEngine->setSlotBypassed(slotIndex, bypassed);
}

- (BOOL)isBypassedAtSlot:(int)slotIndex
{
    return _audioEngine ? _audioEngine->isSlotBypassed(slotIndex) : NO;
}

// Master controls
- (float)getVolume
{
    return _audioEngine ? _audioEngine->getFaderGain() : 1.0f;
}

- (void)setVolume:(float)volume
{
    if (_audioEngine) _audioEngine->setVolumeFromUI(volume);
}

- (BOOL)getMute
{
    return _audioEngine ? _audioEngine->getFaderMute() : NO;
}

- (void)setMute:(BOOL)mute
{
    if (_audioEngine) _audioEngine->setMuteFromUI(mute);
}

// Metering & Info
- (float)getLeftLevel
{
    return _audioEngine ? _audioEngine->getLeftLevel() : 0.0f;
}

- (float)getRightLevel
{
    return _audioEngine ? _audioEngine->getRightLevel() : 0.0f;
}

- (float)getCpuUsage
{
    return _audioEngine ? (float)_audioEngine->getAudioDeviceManager().getCpuUsage() : 0.0f;
}

// Settings
- (void)showAudioSettingsDialog
{
    if (!_audioEngine) return;
    juce::MessageManager::callAsync([self]() {
        if (!self->_audioEngine) return;

        auto selector = std::make_unique<juce::AudioDeviceSelectorComponent> (
            self->_audioEngine->getAudioDeviceManager(),
            0, 2, // inputs
            2, 2, // outputs
            true, // show midi inputs
            false, // hide midi outputs
            true, // channels as stereo pairs
            false // hide advanced options
        );
        selector->setSize (460, 320);

        juce::DialogWindow::LaunchOptions options;
        options.content.setOwned (selector.release());
        options.dialogTitle = "Audio & MIDI Settings";
        options.dialogBackgroundColour = juce::Colour (0xff1f1f1f);
        options.escapeKeyTriggersCloseButton = true;
        options.useNativeTitleBar = true;
        options.resizable = false;

        options.launchAsync();
    });
}

// MIDI
- (void)sendMidiNoteOn:(int)note velocity:(int)velocity
{
    if (!_audioEngine) return;
    _audioEngine->getMidiKeyboardState().noteOn(1, note, (float)velocity / 127.0f);
}

- (void)sendMidiNoteOff:(int)note
{
    if (!_audioEngine) return;
    _audioEngine->getMidiKeyboardState().noteOff(1, note, 0.0f);
}

- (void)sendAllNotesOff
{
    if (_audioEngine) _audioEngine->sendPanic();
}

// Sessions
- (BOOL)saveSessionToFile:(NSString*)path
{
    if (!_audioEngine) return NO;
    juce::File file ([path UTF8String]);
    return _audioEngine->saveSession(file);
}

- (BOOL)loadSessionFromFile:(NSString*)path error:(NSString**)outError
{
    if (!_audioEngine) return NO;
    juce::File file ([path UTF8String]);
    juce::String err;
    if (_audioEngine->loadSession(file, err))
    {
        return YES;
    }
    else
    {
        if (outError) *outError = [NSString stringWithUTF8String:err.toRawUTF8()];
        return NO;
    }
}

@end
