#pragma once

#include <functional>

//==============================================================================
// SystemVolumeLink — bridges VALHost's fader to VALDriver's volume/mute control
// through the Core Audio HAL.
//
// It is deliberately self-contained: this header pulls in neither JUCE nor any
// Core Audio header, so it can be included from the JUCE side without the
// notorious juce::Point / juce::AudioBuffer clashes against MacTypes.h /
// CoreAudioBaseTypes.h. All Core Audio work lives in SystemVolumeLink.mm.
//
// VALDriver owns the single shared value: a 0..1 volume "scalar" that doubles as
// the fader position. When the macOS volume keys move that control, onExternal*
// fires; when the VALHost fader moves, the owner calls push*(). Echoes of our
// own pushes are suppressed internally, so onExternal* only reports genuine
// outside changes.
class SystemVolumeLink
{
public:
    SystemVolumeLink();
    ~SystemVolumeLink();

    // Fired when VALDriver's control changes from outside VALHost (e.g. the
    // macOS volume keys). Set these before calling start(). Always delivered on
    // a Core Audio callback thread.
    std::function<void (float scalar)> onExternalVolume;   // scalar in [0,1]
    std::function<void (bool  mute)>   onExternalMute;

    // Begin/stop tracking the VALDriver device. Safe to call when the driver is
    // not installed (start() simply stays unbound until it appears).
    void start();
    void stop();

    // Mirror VALHost's current value onto VALDriver (no-op while unbound).
    void pushVolume (float scalar);   // scalar in [0,1]
    void pushMute   (bool  mute);

    bool isBound() const;

private:
    struct Impl;
    Impl* impl = nullptr;

    SystemVolumeLink (const SystemVolumeLink&) = delete;
    SystemVolumeLink& operator= (const SystemVolumeLink&) = delete;
};
