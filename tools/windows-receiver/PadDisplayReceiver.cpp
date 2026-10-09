#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <windowsx.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <d3d11.h>
#include <d3d10.h>
#include <dxgi1_2.h>
#include <dxgi1_3.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <cstdarg>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "wmcodecdspuuid.lib")

using Microsoft::WRL::ComPtr;

static constexpr uint8_t VIDEO_H264 = 0x01;
static constexpr uint8_t CONFIG = 0x03;
static constexpr uint8_t DISCONNECT = 0x04;
static constexpr uint8_t TOUCH_V1 = 0x10;
static constexpr uint8_t TOUCH_V2 = 0x11;
static constexpr uint8_t MOUSE_V1 = 0x12;
static constexpr uint8_t KEYBOARD_V1 = 0x13;
static constexpr uint8_t AUDIO_PCM = 0x20;
static constexpr uint8_t AUDIO_PCM_V2 = 0x21;
static constexpr UINT WM_APP_FRAME = WM_APP + 1;
static constexpr UINT WM_APP_STATUS = WM_APP + 2;

static HWND g_hwnd = nullptr;
static std::atomic<bool> g_running{true};
static std::atomic<bool> g_connected{false};
static SOCKET g_client = INVALID_SOCKET;
static std::mutex g_sendMutex;
static int g_streamWidth = 1366;
static int g_streamHeight = 768;
static bool g_fullscreen = true;
static WINDOWPLACEMENT g_windowPlacement{ sizeof(WINDOWPLACEMENT) };
static std::atomic<uint64_t> g_videoPackets{0};
static std::atomic<uint64_t> g_videoBytes{0};
static std::atomic<uint64_t> g_accessUnits{0};
static std::atomic<uint64_t> g_decodedFrames{0};
static std::atomic<uint64_t> g_presentedFrames{0};
static std::atomic<unsigned long> g_lastHr{0};
static std::atomic<uint64_t> g_decoderErrors{0};
static std::atomic<uint64_t> g_reconnects{0};
static std::atomic<uint64_t> g_auQueueHighWater{0};
static std::atomic<uint64_t> g_presentQueueHighWater{0};
static std::atomic<uint64_t> g_decodeStalls{0};
static std::atomic<uint64_t> g_presentStalls{0};
static std::atomic<uint64_t> g_audioPackets{0};
static std::atomic<uint64_t> g_audioBytes{0};
static std::atomic<uint64_t> g_audioErrors{0};

static constexpr size_t AU_QUEUE_MAX = 2;
static constexpr size_t PRESENT_QUEUE_MAX = 1;

static std::mutex g_auMutex;
static std::condition_variable g_auCvNotEmpty;
static std::condition_variable g_auCvNotFull;
static std::deque<std::vector<uint8_t>> g_auQueue;

static std::mutex g_presentMutex;
static std::condition_variable g_presentCvNotEmpty;
static std::condition_variable g_presentCvNotFull;
static std::deque<ComPtr<IMFSample>> g_presentQueue;

static std::atomic<bool> g_decoderResetRequested{false};
static std::mutex g_logMutex;
static FILE* g_logFile = nullptr;
static std::wstring g_logPath;

static void InitLog() {
    wchar_t localAppData[MAX_PATH]{};
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", localAppData, ARRAYSIZE(localAppData));
    if (n == 0 || n >= ARRAYSIZE(localAppData)) return;

    std::wstring dir = std::wstring(localAppData) + L"\\PadDisplayReceiver";
    CreateDirectoryW(dir.c_str(), nullptr);
    g_logPath = dir + L"\\receiver.log";

    WIN32_FILE_ATTRIBUTE_DATA fad{};
    if (GetFileAttributesExW(g_logPath.c_str(), GetFileExInfoStandard, &fad)) {
        ULARGE_INTEGER size{};
        size.HighPart = fad.nFileSizeHigh;
        size.LowPart = fad.nFileSizeLow;
        if (size.QuadPart > 2ull * 1024ull * 1024ull) {
            std::wstring oldPath = dir + L"\\receiver.old.log";
            DeleteFileW(oldPath.c_str());
            MoveFileW(g_logPath.c_str(), oldPath.c_str());
        }
    }
    _wfopen_s(&g_logFile, g_logPath.c_str(), L"a+, ccs=UTF-8");
}

static void Logf(const wchar_t* fmt, ...) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    if (!g_logFile) return;

    SYSTEMTIME st{};
    GetLocalTime(&st);
    fwprintf(g_logFile, L"%04u-%02u-%02u %02u:%02u:%02u.%03u ",
             st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);

    va_list args;
    va_start(args, fmt);
    vfwprintf(g_logFile, fmt, args);
    va_end(args);
    fputws(L"\n", g_logFile);
    fflush(g_logFile);
}

static void CloseLog() {
    std::lock_guard<std::mutex> lock(g_logMutex);
    if (g_logFile) {
        fclose(g_logFile);
        g_logFile = nullptr;
    }
}

static void UpdateHighWater(std::atomic<uint64_t>& target, uint64_t value) {
    uint64_t current = target.load();
    while (value > current && !target.compare_exchange_weak(current, value)) {}
}

static bool QueueAccessUnit(std::vector<uint8_t>&& au) {
    std::unique_lock<std::mutex> lock(g_auMutex);
    auto waitStart = std::chrono::steady_clock::now();
    g_auCvNotFull.wait(lock, [] {
        return !g_running || !g_connected || g_auQueue.size() < AU_QUEUE_MAX;
    });
    auto waited = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - waitStart).count();
    if (waited >= 10) ++g_decodeStalls;
    if (!g_running || !g_connected) return false;
    g_auQueue.emplace_back(std::move(au));
    UpdateHighWater(g_auQueueHighWater, g_auQueue.size());
    lock.unlock();
    g_auCvNotEmpty.notify_one();
    return true;
}

static bool QueuePresentSample(IMFSample* sample) {
    if (!sample) return false;
    ComPtr<IMFSample> hold = sample;

    std::unique_lock<std::mutex> lock(g_presentMutex);
    auto waitStart = std::chrono::steady_clock::now();
    g_presentCvNotFull.wait(lock, [] {
        return !g_running || !g_connected || g_presentQueue.size() < PRESENT_QUEUE_MAX;
    });
    auto waited = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - waitStart).count();
    if (waited >= 10) ++g_presentStalls;
    if (!g_running || !g_connected) return false;
    g_presentQueue.emplace_back(std::move(hold));
    UpdateHighWater(g_presentQueueHighWater, g_presentQueue.size());
    lock.unlock();
    g_presentCvNotEmpty.notify_one();
    return true;
}

static std::wstring Utf8ToWide(const std::string& s) {
    if (s.empty()) return L"";
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), out.data(), n);
    return out;
}

static bool ReadExact(SOCKET s, void* dst, int bytes) {
    char* p = static_cast<char*>(dst);
    int got = 0;
    while (got < bytes && g_running) {
        fd_set set{};
        FD_ZERO(&set); FD_SET(s, &set);
        timeval timeout{1, 0};
        int ready = select(0, &set, nullptr, nullptr, &timeout);
        if (ready == SOCKET_ERROR) return false;
        if (!ready) continue;
        int n = recv(s, p + got, bytes - got, 0);
        if (n <= 0) return false;
        got += n;
    }
    return got == bytes;
}

static bool SendPacket(uint8_t type, const uint8_t* payload, uint32_t len) {
    std::lock_guard<std::mutex> lock(g_sendMutex);
    SOCKET s = g_client;
    if (s == INVALID_SOCKET) return false;

    uint8_t hdr[5] = {
        (uint8_t)(len >> 24), (uint8_t)(len >> 16), (uint8_t)(len >> 8), (uint8_t)len, type
    };
    auto sendAll = [&](const uint8_t* p, int n) -> bool {
        int off = 0;
        while (off < n) {
            int w = send(s, reinterpret_cast<const char*>(p + off), n - off, 0);
            if (w <= 0) return false;
            off += w;
        }
        return true;
    };
    return sendAll(hdr, 5) && (len == 0 || sendAll(payload, (int)len));
}

static int JsonInt(const std::string& json, const char* key, int fallback) {
    std::string token = std::string("\"") + key + "\":";
    size_t p = json.find(token);
    if (p == std::string::npos) return fallback;
    p += token.size();
    while (p < json.size() && isspace((unsigned char)json[p])) ++p;
    bool neg = false;
    if (p < json.size() && json[p] == '-') { neg = true; ++p; }
    int v = 0; bool any = false;
    while (p < json.size() && isdigit((unsigned char)json[p])) {
        any = true; v = v * 10 + (json[p++] - '0');
    }
    return any ? (neg ? -v : v) : fallback;
}

class PcmAudioPlayer {
public:
    HRESULT Initialize() {
        HRESULT hr = CoCreateInstance(
            __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            IID_PPV_ARGS(&enumerator_));
        if (FAILED(hr)) return hr;

        hr = enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &device_);
        if (FAILED(hr)) return hr;

        hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                               reinterpret_cast<void**>(audio_.GetAddressOf()));
        if (FAILED(hr)) return hr;

        WAVEFORMATEX fmt{};
        fmt.wFormatTag = WAVE_FORMAT_PCM;
        fmt.nChannels = 2;
        fmt.nSamplesPerSec = 48000;
        fmt.wBitsPerSample = 16;
        fmt.nBlockAlign = 4;
        fmt.nAvgBytesPerSec = 48000 * 4;

        const DWORD flags = AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                            AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        hr = audio_->Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            flags,
            500000, // 50 ms engine buffer; network queue is managed separately.
            0,
            &fmt,
            nullptr);
        if (FAILED(hr)) return hr;

        hr = audio_->GetBufferSize(&bufferFrames_);
        if (FAILED(hr)) return hr;

        hr = audio_->GetService(IID_PPV_ARGS(&render_));
        if (FAILED(hr)) return hr;

        running_ = true;
        worker_ = std::thread(&PcmAudioPlayer::RenderLoop, this);
        return S_OK;
    }

    ~PcmAudioPlayer() {
        Shutdown();
    }

    HRESULT Submit(const uint8_t* pcm, size_t bytes) {
        if (!pcm || bytes == 0 || (bytes % 4) != 0) return E_INVALIDARG;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            // Cap network-side audio at 120 ms. If the renderer falls behind,
            // discard oldest audio rather than allowing A/V latency to grow.
            constexpr size_t MAX_AUDIO_BYTES = 48000 * 4 * 120 / 1000;
            while (queue_.size() + bytes > MAX_AUDIO_BYTES && queue_.size() >= 4) {
                for (int i = 0; i < 4; ++i) queue_.pop_front();
                ++overflows_;
            }
            queue_.insert(queue_.end(), pcm, pcm + bytes);
        }
        cv_.notify_one();
        return S_OK;
    }

    void Shutdown() {
        bool expected = true;
        if (!running_.compare_exchange_strong(expected, false)) return;
        cv_.notify_all();
        if (worker_.joinable()) worker_.join();
        if (audio_) audio_->Stop();
        render_.Reset();
        audio_.Reset();
        device_.Reset();
        enumerator_.Reset();
    }

    uint64_t Underruns() const { return underruns_.load(); }
    uint64_t Overflows() const { return overflows_.load(); }

private:
    void RenderLoop() {
        // Prebuffer ~30 ms so normal packet jitter does not turn into crackle.
        const size_t startBytes = 48000 * 4 * 30 / 1000;
        while (running_) {
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait_for(lock, std::chrono::milliseconds(5), [&] {
                    return !running_ || queue_.size() >= startBytes;
                });
                if (!running_) return;
                if (queue_.size() < startBytes) continue;
            }
            break;
        }

        HRESULT hr = audio_->Start();
        if (FAILED(hr)) {
            ++g_audioErrors;
            Logf(L"audio start failed hr=0x%08X", (unsigned)hr);
            return;
        }

        while (running_) {
            UINT32 padding = 0;
            hr = audio_->GetCurrentPadding(&padding);
            if (FAILED(hr)) {
                ++g_audioErrors;
                Logf(L"audio padding failed hr=0x%08X", (unsigned)hr);
                break;
            }

            UINT32 available = bufferFrames_ > padding ? bufferFrames_ - padding : 0;
            if (available == 0) {
                Sleep(2);
                continue;
            }

            BYTE* dst = nullptr;
            hr = render_->GetBuffer(available, &dst);
            if (FAILED(hr)) {
                ++g_audioErrors;
                Logf(L"audio GetBuffer failed hr=0x%08X", (unsigned)hr);
                break;
            }

            size_t wantedBytes = (size_t)available * 4;
            size_t copied = 0;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                copied = std::min(wantedBytes, queue_.size());
                copied -= copied % 4;
                for (size_t i = 0; i < copied; ++i) {
                    dst[i] = queue_.front();
                    queue_.pop_front();
                }
            }

            if (copied < wantedBytes) {
                memset(dst + copied, 0, wantedBytes - copied);
                ++underruns_;
            }

            hr = render_->ReleaseBuffer(available, 0);
            if (FAILED(hr)) {
                ++g_audioErrors;
                Logf(L"audio ReleaseBuffer failed hr=0x%08X", (unsigned)hr);
                break;
            }

            Sleep(2);
        }
    }

    ComPtr<IMMDeviceEnumerator> enumerator_;
    ComPtr<IMMDevice> device_;
    ComPtr<IAudioClient> audio_;
    ComPtr<IAudioRenderClient> render_;
    UINT32 bufferFrames_ = 0;

    std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<uint8_t> queue_;
    std::thread worker_;
    std::atomic<bool> running_{false};
    std::atomic<uint64_t> underruns_{0};
    std::atomic<uint64_t> overflows_{0};
};


class D3DPresenter {
public:
    HRESULT Initialize(HWND hwnd) {
        hwnd_ = hwnd;
        UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
        D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1};
        D3D_FEATURE_LEVEL actual{};
        HRESULT hr = D3D11CreateDevice(
            nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
            levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
            &device_, &actual, &context_);
        if (FAILED(hr)) return hr;

        // Presentation runs on the receiver/network thread while window
        // resize messages are handled on the UI thread. Protect the D3D11
        // immediate context so those operations cannot race each other.
        ComPtr<ID3D10Multithread> multithread;
        if (SUCCEEDED(context_.As(&multithread))) {
            multithread->SetMultithreadProtected(TRUE);
        }

        ComPtr<IDXGIDevice> dxgiDevice;
        hr = device_.As(&dxgiDevice);
        if (FAILED(hr)) return hr;
        ComPtr<IDXGIAdapter> adapter;
        hr = dxgiDevice->GetAdapter(&adapter);
        if (FAILED(hr)) return hr;
        ComPtr<IDXGIFactory2> factory;
        hr = adapter->GetParent(IID_PPV_ARGS(&factory));
        if (FAILED(hr)) return hr;

        RECT rc{}; GetClientRect(hwnd_, &rc);
        DXGI_SWAP_CHAIN_DESC1 desc{};
        desc.Width = std::max<LONG>(1, rc.right - rc.left);
        desc.Height = std::max<LONG>(1, rc.bottom - rc.top);
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        desc.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

        hr = factory->CreateSwapChainForHwnd(device_.Get(), hwnd_, &desc, nullptr, nullptr, &swapChain_);
        if (FAILED(hr)) return hr;

        ComPtr<IDXGISwapChain2> swapChain2;
        if (SUCCEEDED(swapChain_.As(&swapChain2))) {
            swapChain2->SetMaximumFrameLatency(1);
            frameLatencyWaitable_ = swapChain2->GetFrameLatencyWaitableObject();
        }

        hr = device_.As(&videoDevice_);
        if (FAILED(hr)) return hr;
        hr = context_.As(&videoContext_);
        if (FAILED(hr)) return hr;

        return CreateVideoProcessor(g_streamWidth, g_streamHeight);
    }

    ID3D11Device* Device() const { return device_.Get(); }

    HRESULT Resize(int width, int height) {
        if (!swapChain_) return E_FAIL;
        if (width <= 0 || height <= 0) return S_OK;
        context_->ClearState();
        return swapChain_->ResizeBuffers(
            0, width, height, DXGI_FORMAT_UNKNOWN,
            DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
    }

    HRESULT CreateVideoProcessor(int width, int height) {
        processor_.Reset();
        enumerator_.Reset();

        D3D11_VIDEO_PROCESSOR_CONTENT_DESC desc{};
        desc.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
        desc.InputWidth = width;
        desc.InputHeight = height;
        desc.OutputWidth = width;
        desc.OutputHeight = height;
        desc.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;

        HRESULT hr = videoDevice_->CreateVideoProcessorEnumerator(&desc, &enumerator_);
        if (FAILED(hr)) return hr;
        return videoDevice_->CreateVideoProcessor(enumerator_.Get(), 0, &processor_);
    }

    HRESULT PresentSample(IMFSample* sample) {
        ComPtr<IMFMediaBuffer> buffer;
        HRESULT hr = sample->ConvertToContiguousBuffer(&buffer);
        if (FAILED(hr)) {
            g_lastHr = (unsigned long)hr;
            return hr;
        }

        ComPtr<ID3D11Texture2D> inputTex;
        UINT subresource = 0;

        // Fast path: decoder produced a D3D11/DXGI-backed surface.
        ComPtr<IMFDXGIBuffer> dxgiBuffer;
        if (SUCCEEDED(buffer.As(&dxgiBuffer))) {
            hr = dxgiBuffer->GetResource(IID_PPV_ARGS(&inputTex));
            if (FAILED(hr)) {
                g_lastHr = (unsigned long)hr;
                return hr;
            }
            dxgiBuffer->GetSubresourceIndex(&subresource);
        } else {
            // Compatibility path: some systems expose Microsoft's H.264 MFT
            // without DXGI-backed output even after receiving the D3D manager.
            // Keep the efficient NV12 format and upload one frame to a reusable
            // D3D11 texture instead of converting to BGRA / GDI.
            if (!uploadTexture_ || uploadW_ != (UINT)g_streamWidth || uploadH_ != (UINT)g_streamHeight) {
                D3D11_TEXTURE2D_DESC desc{};
                desc.Width = g_streamWidth;
                desc.Height = g_streamHeight;
                desc.MipLevels = 1;
                desc.ArraySize = 1;
                desc.Format = DXGI_FORMAT_NV12;
                desc.SampleDesc.Count = 1;
                desc.Usage = D3D11_USAGE_DYNAMIC;
                desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_DECODER;
                desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;

                uploadTexture_.Reset();
                hr = device_->CreateTexture2D(&desc, nullptr, &uploadTexture_);
                if (FAILED(hr)) {
                    // Some drivers reject DECODER on dynamic textures.
                    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
                    hr = device_->CreateTexture2D(&desc, nullptr, &uploadTexture_);
                }
                if (FAILED(hr)) {
                    g_lastHr = (unsigned long)hr;
                    return hr;
                }
                uploadW_ = desc.Width;
                uploadH_ = desc.Height;
            }

            BYTE* src = nullptr;
            DWORD maxLen = 0, curLen = 0;
            hr = buffer->Lock(&src, &maxLen, &curLen);
            if (FAILED(hr)) {
                g_lastHr = (unsigned long)hr;
                return hr;
            }

            D3D11_MAPPED_SUBRESOURCE mapped{};
            hr = context_->Map(uploadTexture_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
            if (SUCCEEDED(hr)) {
                const UINT width = (UINT)g_streamWidth;
                const UINT height = (UINT)g_streamHeight;
                const size_t yBytes = (size_t)width * height;
                const size_t uvBytes = (size_t)width * (height / 2);
                if (curLen >= yBytes + uvBytes) {
                    const BYTE* srcY = src;
                    const BYTE* srcUV = src + yBytes;
                    BYTE* dstY = (BYTE*)mapped.pData;
                    BYTE* dstUV = dstY + mapped.RowPitch * height;

                    for (UINT y = 0; y < height; ++y) {
                        memcpy(dstY + (size_t)y * mapped.RowPitch,
                               srcY + (size_t)y * width,
                               width);
                    }
                    for (UINT y = 0; y < height / 2; ++y) {
                        memcpy(dstUV + (size_t)y * mapped.RowPitch,
                               srcUV + (size_t)y * width,
                               width);
                    }
                } else {
                    hr = MF_E_BUFFERTOOSMALL;
                }
                context_->Unmap(uploadTexture_.Get(), 0);
            }
            buffer->Unlock();

            if (FAILED(hr)) {
                g_lastHr = (unsigned long)hr;
                return hr;
            }

            inputTex = uploadTexture_;
            subresource = 0;
        }

        ComPtr<ID3D11Texture2D> backBuffer;
        hr = swapChain_->GetBuffer(0, IID_PPV_ARGS(&backBuffer));
        if (FAILED(hr)) {
            g_lastHr = (unsigned long)hr;
            return hr;
        }

        D3D11_TEXTURE2D_DESC inDesc{}, outDesc{};
        inputTex->GetDesc(&inDesc);
        backBuffer->GetDesc(&outDesc);

        if (inDesc.Width != lastInW_ || inDesc.Height != lastInH_) {
            lastInW_ = inDesc.Width; lastInH_ = inDesc.Height;
            hr = CreateVideoProcessor((int)inDesc.Width, (int)inDesc.Height);
            if (FAILED(hr)) {
                g_lastHr = (unsigned long)hr;
                return hr;
            }
        }

        D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC inViewDesc{};
        inViewDesc.FourCC = 0;
        inViewDesc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
        inViewDesc.Texture2D.MipSlice = 0;
        inViewDesc.Texture2D.ArraySlice = subresource;

        ComPtr<ID3D11VideoProcessorInputView> inView;
        hr = videoDevice_->CreateVideoProcessorInputView(inputTex.Get(), enumerator_.Get(), &inViewDesc, &inView);
        if (FAILED(hr)) {
            g_lastHr = (unsigned long)hr;
            return hr;
        }

        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC outViewDesc{};
        outViewDesc.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        outViewDesc.Texture2D.MipSlice = 0;

        ComPtr<ID3D11VideoProcessorOutputView> outView;
        hr = videoDevice_->CreateVideoProcessorOutputView(backBuffer.Get(), enumerator_.Get(), &outViewDesc, &outView);
        if (FAILED(hr)) {
            g_lastHr = (unsigned long)hr;
            return hr;
        }

        RECT srcRect{0, 0, (LONG)inDesc.Width, (LONG)inDesc.Height};
        RECT dstRect{0, 0, (LONG)outDesc.Width, (LONG)outDesc.Height};
        videoContext_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &srcRect);
        videoContext_->VideoProcessorSetStreamDestRect(processor_.Get(), 0, TRUE, &dstRect);
        videoContext_->VideoProcessorSetOutputTargetRect(processor_.Get(), TRUE, &dstRect);

        D3D11_VIDEO_PROCESSOR_STREAM stream{};
        stream.Enable = TRUE;
        stream.pInputSurface = inView.Get();

        hr = videoContext_->VideoProcessorBlt(processor_.Get(), outView.Get(), 0, 1, &stream);
        if (FAILED(hr)) {
            g_lastHr = (unsigned long)hr;
            return hr;
        }

        // Keep at most one frame queued without blocking indefinitely inside
        // a vsync Present call. The waitable swap chain gives us explicit
        // presentation backpressure while Present(0,0) avoids tying up the
        // network/decode loop on a synchronous refresh wait.
        if (frameLatencyWaitable_) {
            DWORD wait = WaitForSingleObject(frameLatencyWaitable_, 100);
            if (wait != WAIT_OBJECT_0 && wait != WAIT_TIMEOUT) {
                hr = HRESULT_FROM_WIN32(GetLastError());
                g_lastHr = (unsigned long)hr;
                return hr;
            }
        }

        hr = swapChain_->Present(0, 0);
        if (SUCCEEDED(hr)) {
            ++g_presentedFrames;
        } else {
            g_lastHr = (unsigned long)hr;
        }
        return hr;
    }

private:
    HWND hwnd_{};
    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> context_;
    ComPtr<IDXGISwapChain1> swapChain_;
    HANDLE frameLatencyWaitable_ = nullptr;
    ComPtr<ID3D11VideoDevice> videoDevice_;
    ComPtr<ID3D11VideoContext> videoContext_;
    ComPtr<ID3D11VideoProcessorEnumerator> enumerator_;
    ComPtr<ID3D11VideoProcessor> processor_;
    ComPtr<ID3D11Texture2D> uploadTexture_;
    UINT uploadW_ = 0, uploadH_ = 0;
    UINT lastInW_ = 0, lastInH_ = 0;
};

class H264Decoder {
public:
    HRESULT Initialize(D3DPresenter* presenter, int width, int height) {
        presenter_ = presenter;
        width_ = width;
        height_ = height;

        HRESULT hr = MFCreateDXGIDeviceManager(&resetToken_, &deviceManager_);
        if (FAILED(hr)) return hr;
        hr = deviceManager_->ResetDevice(presenter_->Device(), resetToken_);
        if (FAILED(hr)) return hr;

        // Use the Microsoft H.264 decoder directly. It is a synchronous MFT
        // that supports DXVA through MFT_MESSAGE_SET_D3D_MANAGER, avoiding
        // vendor-specific asynchronous hardware-MFT behavior while still
        // allowing GPU-backed decode surfaces when the driver supports them.
        hr = CoCreateInstance(
            CLSID_CMSH264DecoderMFT,
            nullptr,
            CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(&decoder_));
        if (FAILED(hr)) return hr;

        // The Microsoft H.264 decoder may not be registered as a hardware MFT
        // even when it can use DXVA/D3D11 acceleration internally. Supplying
        // the DXGI device manager is the Media Foundation path that enables
        // D3D11-backed decode surfaces when the graphics driver supports them.
        hr = decoder_->ProcessMessage(
            MFT_MESSAGE_SET_D3D_MANAGER,
            (ULONG_PTR)deviceManager_.Get());
        if (FAILED(hr)) return hr;

        ComPtr<IMFMediaType> inType;
        MFCreateMediaType(&inType);
        inType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        inType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        MFSetAttributeSize(inType.Get(), MF_MT_FRAME_SIZE, width_, height_);
        MFSetAttributeRatio(inType.Get(), MF_MT_FRAME_RATE, 60, 1);
        MFSetAttributeRatio(inType.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        hr = decoder_->SetInputType(0, inType.Get(), 0);
        if (FAILED(hr)) return hr;

        ComPtr<IMFMediaType> outType;
        MFCreateMediaType(&outType);
        outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        outType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
        MFSetAttributeSize(outType.Get(), MF_MT_FRAME_SIZE, width_, height_);
        MFSetAttributeRatio(outType.Get(), MF_MT_FRAME_RATE, 60, 1);
        MFSetAttributeRatio(outType.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        hr = decoder_->SetOutputType(0, outType.Get(), 0);
        if (FAILED(hr)) return hr;

        decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        decoder_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        return S_OK;
    }

    HRESULT FeedAccessUnit(const uint8_t* data, size_t len) {
        if (!decoder_ || len == 0) return S_OK;
        ++g_accessUnits;

        ComPtr<IMFMediaBuffer> buffer;
        HRESULT hr = MFCreateMemoryBuffer((DWORD)len, &buffer);
        if (FAILED(hr)) return hr;

        BYTE* dst = nullptr;
        DWORD maxLen = 0;
        hr = buffer->Lock(&dst, &maxLen, nullptr);
        if (FAILED(hr)) return hr;
        memcpy(dst, data, len);
        buffer->Unlock();
        buffer->SetCurrentLength((DWORD)len);

        ComPtr<IMFSample> sample;
        MFCreateSample(&sample);
        sample->AddBuffer(buffer.Get());
        sample->SetSampleTime(nextTime_);
        sample->SetSampleDuration(frameDuration_);
        nextTime_ += frameDuration_;

        hr = decoder_->ProcessInput(0, sample.Get(), 0);
        if (hr == MF_E_NOTACCEPTING) {
            HRESULT drainHr = Drain();
            if (FAILED(drainHr)) return drainHr;
            hr = decoder_->ProcessInput(0, sample.Get(), 0);
        }
        if (FAILED(hr)) return hr;
        return Drain();
    }

    void Flush() {
        if (decoder_) decoder_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        nextTime_ = 0;
    }

private:
    HRESULT Drain() {
        if (!decoder_) return E_FAIL;
        MFT_OUTPUT_STREAM_INFO info{};
        HRESULT hr = decoder_->GetOutputStreamInfo(0, &info);
        if (FAILED(hr)) return hr;

        while (true) {
            MFT_OUTPUT_DATA_BUFFER out{};
            DWORD status = 0;
            ComPtr<IMFSample> sample;

            if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
                MFCreateSample(&sample);
                ComPtr<IMFMediaBuffer> outBuffer;
                MFCreateMemoryBuffer(std::max<DWORD>(info.cbSize, width_ * height_ * 3 / 2), &outBuffer);
                sample->AddBuffer(outBuffer.Get());
                out.pSample = sample.Get();
            }

            hr = decoder_->ProcessOutput(0, 1, &out, &status);
            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return S_OK;
            if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
                DWORD idx = 0;
                ComPtr<IMFMediaType> type;
                while (SUCCEEDED(decoder_->GetOutputAvailableType(0, idx++, &type))) {
                    GUID subtype{};
                    if (SUCCEEDED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) && subtype == MFVideoFormat_NV12) {
                        decoder_->SetOutputType(0, type.Get(), 0);
                        break;
                    }
                    type.Reset();
                }
                continue;
            }
            if (FAILED(hr)) return hr;

            const bool transformProvidedSample =
                (info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;

            if (out.pSample) {
                ++g_decodedFrames;
                bool queued = QueuePresentSample(out.pSample);

                // When the decoder owns/provides the output sample, ProcessOutput
                // transfers a reference to us. QueuePresentSample took its own
                // reference, so release the transform-owned reference now.
                if (transformProvidedSample) {
                    out.pSample->Release();
                    out.pSample = nullptr;
                }

                if (!queued) {
                    if (out.pEvents) out.pEvents->Release();
                    return MF_E_SHUTDOWN;
                }
            }
            if (out.pEvents) out.pEvents->Release();
        }
    }

    D3DPresenter* presenter_{};
    int width_{}, height_{};
    LONGLONG nextTime_ = 0;
    const LONGLONG frameDuration_ = 10000000LL / 60;
    UINT resetToken_ = 0;
    ComPtr<IMFDXGIDeviceManager> deviceManager_;
    ComPtr<IMFTransform> decoder_;
};

static D3DPresenter g_presenter;

static bool IsStartCode(const std::vector<uint8_t>& b, size_t i, size_t& scLen) {
    if (i + 3 <= b.size() && b[i] == 0 && b[i+1] == 0 && b[i+2] == 1) {
        scLen = 3; return true;
    }
    if (i + 4 <= b.size() && b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1) {
        scLen = 4; return true;
    }
    return false;
}

static void FeedAnnexB(std::vector<uint8_t>& pending, const uint8_t* data, size_t len) {
    pending.insert(pending.end(), data, data + len);

    std::vector<size_t> audPositions;
    for (size_t i = 0; i + 4 < pending.size(); ++i) {
        size_t scLen = 0;
        if (!IsStartCode(pending, i, scLen)) continue;
        if (i + scLen < pending.size()) {
            uint8_t nalType = pending[i + scLen] & 0x1F;
            if (nalType == 9) audPositions.push_back(i);
        }
        i += scLen;
    }

    if (audPositions.size() < 2) return;

    for (size_t n = 0; n + 1 < audPositions.size(); ++n) {
        size_t begin = audPositions[n];
        size_t end = audPositions[n + 1];
        if (end > begin) {
            std::vector<uint8_t> au(pending.begin() + begin, pending.begin() + end);
            if (!QueueAccessUnit(std::move(au))) return;
        }
    }

    size_t keep = audPositions.back();
    if (keep > 0) pending.erase(pending.begin(), pending.begin() + keep);
}

static void SendHello() {
    char name[256]{};
    DWORD size = ARRAYSIZE(name);
    GetComputerNameA(name, &size);
    std::string hello = std::string("{\"protocol\":1,\"app\":\"windows-native-receiver\",\"build\":2,\"device\":\"Windows Receiver\",\"name\":\"") +
        name + "\",\"touch_v2\":true,\"hardware_decode\":true}";
    SendPacket(CONFIG, reinterpret_cast<const uint8_t*>(hello.data()), (uint32_t)hello.size());
}

static void DecoderThread() {
    std::unique_ptr<H264Decoder> decoder;
    int decoderW = 0, decoderH = 0;

    while (g_running) {
        std::vector<uint8_t> au;
        {
            std::unique_lock<std::mutex> lock(g_auMutex);
            g_auCvNotEmpty.wait(lock, [] {
                return !g_running || !g_auQueue.empty() || g_decoderResetRequested.load();
            });
            if (!g_running) break;

            if (g_decoderResetRequested.exchange(false)) {
                g_auQueue.clear();
                lock.unlock();
                g_auCvNotFull.notify_all();
                if (decoder) decoder->Flush();
                decoder.reset();
                decoderW = decoderH = 0;
                Logf(L"decoder reset");
                continue;
            }

            if (g_auQueue.empty()) continue;
            au = std::move(g_auQueue.front());
            g_auQueue.pop_front();
        }
        g_auCvNotFull.notify_one();

        int w = g_streamWidth;
        int h = g_streamHeight;
        if (!decoder || decoderW != w || decoderH != h) {
            if (decoder) decoder->Flush();
            decoder = std::make_unique<H264Decoder>();
            HRESULT hr = decoder->Initialize(&g_presenter, w, h);
            if (FAILED(hr)) {
                g_lastHr = (unsigned long)hr;
                ++g_decoderErrors;
                Logf(L"decoder init failed hr=0x%08X size=%dx%d", (unsigned)hr, w, h);
                decoder.reset();
                continue;
            }
            decoderW = w;
            decoderH = h;
            Logf(L"decoder initialized size=%dx%d", w, h);
            PostMessage(g_hwnd, WM_APP_STATUS, 0, (LPARAM)_wcsdup(L""));
        }

        HRESULT hr = decoder->FeedAccessUnit(au.data(), au.size());
        if (FAILED(hr) && hr != MF_E_SHUTDOWN) {
            g_lastHr = (unsigned long)hr;
            ++g_decoderErrors;
            Logf(L"decoder feed failed hr=0x%08X au_bytes=%llu",
                 (unsigned)hr, (unsigned long long)au.size());
            wchar_t msg[128];
            swprintf_s(msg, L"Decoder error 0x%08X", (unsigned)hr);
            PostMessage(g_hwnd, WM_APP_STATUS, 0, (LPARAM)_wcsdup(msg));
            decoder->Flush();
            decoder.reset();
        }
    }
}

static void PresentThread() {
    while (g_running) {
        ComPtr<IMFSample> sample;
        {
            std::unique_lock<std::mutex> lock(g_presentMutex);
            g_presentCvNotEmpty.wait(lock, [] {
                return !g_running || !g_presentQueue.empty();
            });
            if (!g_running) break;
            sample = std::move(g_presentQueue.front());
            g_presentQueue.pop_front();
        }
        g_presentCvNotFull.notify_one();

        auto started = std::chrono::steady_clock::now();
        HRESULT hr = g_presenter.PresentSample(sample.Get());
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        if (ms >= 50) {
            ++g_presentStalls;
            Logf(L"slow present %lld ms hr=0x%08X", (long long)ms, (unsigned)hr);
        }
        if (FAILED(hr)) {
            g_lastHr = (unsigned long)hr;
            Logf(L"present failed hr=0x%08X", (unsigned)hr);
        }
    }
}

static void DiagnosticsThread() {
    uint64_t lastPackets = 0, lastAU = 0, lastDecoded = 0, lastPresented = 0;
    while (g_running) {
        Sleep(1000);
        if (!g_connected) continue;

        uint64_t packets = g_videoPackets.load();
        uint64_t bytes = g_videoBytes.load();
        uint64_t aus = g_accessUnits.load();
        uint64_t decoded = g_decodedFrames.load();
        uint64_t presented = g_presentedFrames.load();
        unsigned long hr = g_lastHr.load();
        size_t auDepth = 0, presentDepth = 0;
        {
            std::lock_guard<std::mutex> lock(g_auMutex);
            auDepth = g_auQueue.size();
        }
        {
            std::lock_guard<std::mutex> lock(g_presentMutex);
            presentDepth = g_presentQueue.size();
        }

        wchar_t line[384];
        swprintf_s(
            line,
            L"PadDisplay | net %llu / %.2f MB | AU %llu q%llu | dec %llu | present %llu q%llu | +%llu/%llu/%llu/%llu | hr 0x%08lX",
            (unsigned long long)packets,
            (double)bytes / (1024.0 * 1024.0),
            (unsigned long long)aus,
            (unsigned long long)auDepth,
            (unsigned long long)decoded,
            (unsigned long long)presented,
            (unsigned long long)presentDepth,
            (unsigned long long)(packets - lastPackets),
            (unsigned long long)(aus - lastAU),
            (unsigned long long)(decoded - lastDecoded),
            (unsigned long long)(presented - lastPresented),
            hr);
        SetWindowTextW(g_hwnd, line);
        OutputDebugStringW(line);
        OutputDebugStringW(L"\n");
        Logf(L"health net=%llu bytes=%llu au=%llu dec=%llu present=%llu aq=%llu pq=%llu aq_hi=%llu pq_hi=%llu dec_stall=%llu present_stall=%llu errors=%llu reconnects=%llu hr=0x%08lX",
             (unsigned long long)packets,
             (unsigned long long)bytes,
             (unsigned long long)aus,
             (unsigned long long)decoded,
             (unsigned long long)presented,
             (unsigned long long)auDepth,
             (unsigned long long)presentDepth,
             (unsigned long long)g_auQueueHighWater.load(),
             (unsigned long long)g_presentQueueHighWater.load(),
             (unsigned long long)g_decodeStalls.load(),
             (unsigned long long)g_presentStalls.load(),
             (unsigned long long)g_decoderErrors.load(),
             (unsigned long long)g_reconnects.load(),
             hr);
        Logf(L"audio packets=%llu bytes=%llu errors=%llu",
             (unsigned long long)g_audioPackets.load(),
             (unsigned long long)g_audioBytes.load(),
             (unsigned long long)g_audioErrors.load());

        lastPackets = packets;
        lastAU = aus;
        lastDecoded = decoded;
        lastPresented = presented;
    }
}

static void AudioThread() {
    SOCKET listenSock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listenSock == INVALID_SOCKET) {
        Logf(L"audio socket creation failed");
        return;
    }

    BOOL reuse = TRUE;
    setsockopt(listenSock, SOL_SOCKET, SO_REUSEADDR,
               reinterpret_cast<const char*>(&reuse), sizeof(reuse));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(4824);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(listenSock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR ||
        listen(listenSock, 1) == SOCKET_ERROR) {
        Logf(L"audio listen failed wsa=%d", WSAGetLastError());
        closesocket(listenSock);
        return;
    }

    while (g_running) {
        fd_set set{};
        FD_ZERO(&set);
        FD_SET(listenSock, &set);
        timeval tv{1, 0};
        int ready = select(0, &set, nullptr, nullptr, &tv);
        if (!g_running) break;
        if (ready <= 0) continue;

        SOCKET s = accept(listenSock, nullptr, nullptr);
        if (s == INVALID_SOCKET) continue;

        BOOL noDelay = TRUE;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY,
                   reinterpret_cast<const char*>(&noDelay), sizeof(noDelay));

        PcmAudioPlayer player;
        HRESULT initHr = player.Initialize();
        if (FAILED(initHr)) {
            ++g_audioErrors;
            Logf(L"audio playback init failed hr=0x%08X", (unsigned)initHr);
            closesocket(s);
            continue;
        }

        Logf(L"audio client connected");
        while (g_running) {
            uint8_t hdr[5];
            if (!ReadExact(s, hdr, 5)) break;
            uint32_t len = ((uint32_t)hdr[0] << 24) |
                           ((uint32_t)hdr[1] << 16) |
                           ((uint32_t)hdr[2] << 8) |
                           (uint32_t)hdr[3];
            uint8_t type = hdr[4];
            if (len > 4 * 1024 * 1024) break;

            std::vector<uint8_t> payload(len);
            if (len && !ReadExact(s, payload.data(), (int)len)) break;

            if (type == DISCONNECT) break;
            if (type == CONFIG) continue;

            const uint8_t* pcm = nullptr;
            size_t pcmBytes = 0;
            if (type == AUDIO_PCM_V2 && payload.size() >= 12) {
                pcm = payload.data() + 12;
                pcmBytes = payload.size() - 12;
            } else if (type == AUDIO_PCM) {
                pcm = payload.data();
                pcmBytes = payload.size();
            } else {
                continue;
            }

            if (pcmBytes) {
                HRESULT hr = player.Submit(pcm, pcmBytes);
                if (FAILED(hr)) {
                    ++g_audioErrors;
                    Logf(L"audio submit failed hr=0x%08X bytes=%llu",
                         (unsigned)hr, (unsigned long long)pcmBytes);
                    break;
                }
                ++g_audioPackets;
                g_audioBytes += pcmBytes;
            }
        }

        uint64_t underruns = player.Underruns();
        uint64_t overflows = player.Overflows();
        player.Shutdown();
        shutdown(s, SD_BOTH);
        closesocket(s);
        Logf(L"audio client disconnected underruns=%llu overflows=%llu",
             (unsigned long long)underruns,
             (unsigned long long)overflows);
    }

    closesocket(listenSock);
}

static void NetworkThread() {
    SOCKET listenSock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listenSock == INVALID_SOCKET) return;

    BOOL reuse = TRUE;
    setsockopt(listenSock, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof(reuse));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(4822);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(listenSock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR ||
        listen(listenSock, 1) == SOCKET_ERROR) {
        closesocket(listenSock);
        return;
    }

    PostMessage(g_hwnd, WM_APP_STATUS, 0, (LPARAM)_wcsdup(L"Waiting for host connection\nTCP 4822"));
    while (g_running) {
        fd_set set{};
        FD_ZERO(&set); FD_SET(listenSock, &set);
        timeval timeout{1, 0};
        int ready = select(0, &set, nullptr, nullptr, &timeout);
        if (!g_running || ready == SOCKET_ERROR) break;
        if (!ready) continue;
        SOCKET s = accept(listenSock, nullptr, nullptr);
        if (s == INVALID_SOCKET) break;

        BOOL noDelay = TRUE;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&noDelay), sizeof(noDelay));
        g_client = s;
        g_connected = true;
        ++g_reconnects;
        Logf(L"host connected");
        g_videoPackets = 0;
        g_videoBytes = 0;
        g_accessUnits = 0;
        g_decodedFrames = 0;
        g_presentedFrames = 0;
        g_lastHr = 0;
        SendHello();
        PostMessage(g_hwnd, WM_APP_STATUS, 0, (LPARAM)_wcsdup(L"Host connected\nWaiting for stream..."));

        std::vector<uint8_t> annexb;
        while (g_running && g_connected) {
            uint8_t hdr[5];
            if (!ReadExact(s, hdr, 5)) break;
            uint32_t length = (uint32_t(hdr[0]) << 24) | (uint32_t(hdr[1]) << 16) | (uint32_t(hdr[2]) << 8) | hdr[3];
            uint8_t type = hdr[4];
            if (length > 64u * 1024u * 1024u) break;

            std::vector<uint8_t> payload(length);
            if (length && !ReadExact(s, payload.data(), (int)length)) break;

            if (type == CONFIG) {
                std::string json(payload.begin(), payload.end());
                int w = JsonInt(json, "width", 1366);
                int h = JsonInt(json, "height", 768);
                if (w > 0 && h > 0 && (w != g_streamWidth || h != g_streamHeight)) {
                    g_streamWidth = w;
                    g_streamHeight = h;
                    g_decoderResetRequested = true;
                    g_auCvNotEmpty.notify_one();
                    Logf(L"stream config %dx%d", w, h);
                }
            } else if (type == VIDEO_H264) {
                ++g_videoPackets;
                g_videoBytes += payload.size();
                FeedAnnexB(annexb, payload.data(), payload.size());
            } else if (type == DISCONNECT) {
                break;
            }
        }

        g_connected = false;
        g_decoderResetRequested = true;
        g_auCvNotEmpty.notify_one();
        g_auCvNotFull.notify_all();
        g_presentCvNotEmpty.notify_one();
        g_presentCvNotFull.notify_all();
        {
            std::lock_guard<std::mutex> lock(g_presentMutex);
            g_presentQueue.clear();
        }
        Logf(L"host disconnected");
        shutdown(s, SD_BOTH);
        closesocket(s);
        g_client = INVALID_SOCKET;
        InvalidateRect(g_hwnd, nullptr, TRUE);
    }

    closesocket(listenSock);
}

static void ToggleFullscreen() {
    if (!g_hwnd) return;

    if (g_fullscreen) {
        GetWindowPlacement(g_hwnd, &g_windowPlacement);

        LONG_PTR style = GetWindowLongPtrW(g_hwnd, GWL_STYLE);
        style &= ~WS_POPUP;
        style |= WS_OVERLAPPEDWINDOW;
        SetWindowLongPtrW(g_hwnd, GWL_STYLE, style);

        SetWindowPos(
            g_hwnd,
            HWND_NOTOPMOST,
            100, 100, 1100, 700,
            SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        ShowWindow(g_hwnd, SW_RESTORE);
        g_fullscreen = false;
    } else {
        MONITORINFO mi{ sizeof(mi) };
        GetMonitorInfoW(MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST), &mi);

        LONG_PTR style = GetWindowLongPtrW(g_hwnd, GWL_STYLE);
        style &= ~WS_OVERLAPPEDWINDOW;
        style |= WS_POPUP;
        SetWindowLongPtrW(g_hwnd, GWL_STYLE, style);

        SetWindowPos(
            g_hwnd,
            HWND_TOPMOST,
            mi.rcMonitor.left,
            mi.rcMonitor.top,
            mi.rcMonitor.right - mi.rcMonitor.left,
            mi.rcMonitor.bottom - mi.rcMonitor.top,
            SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        g_fullscreen = true;
    }
}

static void SendMousePacket(uint8_t action, uint8_t button, int x, int y, int16_t wheel = 0) {
    RECT rc{}; GetClientRect(g_hwnd, &rc);
    int w = std::max(1L, rc.right - rc.left);
    int h = std::max(1L, rc.bottom - rc.top);
    x = std::clamp(x, 0, w - 1);
    y = std::clamp(y, 0, h - 1);
    uint16_t nx = (uint16_t)((uint64_t)x * 65535u / (uint64_t)std::max(1, w - 1));
    uint16_t ny = (uint16_t)((uint64_t)y * 65535u / (uint64_t)std::max(1, h - 1));

    uint8_t p[8] = {
        action,
        button,
        (uint8_t)(nx >> 8), (uint8_t)nx,
        (uint8_t)(ny >> 8), (uint8_t)ny,
        (uint8_t)(((uint16_t)wheel) >> 8), (uint8_t)wheel
    };
    SendPacket(MOUSE_V1, p, sizeof(p));
}

static void SendKeyboardPacket(uint8_t action, WPARAM wParam, LPARAM lParam) {
    uint16_t vk = (uint16_t)(wParam & 0xFFFF);
    uint16_t scan = (uint16_t)((lParam >> 16) & 0xFF);
    uint8_t flags = (lParam & (1LL << 24)) ? 0x01 : 0x00;
    uint8_t p[6] = {
        action,
        (uint8_t)(vk >> 8), (uint8_t)vk,
        (uint8_t)(scan >> 8), (uint8_t)scan,
        flags
    };
    SendPacket(KEYBOARD_V1, p, sizeof(p));
}

static void SendPointerFrame(UINT32 pointerId, uint8_t phase, int x, int y) {
    RECT rc{}; GetClientRect(g_hwnd, &rc);
    int w = std::max(1L, rc.right - rc.left);
    int h = std::max(1L, rc.bottom - rc.top);
    x = std::clamp(x, 0, w - 1);
    y = std::clamp(y, 0, h - 1);
    uint16_t nx = (uint16_t)((uint64_t)x * 65535u / (uint64_t)std::max(1, w - 1));
    uint16_t ny = (uint16_t)((uint64_t)y * 65535u / (uint64_t)std::max(1, h - 1));

    uint8_t p[8] = {
        1,
        (uint8_t)(pointerId >> 8), (uint8_t)pointerId,
        phase,
        (uint8_t)(nx >> 8), (uint8_t)nx,
        (uint8_t)(ny >> 8), (uint8_t)ny
    };
    SendPacket(TOUCH_V2, p, sizeof(p));
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    static bool mouseDown = false;
    static std::wstring status = L"Waiting for host connection\nTCP 4822";

    switch (msg) {
    case WM_ERASEBKGND:
        return 1;
    case WM_SIZE:
        if (wParam != SIZE_MINIMIZED) {
            g_presenter.Resize(LOWORD(lParam), HIWORD(lParam));
        }
        return 0;
    case WM_APP_STATUS: {
        wchar_t* p = reinterpret_cast<wchar_t*>(lParam);
        status = p ? p : L"";
        if (p) free(p);
        InvalidateRect(hwnd, nullptr, TRUE);
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps{};
        HDC dc = BeginPaint(hwnd, &ps);
        if (!g_connected || !status.empty()) {
            RECT rc{}; GetClientRect(hwnd, &rc);
            FillRect(dc, &rc, (HBRUSH)GetStockObject(BLACK_BRUSH));
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, RGB(245,245,245));
            HFONT font = CreateFontW(32, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                                     OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                     DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
            HFONT old = (HFONT)SelectObject(dc, font);
            DrawTextW(dc, status.c_str(), -1, &rc, DT_CENTER | DT_VCENTER | DT_WORDBREAK);
            SelectObject(dc, old);
            DeleteObject(font);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_MOUSEMOVE:
        SendMousePacket(0, 0, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        return 0;
    case WM_LBUTTONDOWN:
        SetCapture(hwnd); mouseDown = true;
        SendMousePacket(1, 1, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        return 0;
    case WM_LBUTTONUP:
        SendMousePacket(2, 1, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        if (mouseDown) { mouseDown = false; ReleaseCapture(); }
        return 0;
    case WM_RBUTTONDOWN:
        SendMousePacket(1, 2, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        return 0;
    case WM_RBUTTONUP:
        SendMousePacket(2, 2, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        return 0;
    case WM_MBUTTONDOWN:
        SendMousePacket(1, 3, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        return 0;
    case WM_MBUTTONUP:
        SendMousePacket(2, 3, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
        return 0;
    case WM_MOUSEWHEEL: {
        POINT pt{ GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam) };
        ScreenToClient(hwnd, &pt);
        SendMousePacket(3, 0, pt.x, pt.y, (int16_t)GET_WHEEL_DELTA_WPARAM(wParam));
        return 0;
    }
    case WM_POINTERDOWN:
    case WM_POINTERUPDATE:
    case WM_POINTERUP: {
        UINT32 id = GET_POINTERID_WPARAM(wParam);
        POINTER_INFO pi{};
        if (GetPointerInfo(id, &pi)) {
            POINT pt = pi.ptPixelLocation;
            ScreenToClient(hwnd, &pt);
            uint8_t phase = msg == WM_POINTERDOWN ? 0 : msg == WM_POINTERUP ? 2 : 1;
            SendPointerFrame(id & 0xFFFF, phase, pt.x, pt.y);
        }
        return 0;
    }
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
        if (wParam == VK_F11) {
            ToggleFullscreen();
            return 0;
        }
        if (wParam == VK_ESCAPE && g_fullscreen) {
            ToggleFullscreen();
            return 0;
        }
        SendKeyboardPacket(0, wParam, lParam);
        return 0;
    case WM_KEYUP:
    case WM_SYSKEYUP:
        if (wParam == VK_F11) return 0;
        SendKeyboardPacket(1, wParam, lParam);
        return 0;
    case WM_CLOSE:
        g_running = false;
        if (g_client != INVALID_SOCKET) shutdown(g_client, SD_BOTH);
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, msg, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE hInst, HINSTANCE, PWSTR, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2,2), &wsa) != 0) return 1;
    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return 2;
    if (FAILED(MFStartup(MF_VERSION))) return 3;
    InitLog();
    Logf(L"receiver start");

    WNDCLASSW wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = L"PadDisplayNativeReceiver";
    RegisterClassW(&wc);

    int sw = GetSystemMetrics(SM_CXSCREEN);
    int sh = GetSystemMetrics(SM_CYSCREEN);
    g_hwnd = CreateWindowExW(
        WS_EX_TOPMOST, wc.lpszClassName, L"PadDisplay Receiver",
        WS_POPUP | WS_VISIBLE, 0, 0, sw, sh,
        nullptr, nullptr, hInst, nullptr);
    if (!g_hwnd) return 4;

    HRESULT hr = g_presenter.Initialize(g_hwnd);
    if (FAILED(hr)) {
        MessageBoxW(nullptr, L"Could not initialize D3D11 presentation.", L"PadDisplay Receiver", MB_ICONERROR);
        return 5;
    }

    RegisterTouchWindow(g_hwnd, 0);
    ShowWindow(g_hwnd, SW_SHOWMAXIMIZED);
    SetForegroundWindow(g_hwnd);

    std::thread network(NetworkThread);
    std::thread audio(AudioThread);
    std::thread decoder(DecoderThread);
    std::thread presenter(PresentThread);
    std::thread diagnostics(DiagnosticsThread);

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    g_running = false;
    if (g_client != INVALID_SOCKET) shutdown(g_client, SD_BOTH);
    g_auCvNotEmpty.notify_all();
    g_auCvNotFull.notify_all();
    g_presentCvNotEmpty.notify_all();
    g_presentCvNotFull.notify_all();
    if (network.joinable()) network.join();
    if (audio.joinable()) audio.join();
    if (decoder.joinable()) decoder.join();
    if (presenter.joinable()) presenter.join();
    if (diagnostics.joinable()) diagnostics.join();

    Logf(L"receiver stop");
    CloseLog();
    MFShutdown();
    CoUninitialize();
    WSACleanup();
    return 0;
}
