#include <windows.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <cstdio>
#include <cwchar>
#include <cstdlib>
#include <algorithm>
using Microsoft::WRL::ComPtr;

static bool SetDesktopAttachment(const DISPLAY_DEVICEW& device, bool attach, int width, int height, int hz) {
    bool attached=(device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)!=0;
    if(!attach && !attached) return true;
    if(device.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) return false;
    DEVMODEW mode{};
    mode.dmSize=sizeof(mode);
    if(attach){
        if(attached && EnumDisplaySettingsW(device.DeviceName,ENUM_CURRENT_SETTINGS,&mode) &&
           mode.dmPelsWidth==(DWORD)width && mode.dmPelsHeight==(DWORD)height &&
           mode.dmDisplayFrequency==(DWORD)hz) return true;
        bool found=false;
        for(DWORD i=0;EnumDisplaySettingsW(device.DeviceName,i,&mode);++i){
            if(mode.dmPelsWidth==(DWORD)width && mode.dmPelsHeight==(DWORD)height &&
               mode.dmDisplayFrequency==(DWORD)hz){found=true;break;}
        }
        if(!found) return false;
        LONG right=0;
        for(DWORD i=0;;++i){
            DISPLAY_DEVICEW other{};other.cb=sizeof(other);
            if(!EnumDisplayDevicesW(nullptr,i,&other,0)) break;
            if(!(other.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) ||
               _wcsicmp(other.DeviceName,device.DeviceName)==0) continue;
            DEVMODEW current{};current.dmSize=sizeof(current);
            if(EnumDisplaySettingsW(other.DeviceName,ENUM_CURRENT_SETTINGS,&current))
                right=(std::max)(right,current.dmPosition.x+(LONG)current.dmPelsWidth);
        }
        mode.dmPosition.x=right;mode.dmPosition.y=0;
        mode.dmFields=DM_POSITION|DM_PELSWIDTH|DM_PELSHEIGHT|DM_DISPLAYFREQUENCY;
    } else {
        mode.dmFields=DM_POSITION|DM_PELSWIDTH|DM_PELSHEIGHT;
    }
    // Detach only this desktop output; restarting the adapter resets the entire graphics stack.
    LONG result=ChangeDisplaySettingsExW(device.DeviceName,&mode,nullptr,CDS_UPDATEREGISTRY|CDS_NORESET,nullptr);
    if(result==DISP_CHANGE_SUCCESSFUL) result=ChangeDisplaySettingsExW(nullptr,nullptr,nullptr,0,nullptr);
    if(result!=DISP_CHANGE_SUCCESSFUL) fwprintf(stderr,L"Desktop attachment failed: %ld\n",result);
    return result==DISP_CHANGE_SUCCESSFUL;
}

int wmain(int argc, wchar_t** argv) {
    if(argc!=2 && argc!=3 && argc!=6) return 2;
    bool change=argc!=2,attach=false;
    int width=0,height=0,hz=0;
    if(change){
        attach=_wcsicmp(argv[2],L"on")==0;
        if(attach){
            if(argc!=6) return 2;
            int* values[]={&width,&height,&hz};
            for(int i=0;i<3;++i){
                wchar_t* end=nullptr;
                long value=wcstol(argv[i+3],&end,10);
                if(!end || *end || value<=0 || value>16384) return 2;
                *values[i]=(int)value;
            }
            if(width%2 || height%2 || (hz!=30 && hz!=60)) return 2;
        } else if(argc!=3 || _wcsicmp(argv[2],L"off")!=0) return 2;
    }
    DISPLAY_DEVICEW device{};
    bool found = false;
    for (DWORD i = 0;; ++i) {
        device = {};
        device.cb = sizeof(device);
        if (!EnumDisplayDevicesW(nullptr, i, &device, 0)) break;
        if (_wcsicmp(device.DeviceID, argv[1]) == 0) { found = true; break; }
    }
    if (!found) return 1;
    if(change) return SetDesktopAttachment(device,attach,width,height,hz) ? 0 : 1;
    wprintf(L"%ls\n", device.DeviceName);
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return 1;
    for (UINT a = 0;; ++a) {
        ComPtr<IDXGIAdapter1> adapter;
        HRESULT result=factory->EnumAdapters1(a, &adapter);
        if(result==DXGI_ERROR_NOT_FOUND) break;
        if(FAILED(result)) return 1;
        for (UINT o = 0;; ++o) {
            ComPtr<IDXGIOutput> output;
            HRESULT result=adapter->EnumOutputs(o, &output);
            if(result==DXGI_ERROR_NOT_FOUND) break;
            if(FAILED(result)) return 1;
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
