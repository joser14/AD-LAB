# Elevated launcher: detects the Server ISO, logs a transcript, runs the build unattended.
param(
    [string]$LabRoot  = $PSScriptRoot,
    [string]$Password = "ChangeMe!2026word",
    [string]$Log      = (Join-Path $PSScriptRoot "build-log.txt")
)
Start-Transcript -Path $Log -Append -Force | Out-Null
try {
    $iso = Get-ChildItem "$env:USERPROFILE\Downloads" -Filter *.iso -ErrorAction Stop |
        Where-Object { $_.Name -match 'server|SERVER_EVAL|20348|26100' -and $_.Name -notmatch 'Win11|kali' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $iso) { throw "No Windows Server ISO found in Downloads." }
    Write-Host "Using Server ISO: $iso"
    & "$LabRoot\Build-ADLab.ps1" -ServerIso $iso -LabPassword $Password
    Write-Host "=== BUILD SCRIPT RETURNED (exit) ==="
} catch {
    Write-Host "=== BUILD FAILED: $($_.Exception.Message) ==="
    Write-Host $_.ScriptStackTrace
} finally {
    Stop-Transcript | Out-Null
}
