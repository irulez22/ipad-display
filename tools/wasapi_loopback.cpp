#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <vector>
#include <algorithm>

template <typename T>
static void safe_release(T **p) {
    if (p && *p) { (*p)->Release(); *p = nullptr; }
}

static float clamp_unit(float v) {
    if (v < -1.0f) return -1.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

static bool guid_equal(const GUID &a, const GUID &b) {
    return InlineIsEqualGUID(a, b) != 0;
}

struct AudioFormatInfo {
    bool isFloat = false;
    bool isPCM = false;
    WORD channels = 0;
    DWORD sampleRate = 0;
    WORD containerBits = 0;
    WORD validBits = 0;
    WORD blockAlign = 0;
};

static bool parse_format(const WAVEFORMATEX *fmt, AudioFormatInfo &out)
{
    if (!fmt || !fmt->nChannels || !fmt->nSamplesPerSec || !fmt->nBlockAlign) return false;

    out.channels = fmt->nChannels;
    out.sampleRate = fmt->nSamplesPerSec;
    out.containerBits = fmt->wBitsPerSample;
    out.validBits = fmt->wBitsPerSample;
    out.blockAlign = fmt->nBlockAlign;

    if (fmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        out.isFloat = true;
        return fmt->wBitsPerSample == 32;
    }

    if (fmt->wFormatTag == WAVE_FORMAT_PCM) {
        out.isPCM = true;
        return fmt->wBitsPerSample == 16 || fmt->wBitsPerSample == 24 || fmt->wBitsPerSample == 32;
    }

    if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
        fmt->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
        const WAVEFORMATEXTENSIBLE *ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(fmt);
        out.validBits = ext->Samples.wValidBitsPerSample ? ext->Samples.wValidBitsPerSample : fmt->wBitsPerSample;
        if (guid_equal(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)) {
            out.isFloat = true;
            return fmt->wBitsPerSample == 32;
        }
        if (guid_equal(ext->SubFormat, KSDATAFORMAT_SUBTYPE_PCM)) {
            out.isPCM = true;
            return fmt->wBitsPerSample == 16 || fmt->wBitsPerSample == 24 || fmt->wBitsPerSample == 32;
        }
    }

    return false;
}

static float read_sample(const BYTE *p, const AudioFormatInfo &fmt)
{
    if (fmt.isFloat && fmt.containerBits == 32) {
        float v;
        memcpy(&v, p, sizeof(v));
        return clamp_unit(v);
    }

    if (!fmt.isPCM) return 0.0f;

    if (fmt.containerBits == 16) {
        int16_t v;
        memcpy(&v, p, sizeof(v));
        return (float)v / 32768.0f;
    }

    if (fmt.containerBits == 24) {
        int32_t v = (int32_t)p[0] | ((int32_t)p[1] << 8) | ((int32_t)p[2] << 16);
        if (v & 0x00800000) v |= ~0x00ffffff;
        return (float)v / 8388608.0f;
    }

    if (fmt.containerBits == 32) {
        int32_t v;
        memcpy(&v, p, sizeof(v));
        const int bits = fmt.validBits > 0 && fmt.validBits <= 32 ? fmt.validBits : 32;
        const double denom = bits == 32 ? 2147483648.0 : (double)(1ULL << (bits - 1));
        if (bits < 32) v >>= (32 - bits);
        return (float)((double)v / denom);
    }

    return 0.0f;
}

static int16_t to_s16(float v)
{
    v = clamp_unit(v);
    int sample = (int)lrintf(v * 32767.0f);
    if (sample < -32768) sample = -32768;
    if (sample > 32767) sample = 32767;
    return (int16_t)sample;
}

int wmain()
{
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) return 2;

    IMMDeviceEnumerator *enumerator = nullptr;
    IMMDevice *device = nullptr;
    IAudioClient *audio = nullptr;
    IAudioCaptureClient *capture = nullptr;
    WAVEFORMATEX *mix = nullptr;

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), (void **)&enumerator);
    if (FAILED(hr)) goto fail;

    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) goto fail;

    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void **)&audio);
    if (FAILED(hr)) goto fail;

    hr = audio->GetMixFormat(&mix);
    if (FAILED(hr) || !mix) goto fail;

    AudioFormatInfo inputFmt;
    if (!parse_format(mix, inputFmt)) {
        fwprintf(stderr, L"Unsupported Windows mix format: tag=%u channels=%u rate=%lu bits=%u align=%u\n",
                 mix->wFormatTag, mix->nChannels, mix->nSamplesPerSec,
                 mix->wBitsPerSample, mix->nBlockAlign);
        hr = E_FAIL;
        goto fail;
    }

    fwprintf(stderr, L"WASAPI mix: %lu Hz, %u ch, %u-bit%s; output 48000 Hz stereo s16le\n",
             inputFmt.sampleRate, inputFmt.channels, inputFmt.containerBits,
             inputFmt.isFloat ? L" float" : L" PCM");

    hr = audio->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK,
        1000000,
        0,
        mix,
        nullptr
    );
    if (FAILED(hr)) goto fail;

    hr = audio->GetService(__uuidof(IAudioCaptureClient), (void **)&capture);
    if (FAILED(hr)) goto fail;

    hr = audio->Start();
    if (FAILED(hr)) goto fail;

    setvbuf(stdout, nullptr, _IONBF, 0);

    uint64_t resampleAccumulator = 0;
    const uint64_t outputRate = 48000;

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

            std::vector<int16_t> output;
            const size_t estimatedFrames =
                (size_t)(((uint64_t)frames * outputRate + inputFmt.sampleRate - 1) / inputFmt.sampleRate) + 2;
            output.reserve(estimatedFrames * 2);

            const bool silent = (captureFlags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
            const size_t bytesPerContainerSample = inputFmt.containerBits / 8;

            for (UINT32 i = 0; i < frames; ++i) {
                float left = 0.0f;
                float right = 0.0f;

                if (!silent) {
                    const BYTE *frame = data + (size_t)i * inputFmt.blockAlign;
                    left = read_sample(frame, inputFmt);
                    if (inputFmt.channels >= 2) {
                        right = read_sample(frame + bytesPerContainerSample, inputFmt);
                    } else {
                        right = left;
                    }
                }

                resampleAccumulator += outputRate;
                while (resampleAccumulator >= inputFmt.sampleRate) {
                    resampleAccumulator -= inputFmt.sampleRate;
                    output.push_back(to_s16(left));
                    output.push_back(to_s16(right));
                }
            }

            if (!output.empty()) {
                const size_t bytes = output.size() * sizeof(int16_t);
                if (fwrite(output.data(), 1, bytes, stdout) != bytes) {
                    capture->ReleaseBuffer(frames);
                    goto done;
                }
            }

            capture->ReleaseBuffer(frames);
            hr = capture->GetNextPacketSize(&packetFrames);
            if (FAILED(hr)) goto done;
        }
    }

done:
    if (audio) audio->Stop();

fail:
    if (mix) CoTaskMemFree(mix);
    safe_release(&capture);
    safe_release(&audio);
    safe_release(&device);
    safe_release(&enumerator);
    CoUninitialize();
    return FAILED(hr) ? 1 : 0;
}
