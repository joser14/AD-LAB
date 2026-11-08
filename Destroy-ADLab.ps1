#Requires -RunAsAdministrator
<# Tears down the AD lab: stops and removes the VMs, deletes their disks, and removes the switch + NAT. #>
param(
    [string]$LabPath    = "D:\ADLab",
    [string]$SwitchName = "ADLab",
    [string]$Subnet     = "10.10.10",
    [switch]$KeepBase   # keep the base VHDs so a rebuild is fast
)
$ErrorActionPreference = 'Continue'
foreach ($n in 'DC01','WS01','WS02') {
    if (Get-VM -Name $n -ErrorAction SilentlyContinue) {
        Stop-VM -Name $n -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $n -Force
        Write-Host "Removed VM $n"
    }
}
Get-NetNat | Where-Object InternalIPInterfaceAddressPrefix -eq "$Subnet.0/24" | Remove-NetNat -Confirm:$false
if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) { Remove-VMSwitch -Name $SwitchName -Force }
foreach ($n in 'DC01','WS01','WS02') { Remove-Item "$LabPath\$n" -Recurse -Force -ErrorAction SilentlyContinue }
if (-not $KeepBase) { Remove-Item "$LabPath\Base" -Recurse -Force -ErrorAction SilentlyContinue }
if ($KeepBase) { Write-Host "Lab removed. Base disks kept." } else { Write-Host "Lab removed. Base disks deleted." }
