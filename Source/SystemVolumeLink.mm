#include "SystemVolumeLink.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <cmath>

// Newer SDKs renamed kAudioObjectPropertyElementMaster -> ...Main.
#ifndef kAudioObjectPropertyElementMain
 #define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

namespace
{
    // VALDriver's device UID (matches kDeviceUID in VALDriver.c).
    constexpr const char* kValDriverUID = "com.val.VALDriver.device";

    const AudioObjectPropertyAddress kVolumeScalarAddr =
        { kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    const AudioObjectPropertyAddress kMuteAddr =
        { kAudioDevicePropertyMute,         kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
    const AudioObjectPropertyAddress kDevicesAddr =
        { kAudioHardwarePropertyDevices,    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };

    AudioObjectID findDeviceByUID (const char* uidUtf8)
    {
        CFStringRef uid = CFStringCreateWithCString (nullptr, uidUtf8, kCFStringEncodingUTF8);
        if (uid == nullptr)
            return kAudioObjectUnknown;

        AudioObjectID device = kAudioObjectUnknown;
        AudioObjectPropertyAddress addr =
            { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 size = sizeof (device);
        OSStatus err = AudioObjectGetPropertyData (kAudioObjectSystemObject, &addr,
                                                   sizeof (uid), &uid, &size, &device);
        CFRelease (uid);
        return (err == noErr) ? device : kAudioObjectUnknown;
    }
}

//==============================================================================
struct SystemVolumeLink::Impl
{
    SystemVolumeLink& owner;
    AudioObjectID device { kAudioObjectUnknown };

    // Re-entrancy guards: the value we last wrote, so the listener can ignore the
    // notification our own write provokes.
    std::atomic<float> lastPushedScalar { -1.0f };
    std::atomic<int>   lastPushedMute   { -1 };

    explicit Impl (SystemVolumeLink& o) : owner (o) {}

    void start()
    {
        AudioObjectAddPropertyListener (kAudioObjectSystemObject, &kDevicesAddr, &devicesProc, this);
        reattach();
    }

    void stop()
    {
        AudioObjectRemovePropertyListener (kAudioObjectSystemObject, &kDevicesAddr, &devicesProc, this);
        detachDevice();
    }

    void detachDevice()
    {
        if (device != kAudioObjectUnknown)
        {
            AudioObjectRemovePropertyListener (device, &kVolumeScalarAddr, &propProc, this);
            AudioObjectRemovePropertyListener (device, &kMuteAddr,         &propProc, this);
            device = kAudioObjectUnknown;
        }
    }

    void reattach()
    {
        AudioObjectID found = findDeviceByUID (kValDriverUID);
        if (found == device)
            return;

        detachDevice();
        device = found;

        if (device != kAudioObjectUnknown)
        {
            AudioObjectAddPropertyListener (device, &kVolumeScalarAddr, &propProc, this);
            AudioObjectAddPropertyListener (device, &kMuteAddr,         &propProc, this);
        }
    }

    void pushVolume (float scalar)
    {
        if (device == kAudioObjectUnknown)
            return;
        Float32 s = scalar;
        lastPushedScalar.store (s);
        AudioObjectSetPropertyData (device, &kVolumeScalarAddr, 0, nullptr, sizeof (s), &s);
    }

    void pushMute (bool mute)
    {
        if (device == kAudioObjectUnknown)
            return;
        UInt32 m = mute ? 1 : 0;
        lastPushedMute.store ((int) m);
        AudioObjectSetPropertyData (device, &kMuteAddr, 0, nullptr, sizeof (m), &m);
    }

    void volumeChangedExternally()
    {
        if (device == kAudioObjectUnknown)
            return;
        Float32 scalar = 0.0f;
        UInt32 size = sizeof (scalar);
        if (AudioObjectGetPropertyData (device, &kVolumeScalarAddr, 0, nullptr, &size, &scalar) != noErr)
            return;
        if (std::abs (scalar - lastPushedScalar.load()) <= 1.0e-4f)
            return;                              // echo of our own push
        if (owner.onExternalVolume)
            owner.onExternalVolume (scalar);
    }

    void muteChangedExternally()
    {
        if (device == kAudioObjectUnknown)
            return;
        UInt32 m = 0;
        UInt32 size = sizeof (m);
        if (AudioObjectGetPropertyData (device, &kMuteAddr, 0, nullptr, &size, &m) != noErr)
            return;
        if ((int) m == lastPushedMute.load())
            return;                              // echo of our own push
        if (owner.onExternalMute)
            owner.onExternalMute (m != 0);
    }

    static OSStatus propProc (AudioObjectID, UInt32 numAddresses,
                              const AudioObjectPropertyAddress* addresses, void* clientData)
    {
        auto* self = static_cast<Impl*> (clientData);
        if (self == nullptr)
            return noErr;
        for (UInt32 i = 0; i < numAddresses; ++i)
        {
            if (addresses[i].mSelector == kAudioDevicePropertyVolumeScalar)
                self->volumeChangedExternally();
            else if (addresses[i].mSelector == kAudioDevicePropertyMute)
                self->muteChangedExternally();
        }
        return noErr;
    }

    static OSStatus devicesProc (AudioObjectID, UInt32, const AudioObjectPropertyAddress*, void* clientData)
    {
        if (auto* self = static_cast<Impl*> (clientData))
            self->reattach();
        return noErr;
    }
};

//==============================================================================
SystemVolumeLink::SystemVolumeLink()  : impl (new Impl (*this)) {}
SystemVolumeLink::~SystemVolumeLink() { if (impl) { impl->stop(); delete impl; } }

void SystemVolumeLink::start()              { if (impl) impl->start(); }
void SystemVolumeLink::stop()               { if (impl) impl->stop(); }
void SystemVolumeLink::pushVolume (float s) { if (impl) impl->pushVolume (s); }
void SystemVolumeLink::pushMute   (bool m)  { if (impl) impl->pushMute (m); }
bool SystemVolumeLink::isBound() const      { return impl && impl->device != kAudioObjectUnknown; }
