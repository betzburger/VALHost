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

    // Written by reattach() on the HAL notification thread, read by push*() on
    // the message thread.
    std::atomic<AudioObjectID> device { kAudioObjectUnknown };

    // Echo guards: the value we last wrote and whose change notification has not
    // arrived yet. Each one swallows exactly ONE matching notification and is then
    // cleared, so a later genuine change back to the same value (e.g. the mute key
    // pressed twice after a UI mute) is never mistaken for an echo.
    std::atomic<float> pendingEchoScalar { -1.0f };
    std::atomic<int>   pendingEchoMute   { -1 };

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
        const AudioObjectID old = device.exchange (kAudioObjectUnknown);
        if (old != kAudioObjectUnknown)
        {
            AudioObjectRemovePropertyListener (old, &kVolumeScalarAddr, &propProc, this);
            AudioObjectRemovePropertyListener (old, &kMuteAddr,         &propProc, this);
        }
        pendingEchoScalar.store (-1.0f);
        pendingEchoMute.store (-1);
    }

    void reattach()
    {
        AudioObjectID found = findDeviceByUID (kValDriverUID);
        if (found == device.load())
            return;

        detachDevice();

        if (found != kAudioObjectUnknown)
        {
            AudioObjectAddPropertyListener (found, &kVolumeScalarAddr, &propProc, this);
            AudioObjectAddPropertyListener (found, &kMuteAddr,         &propProc, this);
            device.store (found);

            // The driver just appeared (at start, or installed/restarted while
            // VALHost runs): make it agree with VALHost's current value.
            if (owner.queryVolume)  pushVolume (owner.queryVolume());
            if (owner.queryMute)    pushMute (owner.queryMute());
        }
    }

    void pushVolume (float scalar)
    {
        const AudioObjectID dev = device.load();
        if (dev == kAudioObjectUnknown)
            return;

        // Writing the value the driver already holds provokes no notification,
        // so it must not arm the echo guard either.
        Float32 current = 0.0f;
        UInt32 size = sizeof (current);
        if (AudioObjectGetPropertyData (dev, &kVolumeScalarAddr, 0, nullptr, &size, &current) == noErr
             && std::abs (current - scalar) <= 1.0e-4f)
            return;

        Float32 s = scalar;
        pendingEchoScalar.store (s);
        if (AudioObjectSetPropertyData (dev, &kVolumeScalarAddr, 0, nullptr, sizeof (s), &s) != noErr)
            pendingEchoScalar.store (-1.0f);
    }

    void pushMute (bool mute)
    {
        const AudioObjectID dev = device.load();
        if (dev == kAudioObjectUnknown)
            return;

        UInt32 m = mute ? 1 : 0;
        UInt32 current = 0;
        UInt32 size = sizeof (current);
        if (AudioObjectGetPropertyData (dev, &kMuteAddr, 0, nullptr, &size, &current) == noErr
             && (current != 0) == mute)
            return;

        pendingEchoMute.store ((int) m);
        if (AudioObjectSetPropertyData (dev, &kMuteAddr, 0, nullptr, sizeof (m), &m) != noErr)
            pendingEchoMute.store (-1);
    }

    void volumeChangedExternally()
    {
        const AudioObjectID dev = device.load();
        if (dev == kAudioObjectUnknown)
            return;
        Float32 scalar = 0.0f;
        UInt32 size = sizeof (scalar);
        if (AudioObjectGetPropertyData (dev, &kVolumeScalarAddr, 0, nullptr, &size, &scalar) != noErr)
            return;

        // Consume the pending echo either way: a matching value is our own push,
        // anything else means an outside change superseded it.
        const float echo = pendingEchoScalar.exchange (-1.0f);
        if (echo >= 0.0f && std::abs (scalar - echo) <= 1.0e-4f)
            return;                              // echo of our own push
        if (owner.onExternalVolume)
            owner.onExternalVolume (scalar);
    }

    void muteChangedExternally()
    {
        const AudioObjectID dev = device.load();
        if (dev == kAudioObjectUnknown)
            return;
        UInt32 m = 0;
        UInt32 size = sizeof (m);
        if (AudioObjectGetPropertyData (dev, &kMuteAddr, 0, nullptr, &size, &m) != noErr)
            return;

        const int echo = pendingEchoMute.exchange (-1);
        if (echo >= 0 && (m != 0) == (echo != 0))
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
