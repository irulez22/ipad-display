#include <windows.h>
#include <cassert>
#include <vector>

static std::vector<DWORD> change_flags;
static DEVMODEW staged{};
static LONG change_result=DISP_CHANGE_SUCCESSFUL;
static LONG WINAPI TestChange(LPCWSTR device, DEVMODEW* mode, HWND, DWORD flags, LPVOID){
    change_flags.push_back(flags);
    if(device){ assert(wcscmp(device,L"virtual")==0); assert(mode); staged=*mode; }
    else { assert(!mode); }
    return change_result;
}
static BOOL WINAPI TestSettings(LPCWSTR device, DWORD index, DEVMODEW* mode){
    if(index!=0 && index!=ENUM_CURRENT_SETTINGS) return FALSE;
    mode->dmPelsWidth=wcscmp(device,L"physical")==0 ? 2560 : 1366;
    mode->dmPelsHeight=768;mode->dmDisplayFrequency=60;
    mode->dmPosition.x=0;mode->dmPosition.y=0;
    return TRUE;
}
static BOOL WINAPI TestDevices(LPCWSTR, DWORD index, DISPLAY_DEVICEW* device, DWORD){
    if(index!=0) return FALSE;
    wcscpy_s(device->DeviceName,L"physical");
    device->StateFlags=DISPLAY_DEVICE_ATTACHED_TO_DESKTOP|DISPLAY_DEVICE_PRIMARY_DEVICE;
    return TRUE;
}
#define ChangeDisplaySettingsExW TestChange
#define EnumDisplaySettingsW TestSettings
#define EnumDisplayDevicesW TestDevices
#define wmain PadDisplayTargetMain
#include "../tools/display_target.cpp"
#undef wmain

int main(){
    DISPLAY_DEVICEW device{};device.cb=sizeof(device);
    wcscpy_s(device.DeviceName,L"virtual");
    assert(SetDesktopAttachment(device,false,0,0,0));
    assert(change_flags.empty());
    assert(SetDesktopAttachment(device,true,1366,768,60));
    assert(change_flags.size()==2);
    assert(change_flags[0]==(CDS_UPDATEREGISTRY|CDS_NORESET) && change_flags[1]==0);
    assert(staged.dmPosition.x==2560 && staged.dmPelsWidth==1366);
    change_flags.clear();
    device.StateFlags=DISPLAY_DEVICE_ATTACHED_TO_DESKTOP;
    assert(SetDesktopAttachment(device,true,1366,768,60));
    assert(change_flags.empty());
    assert(SetDesktopAttachment(device,false,0,0,0));
    assert(change_flags.size()==2 && staged.dmPelsWidth==0 && staged.dmPelsHeight==0);
    change_flags.clear();
    device.StateFlags|=DISPLAY_DEVICE_PRIMARY_DEVICE;
    assert(!SetDesktopAttachment(device,false,0,0,0));
    assert(change_flags.empty());
    device.StateFlags=0;change_result=DISP_CHANGE_BADMODE;
    assert(!SetDesktopAttachment(device,true,1366,768,60));
    assert(change_flags.size()==1);
    puts("Desktop attachment, idempotency and primary-display safety checks passed");
}
