#include <windows.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <cstdio>
using Microsoft::WRL::ComPtr;

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) return 2;
    DISPLAY_DEVICEW device{};
    bool found = false;
    for (DWORD i = 0;; ++i) {
        device = {};
        device.cb = sizeof(device);
        if (!EnumDisplayDevicesW(nullptr, i, &device, 0)) break;
        if (_wcsicmp(device.DeviceID, argv[1]) == 0) { found = true; break; }
    }
    if (!found) return 1;
    wprintf(L"%ls\n", device.DeviceName);
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return 1;
    for (UINT a = 0;; ++a) {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(a, &adapter) == DXGI_ERROR_NOT_FOUND) break;
        if (!adapter) continue;
        for (UINT o = 0;; ++o) {
            ComPtr<IDXGIOutput> output;
            if (adapter->EnumOutputs(o, &output) == DXGI_ERROR_NOT_FOUND) break;
            if (!output) continue;
            DXGI_OUTPUT_DESC desc{};
            if (SUCCEEDED(output->GetDesc(&desc)) &&
                _wcsicmp(desc.DeviceName, device.DeviceName) == 0 && desc.AttachedToDesktop) {
                printf("%u\n%u\n", a, o);
                return 0;
            }
        }
    }
    printf("-1\n-1\n");
    return 0;
}
