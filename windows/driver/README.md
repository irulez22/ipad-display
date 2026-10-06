# PadDisplay Windows IDD

This directory bootstraps the PadDisplay virtual monitor from the exact Microsoft IndirectDisplay sample already validated on the development PC.

## Milestone v1

- one virtual monitor
- EDID-less mode reporting
- 1280x960 @ 60 Hz preferred
- 1600x1200 @ 60 Hz
- 1024x768 @ 60 Hz
- 2048x1536 @ 30 Hz experimental
- stock IddCx swap-chain consumer (no encoding/networking yet)
- PadDisplay software-device ID and display naming

## Bootstrap

From an elevated Developer PowerShell after pulling this repository:

    cd C:\Users\Josh\ipad-display\windows\driver
    .\bootstrap-from-microsoft-sample.ps1

The script defaults to the validated Microsoft checkout at:

    C:\Users\Josh\Windows-driver-samples\video\IndirectDisplay

Then build:

    msbuild PadDisplay.sln /p:Configuration=Debug /p:Platform=x64

The generated driver package will be under the solution's x64\Debug output. Install the generated PadDisplayDriver.inf with pnputil, then run PadDisplayApp.exe and keep it open while testing.

## Why bootstrap instead of vendoring the full sample

For this first milestone we deliberately retain Microsoft's known-good sample source and project settings and apply a small deterministic PadDisplay delta. This makes it easy to compare failures against the baseline that already enumerated three monitors successfully.

Once v1 builds and enumerates one monitor, the generated source can be promoted into the repository and the swap-chain processing path can be replaced with the PadDisplay D3D11/NVENC transport.
