<#
.SYNOPSIS
  Checks whether a Bluetooth adapter can act as a BLE *peripheral* for the Matrack Truck Simulator.

.DESCRIPTION
  Windows BLE advertising needs the adapter to support the PERIPHERAL role. Most built-in adapters
  (and many cheap USB dongles) are central-only: they can scan but never advertise, so the ELD app
  will never see the simulator. Some adapters (e.g. Realtek 4.2) pass the capability check and can
  even advertise, yet still fail to COMPLETE an incoming connection.

  This script tests, in order:
    1. Adapter present, BLE supported.
    2. Peripheral role supported (the hard gate).
    3. Radio powered on (optionally turns it on with -EnableRadio).
    4. A real connectable advertisement - the exact service + characteristics the app uses - held
       stable for N seconds (no "Aborted" churn).

  What it CANNOT do by itself: prove the adapter completes an incoming connection. That last step
  needs a real phone. If this script says PASS but a phone still times out (GATT 133 / status 8),
  the adapter advertises but can't accept connections - use a different adapter or the ESP32.

  NOTE: this file is intentionally pure ASCII so Windows PowerShell 5.1 parses it regardless of the
  file encoding (unmarked UTF-8 is read as ANSI by 5.1 and would corrupt any non-ASCII characters).

.PARAMETER Seconds
  How long to hold the test advertisement while sampling its status. Default 20.

.PARAMETER EnableRadio
  If the Bluetooth radio is off, turn it on (equivalent to the Settings > Bluetooth toggle).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\check-adapter.ps1
  powershell -ExecutionPolicy Bypass -File .\check-adapter.ps1 -Seconds 30 -EnableRadio
#>
[CmdletBinding()]
param(
    [int]$Seconds = 20,
    [switch]$EnableRadio
)

# --- WinRT needs a single-threaded apartment; re-launch self in -STA if we're not already there ---
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argsList = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Seconds',$Seconds)
    if ($EnableRadio) { $argsList += '-EnableRadio' }
    & powershell.exe @argsList
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$SERVICE = '7add0001-f286-4c78-adda-520c4ba3500c'   # Matrack tracker GATT service
$TX      = '7add0002-f286-4c78-adda-520c4ba3500c'   # app writes commands here (Write)
$RX      = '7add0003-f286-4c78-adda-520c4ba3500c'   # tracker notifies telemetry here (Notify)

function Write-Head($t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan; Write-Host ('-' * $t.Length) -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  [PASS] $t" -ForegroundColor Green }
function Bad($t)  { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Warn($t) { Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Note($t) { Write-Host "  $t" -ForegroundColor Gray }

# --- WinRT async plumbing (AsTask + Await) ---
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Devices.Bluetooth.BluetoothAdapter,Windows.Devices.Bluetooth,ContentType=WindowsRuntime] | Out-Null
[Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider,Windows.Devices.Bluetooth,ContentType=WindowsRuntime] | Out-Null
[Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime] | Out-Null
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $type) {
    $t = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    $t.Wait(-1) | Out-Null
    $t.Result
}

Write-Host ''
Write-Host '=== Matrack Simulator - Bluetooth peripheral-role check ===' -ForegroundColor White

$verdict = 'PASS'   # downgraded to WARN/FAIL as problems are found

# ---------------------------------------------------------------- 1. Adapter + which physical device
Write-Head '1. Adapter'
$adapter = Await ([Windows.Devices.Bluetooth.BluetoothAdapter]::GetDefaultAsync()) ([Windows.Devices.Bluetooth.BluetoothAdapter])
if ($null -eq $adapter) {
    Bad 'No default Bluetooth adapter found. Plug in a BLE adapter and retry.'
    Write-Host ''; Write-Host 'VERDICT: FAIL - no adapter.' -ForegroundColor Red
    exit 2
}
$addr = ('{0:X12}' -f $adapter.BluetoothAddress) -replace '(..)(?=.)', '$1:'
$friendly = (Get-PnpDevice -Class Bluetooth -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'Adapter|Radio|Bluetooth' -and $_.FriendlyName -notmatch 'Enumerator' } |
    Select-Object -First 1 -ExpandProperty FriendlyName)
Ok ("Adapter present: $friendly")
Note ("Public address : $addr")

# ---------------------------------------------------------------- 2. Capabilities (the hard gate)
Write-Head '2. Capabilities'
Note ("IsLowEnergySupported            = $($adapter.IsLowEnergySupported)")
Note ("IsCentralRoleSupported          = $($adapter.IsCentralRoleSupported)")
Note ("IsPeripheralRoleSupported       = $($adapter.IsPeripheralRoleSupported)")
Note ("IsAdvertisementOffloadSupported = $($adapter.IsAdvertisementOffloadSupported)")

if (-not $adapter.IsLowEnergySupported) {
    Bad 'Adapter has no Bluetooth LE at all.'
    Write-Host ''; Write-Host 'VERDICT: FAIL - no BLE.' -ForegroundColor Red
    exit 2
}
if (-not $adapter.IsPeripheralRoleSupported) {
    Bad 'Peripheral role NOT supported - this adapter is central-only. It can scan but never advertise.'
    Note 'This is the #1 blocker. Use a peripheral-capable adapter or the ESP32. No software can work around it.'
    Write-Host ''; Write-Host 'VERDICT: FAIL - central-only, cannot advertise.' -ForegroundColor Red
    exit 2
}
Ok 'Peripheral role supported (necessary - but not sufficient by itself; see the connection note at the end).'

# ---------------------------------------------------------------- 3. Radio power
Write-Head '3. Radio power'
$radio = Await ($adapter.GetRadioAsync()) ([Windows.Devices.Radios.Radio])
if ($radio -and $radio.State -ne 'On') {
    Warn ("Bluetooth radio is $($radio.State).")
    if ($EnableRadio) {
        Await ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus]) | Out-Null
        $r = Await ($radio.SetStateAsync('On')) ([Windows.Devices.Radios.RadioAccessStatus])
        if ($r -eq 'Allowed' -and $radio.State -eq 'On') { Ok 'Turned the radio on.' }
        else { Bad "Could not turn the radio on ($r). Enable Bluetooth in Settings, then retry."; $verdict = 'FAIL' }
    } else {
        Bad 'Radio is off. Turn Bluetooth on (or re-run with -EnableRadio), then retry.'
        Write-Host ''; Write-Host 'VERDICT: FAIL - radio off (fixable).' -ForegroundColor Red
        exit 2
    }
} else {
    Ok 'Radio is on.'
}

# ---------------------------------------------------------------- 4. Stable connectable advertisement
Write-Head "4. Connectable advertisement (hold for ${Seconds}s)"
$result = Await ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProvider]::CreateAsync([Guid]$SERVICE)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProviderResult])
if ($result.Error -ne 'Success') {
    Bad "Could not create the GATT service: $($result.Error)"
    if ($result.Error -eq 'RadioNotAvailable') { Note 'Radio dropped - turn Bluetooth off/on and retry.' }
    Write-Host ''; Write-Host "VERDICT: FAIL - GATT service creation failed ($($result.Error))." -ForegroundColor Red
    exit 2
}
$provider = $result.ServiceProvider

# Add the same two characteristics the app publishes, so this mirrors the real GATT-server load.
$notifyP = New-Object Windows.Devices.Bluetooth.GenericAttributeProfile.GattLocalCharacteristicParameters
$notifyP.CharacteristicProperties = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::Notify
Await ($provider.Service.CreateCharacteristicAsync([Guid]$RX, $notifyP)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattLocalCharacteristicResult]) | Out-Null
$writeP = New-Object Windows.Devices.Bluetooth.GenericAttributeProfile.GattLocalCharacteristicParameters
$writeP.CharacteristicProperties = ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::Write -bor [Windows.Devices.Bluetooth.GenericAttributeProfile.GattCharacteristicProperties]::WriteWithoutResponse)
Await ($provider.Service.CreateCharacteristicAsync([Guid]$TX, $writeP)) ([Windows.Devices.Bluetooth.GenericAttributeProfile.GattLocalCharacteristicResult]) | Out-Null

$script:aborts = 0
$provider.add_AdvertisementStatusChanged({ param($s,$e) if ($e.Status -eq 'Aborted') { $script:aborts++ } }) | Out-Null

$ap = New-Object Windows.Devices.Bluetooth.GenericAttributeProfile.GattServiceProviderAdvertisingParameters
$ap.IsConnectable = $true
$ap.IsDiscoverable = $true
$provider.StartAdvertising($ap)

$started = 0
for ($i = 1; $i -le $Seconds; $i++) {
    Start-Sleep -Seconds 1
    $st = $provider.AdvertisementStatus
    if ($st -eq 'Started') { $started++ }
    Write-Host ("`r  holding... {0,2}/{1}s  status={2}  aborts={3}   " -f $i, $Seconds, $st, $script:aborts) -NoNewline
}
Write-Host ''
try { $provider.StopAdvertising() } catch {}

$pct = [math]::Round(100 * $started / $Seconds)
Note ("Advertised 'Started' for $started of $Seconds samples ($pct pct), with $script:aborts abort event(s).")
if ($started -eq $Seconds -and $script:aborts -eq 0) {
    Ok 'Advertisement held rock-solid - no aborts.'
} elseif ($pct -ge 80) {
    Warn 'Advertisement mostly held but flapped. Connections may be unreliable (address can change on each restart).'
    if ($verdict -eq 'PASS') { $verdict = 'WARN' }
} else {
    Bad 'Advertisement kept aborting - this adapter cannot hold a connectable advertisement.'
    $verdict = 'FAIL'
}

# ---------------------------------------------------------------- Verdict
Write-Head 'VERDICT'
switch ($verdict) {
    'PASS' { Write-Host '  PASS - advertising works and is stable on this adapter.' -ForegroundColor Green }
    'WARN' { Write-Host '  WARN - advertises but not perfectly stable; a phone may or may not connect.' -ForegroundColor Yellow }
    'FAIL' { Write-Host '  FAIL - this adapter is not usable as a stable BLE peripheral.' -ForegroundColor Red }
}
Write-Host ''
Write-Host '  IMPORTANT - advertising is NOT the same as accepting a connection.' -ForegroundColor White
Note 'Some adapters (e.g. Realtek 4.2) advertise fine here yet still fail to COMPLETE an incoming'
Note 'connection: the phone shows GATT 133 / status 8 timeout and the app log stays silent (the'
Note 'connection never reaches Windows). This script cannot detect that without a phone.'
Note ''
Note 'To confirm end-to-end: run MatrackSim.exe, attempt to connect from the ELD app, then check'
Note '  %LOCALAPPDATA%\MatrackSim\logs\matracksim.log'
Note 'If the app logged "Device subscribed" during your attempt: the connection reached Windows (good).'
Note 'If the log stayed silent through a ~20s attempt: the adapter cannot accept connections; use a'
Note 'different peripheral-capable adapter or the ESP32 advertiser.'
Write-Host ''
exit $(if ($verdict -eq 'FAIL') { 2 } elseif ($verdict -eq 'WARN') { 1 } else { 0 })
