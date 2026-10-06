#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <cstdio>
#include <cstdint>
#include <vector>

template <typename T>
static void safe_release(T **p) {
    if (p && *p) { (*p)->Release(); *p = nullptr; }
}

int wmain()
{
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) return 2;

    IMMDeviceEnumerator *enumerator = nullptr;
    IMMDevice *device = nullptr;
    IAudioClient *audio = nullptr;
    IAudioCaptureClient *capture = nullptr;

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), (void **)&enumerator);
    if (FAILED(hr)) goto fail;

    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) goto fail;

    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&audio);
    if (FAILED(hr)) goto fail;

    WAVEFORMATEX fmt = {};
    fmt.wFormatTag = WAVE_FORMAT_PCM;
    fmt.nChannels = 2;
    fmt.nSamplesPerSec = 48000;
    fmt.wBitsPerSample = 16;
    fmt.nBlockAlign = (fmt.nChannels * fmt.wBitsPerSample) / 8;
    fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
    fmt.cbSize = 0;

    const DWORD flags = AUDCLNT_STREAMFLAGS_LOOPBACK |
                        AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                        AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;

    hr = audio->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 1000000, 0, &fmt, nullptr);
    if (FAILED(hr)) goto fail;

    hr = audio->GetService(__uuidof(IAudioCaptureClient), (void **)&capture);
    if (FAILED(hr)) goto fail;

    hr = audio->Start();
    if (FAILED(hr)) goto fail;

    setvbuf(stdout, nullptr, _IONBF, 0);

    for (;;) {
        UINT32 packetFrames = 0;
        hr = capture->GetNextPacketSize(&packetFrames);
        if (FAILED(hr)) break;

        if (!packetFrames) {
            Sleep(3);
            continue;
        }

        while (packetFrames) {
            BYTE *data = nullptr;
            UINT32 frames = 0;
            DWORD captureFlags = 0;
            hr = capture->GetBuffer(&data, &frames, &captureFlags, nullptr, nullptr);
            if (FAILED(hr)) goto done;

            const size_t bytes = (size_t)frames * fmt.nBlockAlign;
            if (captureFlags & AUDCLNT_BUFFERFLAGS_SILENT) {
                static const uint8_t zeros[4096] = {};
                size_t left = bytes;
                while (left) {
                    size_t n = left > sizeof(zeros) ? sizeof(zeros) : left;
                    if (fwrite(zeros, 1, n, stdout) != n) {
                        capture->ReleaseBuffer(frames);
                        goto done;
                    }
                    left -= n;
                }
            } else if (bytes && fwrite(data, 1, bytes, stdout) != bytes) {
                capture->ReleaseBuffer(frames);
                goto done;
            }

            capture->ReleaseBuffer(frames);
            hr = capture->GetNextPacketSize(&packetFrames);
            if (FAILED(hr)) goto done;
        }
    }

done:
    if (audio) audio->Stop();
fail:
    safe_release(&capture);
    safe_release(&audio);
    safe_release(&device);
    safe_release(&enumerator);
    CoUninitialize();
    return FAILED(hr) ? 1 : 0;
}
