param(
    [string]$SampleRoot = "C:\Users\Josh\Windows-driver-samples\video\IndirectDisplay"
)

$ErrorActionPreference = "Stop"

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$DriverSource = Join-Path $SampleRoot "IddSampleDriver"
$AppSource = Join-Path $SampleRoot "IddSampleApp"

if (!(Test-Path (Join-Path $DriverSource "Driver.cpp"))) {
    throw "Microsoft IndirectDisplay sample not found at $SampleRoot"
}

Write-Host "Bootstrapping PadDisplay IDD from $SampleRoot"

$driverOut = Join-Path $Here "PadDisplayDriver"
$appOut = Join-Path $Here "PadDisplayApp"
New-Item -ItemType Directory -Force $driverOut, $appOut | Out-Null

Copy-Item (Join-Path $DriverSource "Driver.cpp") (Join-Path $driverOut "Driver.cpp") -Force
Copy-Item (Join-Path $DriverSource "Driver.h") (Join-Path $driverOut "Driver.h") -Force
Copy-Item (Join-Path $DriverSource "Trace.h") (Join-Path $driverOut "trace.h") -Force
Copy-Item (Join-Path $DriverSource "IddSampleDriver.vcxproj.filters") (Join-Path $driverOut "PadDisplayDriver.vcxproj.filters") -Force
Copy-Item (Join-Path $DriverSource "IddSampleDriver.vcxproj") (Join-Path $driverOut "PadDisplayDriver.vcxproj") -Force
Copy-Item (Join-Path $DriverSource "IddSampleDriver.inf") (Join-Path $driverOut "PadDisplayDriver.inf") -Force
Copy-Item (Join-Path $AppSource "IddSampleApp.vcxproj") (Join-Path $appOut "PadDisplayApp.vcxproj") -Force
Copy-Item (Join-Path $AppSource "main.cpp") (Join-Path $appOut "main.cpp") -Force

$driver = Get-Content (Join-Path $driverOut "Driver.cpp") -Raw
$driver = $driver.Replace(
    "static constexpr DWORD IDD_SAMPLE_MONITOR_COUNT = 3;",
    "static constexpr DWORD IDD_SAMPLE_MONITOR_COUNT = 1;"
)
$driver = [regex]::Replace(
    $driver,
    '(?s)static const struct IndirectSampleMonitor::SampleMonitorMode s_SampleDefaultModes\[\]\s*=\s*\{.*?\};',
@'
static const struct IndirectSampleMonitor::SampleMonitorMode s_SampleDefaultModes[] =
{
    { 1280,  960, 60 },
    { 1600, 1200, 60 },
    { 1024,  768, 60 },
    { 2048, 1536, 30 },
};
'@
)
# Force our single monitor down the EDID-less path.
$driver = $driver.Replace(
    "if (ConnectorIndex >= ARRAYSIZE(s_SampleMonitors))",
    "if (true)"
)
$driver = $driver.Replace('L"IddSample Device"', 'L"PadDisplay"')
$driver = $driver.Replace('L"Microsoft"', 'L"PadDisplay"')
$driver = $driver.Replace('L"IddSample Model"', 'L"iPad Virtual Display"')
$driver = [regex]::Replace(
    $driver,
    '(?s)    TargetModes\.push_back\(CreateIddCxTargetMode\(3840, 2160, 60\)\);.*?    TargetModes\.push_back\(CreateIddCxTargetMode\(1024,  768, 60\)\);',
@'
    TargetModes.push_back(CreateIddCxTargetMode(1280,  960, 60));
    TargetModes.push_back(CreateIddCxTargetMode(1600, 1200, 60));
    TargetModes.push_back(CreateIddCxTargetMode(1024,  768, 60));
    TargetModes.push_back(CreateIddCxTargetMode(2048, 1536, 30));
'@
)

# Add a lightweight frame probe at the IddCx swapchain handoff. This deliberately
# avoids CPU readback/encoding; it only verifies that PadDisplay is receiving the
# compositor's D3D11 textures at the expected mode and cadence.
$driver = $driver.Replace(
    '#include "Driver.h"',
@'
#include "Driver.h"
#include <cstdio>
'@
)

$driver = $driver.Replace(
    '    // Acquire and release buffers in a loop',
@'
    // PadDisplay frame probe. Keep this inside the swapchain thread so we verify
    // the exact surface that will later be handed to NVENC.
    UINT64 PadDisplayFrameNumber = 0;

    // Acquire and release buffers in a loop
'@
)

$driver = [regex]::Replace(
    $driver,
    '(?s)            // ==============================\r?\n            // TODO: Process the frame here.*?            // ==============================',
@'
            ++PadDisplayFrameNumber;

            ComPtr<ID3D11Texture2D> PadDisplayTexture;
            HRESULT TextureHr = AcquiredBuffer.As(&PadDisplayTexture);
            if (SUCCEEDED(TextureHr))
            {
                D3D11_TEXTURE2D_DESC TextureDesc = {};
                PadDisplayTexture->GetDesc(&TextureDesc);

                // Emit the first frame and then roughly every two seconds at 60 Hz.
                if (PadDisplayFrameNumber == 1 || (PadDisplayFrameNumber % 120) == 0)
                {
                    char Message[256] = {};
                    sprintf_s(
                        Message,
                        "PadDisplay IDD frame %llu: %ux%u format=%u bind=0x%X misc=0x%X\n",
                        static_cast<unsigned long long>(PadDisplayFrameNumber),
                        TextureDesc.Width,
                        TextureDesc.Height,
                        static_cast<unsigned int>(TextureDesc.Format),
                        TextureDesc.BindFlags,
                        TextureDesc.MiscFlags);
                    OutputDebugStringA(Message);
                }

                // Next milestone: copy/encode PadDisplayTexture on-GPU and send the
                // resulting H.264 stream to the existing PadDisplay TCP receiver.
            }
            else if (PadDisplayFrameNumber == 1)
            {
                OutputDebugStringA("PadDisplay IDD: acquired swapchain surface is not ID3D11Texture2D\n");
            }
'@
)

Set-Content (Join-Path $driverOut "Driver.cpp") $driver -Encoding UTF8

$driverHeader = Get-Content (Join-Path $driverOut "Driver.h") -Raw
$driverHeader = $driverHeader.Replace('#include "Trace.h"', '#include "trace.h"')
Set-Content (Join-Path $driverOut "Driver.h") $driverHeader -Encoding UTF8

$inf = Get-Content (Join-Path $driverOut "PadDisplayDriver.inf") -Raw
$inf = $inf.Replace("IddSampleDriver.cat", "PadDisplayDriver.cat")
$inf = $inf.Replace("Root\IddSampleDriver", "Root\PadDisplay")
$inf = $inf.Replace("IddSampleDriverGroup", "PadDisplayDriverGroup")
$inf = $inf.Replace("IddSampleDriver_Install", "PadDisplayDriver_Install")
$inf = $inf.Replace("IddSampleDriver.dll", "PadDisplayDriver.dll")
$inf = $inf.Replace("UmdfService=IddSampleDriver,", "UmdfService=PadDisplayDriver,")
$inf = $inf.Replace("UmdfServiceOrder=IddSampleDriver", "UmdfServiceOrder=PadDisplayDriver")
$inf = $inf.Replace("IddSampleDriver      ", "PadDisplay           ")
$inf = $inf.Replace('ManufacturerName="<Your manufacturer name>"', 'ManufacturerName="PadDisplay"')
$inf = $inf.Replace('DiskName = "IddSampleDriver Installation Disk"', 'DiskName = "PadDisplay Driver Installation Disk"')
$inf = $inf.Replace('DeviceName="IddSampleDriver Device"', 'DeviceName="PadDisplay Virtual Display"')
Set-Content (Join-Path $driverOut "PadDisplayDriver.inf") $inf -Encoding UTF8

$proj = Get-Content (Join-Path $driverOut "PadDisplayDriver.vcxproj") -Raw
$proj = $proj.Replace("<RootNamespace>IddSampleDriver</RootNamespace>", "<RootNamespace>PadDisplayDriver</RootNamespace>")
$proj = $proj.Replace('<Inf Include="IddSampleDriver.inf" />', '<Inf Include="PadDisplayDriver.inf" />')
$proj = $proj.Replace('<ClInclude Include="Trace.h" />', '<ClInclude Include="trace.h" />')
Set-Content (Join-Path $driverOut "PadDisplayDriver.vcxproj") $proj -Encoding UTF8

$filters = Get-Content (Join-Path $driverOut "PadDisplayDriver.vcxproj.filters") -Raw
$filters = $filters.Replace('IddSampleDriver.inf', 'PadDisplayDriver.inf')
$filters = $filters.Replace('Trace.h', 'trace.h')
Set-Content (Join-Path $driverOut "PadDisplayDriver.vcxproj.filters") $filters -Encoding UTF8

$app = Get-Content (Join-Path $appOut "main.cpp") -Raw
$app = $app.Replace('L"Idd Sample Driver"', 'L"PadDisplay Virtual Display"')
$app = [regex]::Replace($app, 'PCWSTR hardwareIds\s*=\s*L"[^"]*";', 'PCWSTR hardwareIds = L"PadDisplay\0\0";')
$app = [regex]::Replace($app, 'PCWSTR compatibleIds\s*=\s*L"[^"]*";', 'PCWSTR compatibleIds = L"PadDisplay\0\0";')
$app = $app.Replace('L"IddSampleDriver"', 'L"PadDisplay"')
$app = $app.Replace('SwDeviceCreate(L"IddSampleDriver"', 'SwDeviceCreate(L"PadDisplay"')
Set-Content (Join-Path $appOut "main.cpp") $app -Encoding UTF8

$appProj = Get-Content (Join-Path $appOut "PadDisplayApp.vcxproj") -Raw
$appProj = $appProj.Replace("<RootNamespace>IddSampleApp</RootNamespace>", "<RootNamespace>PadDisplayApp</RootNamespace>")
Set-Content (Join-Path $appOut "PadDisplayApp.vcxproj") $appProj -Encoding UTF8

Write-Host ""
Write-Host "PadDisplay source generated."
Write-Host "Next: build windows\driver\PadDisplay.sln"
