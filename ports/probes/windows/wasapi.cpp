#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>

// The runner has a Windows SDK but may have no render or capture endpoint.
HRESULT open_capture_endpoint(IMMDeviceEnumerator& devices, bool loopback, IMMDevice** endpoint) {
    return devices.GetDefaultAudioEndpoint(loopback ? eRender : eCapture, eConsole, endpoint);
}

HRESULT initialize_capture(IAudioClient& client, bool loopback, const WAVEFORMATEX& format) {
    return client.Initialize(AUDCLNT_SHAREMODE_SHARED,
                             loopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0,
                             0, 0, &format, nullptr);
}
