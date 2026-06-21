#import <Foundation/Foundation.h>

@interface VALHostEngine : NSObject

+ (instancetype)sharedInstance;

- (void)initializeEngine;
- (void)shutdownEngine;

// Scans
- (void)scanPluginsWithProgress:(void (^)(NSString* progressMsg))progressBlock
                     completion:(void (^)(void))completionBlock
                     NS_SWIFT_NAME(scanPlugins(progress:completion:));

- (NSArray<NSString*>*)getScannedPluginNames;
- (NSArray<NSString*>*)getScannedPluginFormats;
- (NSArray<NSNumber*>*)getScannedPluginIsInstrument;

// Slot management
- (BOOL)loadPluginAtSlot:(int)slotIndex pluginIndex:(int)pluginIndex error:(NSString**)outError;
- (void)unloadPluginAtSlot:(int)slotIndex;
- (BOOL)isPluginLoadedAtSlot:(int)slotIndex;
- (NSString*)getPluginNameAtSlot:(int)slotIndex;
- (void)showPluginEditorAtSlot:(int)slotIndex;
- (void)hidePluginEditorAtSlot:(int)slotIndex;

// Master controls
- (float)getVolume;
- (void)setVolume:(float)volume;
- (BOOL)getMute;
- (void)setMute:(BOOL)mute;
- (BOOL)getSolo;
- (void)setSolo:(BOOL)solo;

// Metering & Info
- (float)getLeftLevel;
- (float)getRightLevel;
- (float)getCpuUsage;

// Settings
- (void)showAudioSettingsDialog;

// MIDI
- (void)sendMidiNoteOn:(int)note velocity:(int)velocity NS_SWIFT_NAME(sendMidiNoteOn(_:velocity:));
- (void)sendMidiNoteOff:(int)note NS_SWIFT_NAME(sendMidiNoteOff(_:));

// Sessions
- (BOOL)saveSessionToFile:(NSString*)path;
- (BOOL)loadSessionFromFile:(NSString*)path error:(NSString**)outError;

@end
