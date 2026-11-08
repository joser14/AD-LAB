#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
  Builds an Active Directory lab on Hyper-V: 1 domain controller + 2 Windows 11 clients,
  fully unattended, with both clients joined to the domain.

  Network : internal switch "ADLab" 10.10.10.0/24 with NAT to the internet (host = 10.10.10.1)
  DC01    : Windows Server (Desktop Experience) 10.10.10.10  - AD DS + DNS, forest lab.local
  WS01    : Windows 11 Pro                       10.10.10.21  - joined to lab.local
  WS02    : Windows 11 Pro                       10.10.10.22  - joined to lab.local

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Build-ADLab.ps1 -ServerIso "C:\ISOs\SERVER_EVAL.iso"
#>
param(
    [string]$ServerIso,
    [string]$ClientIso   = "$env:USERPROFILE\Downloads\Win11_24H2_English_x64.iso",
    [string]$LabPath     = "D:\ADLab",
    [string]$DomainName  = "lab.local",
    [string]$NetBIOSName = "LAB",
    [string]$SwitchName  = "ADLab",
    [string]$Subnet      = "10.10.10",
    [string]$SqlHost     = "WS01",
    # SQL Server 2022 Developer bootstrapper (Microsoft). Change if Microsoft moves the link.
    [string]$SqlBootstrapUrl = "https://go.microsoft.com/fwlink/p/?linkid=2215158",
    [switch]$SkipSql
)

$ErrorActionPreference = 'Stop'
function Log($m) { Write-Host "[$(Get-Date -f HH:mm:ss)] $m" -ForegroundColor Cyan }

# ---------- inputs ----------
if (-not $ServerIso) {
    $ServerIso = Get-ChildItem "$env:USERPROFILE\Downloads" -Filter *.iso |
        Where-Object Name -match 'server' | Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ServerIso -or -not (Test-Path $ServerIso)) { throw "Windows Server ISO not found. Pass -ServerIso <path>." }
if (-not (Test-Path $ClientIso)) { throw "Windows 11 ISO not found at $ClientIso. Pass -ClientIso <path>." }
Log "Server ISO: $ServerIso"
Log "Client ISO: $ClientIso"

$sec = Read-Host "Password for Administrator / labadmin / domain admin (needs upper, lower, digit, 8+ chars)" -AsSecureString
$Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
if ($Password.Length -lt 8) { throw "Password too short." }
$sqlSec = Read-Host "Password for svc_sql (SQL service account; Enter = same as above)" -AsSecureString
$SqlSvcPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sqlSec))
if (-not $SqlSvcPassword) { $SqlSvcPassword = $Password }

$DCName = "DC01"; $DCIP = "$Subnet.10"; $Gateway = "$Subnet.1"
$Clients = @(@{ Name = "WS01"; IP = "$Subnet.21" }, @{ Name = "WS02"; IP = "$Subnet.22" })

$dcLocalCred  = New-Object PSCredential("Administrator", $sec)
$clientCred   = New-Object PSCredential("labadmin", $sec)
$domainCred   = New-Object PSCredential("$NetBIOSName\Administrator", $sec)
$TimeZone     = (Get-TimeZone).Id

New-Item -ItemType Directory -Force -Path $LabPath, "$LabPath\Base" | Out-Null

# ---------- network ----------
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    Log "Creating internal switch $SwitchName"
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
}
$ifIndex = (Get-NetAdapter | Where-Object Name -eq "vEthernet ($SwitchName)").ifIndex
if (-not (Get-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $Gateway -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $Gateway -PrefixLength 24 | Out-Null
}
if (-not (Get-NetNat | Where-Object InternalIPInterfaceAddressPrefix -eq "$Subnet.0/24")) {
    try { New-NetNat -Name "${SwitchName}NAT" -InternalIPInterfaceAddressPrefix "$Subnet.0/24" | Out-Null; Log "NAT created" }
    catch { Write-Warning "Could not create NAT (another NetNat may exist). Lab works, but VMs won't have internet. $_" }
}

# ---------- image helpers ----------
function New-BaseVhd {
    param($Iso, $EditionPattern, $VhdPath)
    if (Test-Path $VhdPath) { Log "Base disk exists: $VhdPath"; return }
    Log "Building base disk $VhdPath (this takes several minutes)"
    $mount = Mount-DiskImage -ImagePath $Iso -PassThru
    try {
        $isoDrive = ($mount | Get-Volume).DriveLetter
        $wim = @("$isoDrive`:\sources\install.wim", "$isoDrive`:\sources\install.esd") | Where-Object { Test-Path $_ } | Select-Object -First 1
        $img = Get-WindowsImage -ImagePath $wim | Where-Object ImageName -like $EditionPattern | Select-Object -First 1
        if (-not $img) {
            Get-WindowsImage -ImagePath $wim | Format-Table ImageIndex, ImageName | Out-String | Write-Host
            throw "No edition matching '$EditionPattern' in $Iso"
        }
        Log "  Edition: $($img.ImageName) (index $($img.ImageIndex))"

        New-VHD -Path $VhdPath -SizeBytes 80GB -Dynamic | Out-Null
        $disk = Mount-VHD -Path $VhdPath -Passthru | Get-Disk
        try {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT
            $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
            $efi | Format-Volume -FileSystem FAT32 -Force -Confirm:$false | Out-Null
            New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
            $win = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
            $win | Format-Volume -FileSystem NTFS -Force -Confirm:$false | Out-Null
            $efi | Add-PartitionAccessPath -AssignDriveLetter
            $win | Add-PartitionAccessPath -AssignDriveLetter
            $S = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber).DriveLetter
            $W = (Get-Partition -DiskNumber $disk.Number -PartitionNumber $win.PartitionNumber).DriveLetter

            Expand-WindowsImage -ImagePath $wim -Index $img.ImageIndex -ApplyPath "$W`:\" | Out-Null
            & bcdboot.exe "$W`:\Windows" /s "$S`:" /f UEFI | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "bcdboot failed" }
        } finally { Dismount-VHD -Path $VhdPath }
    } finally { Dismount-DiskImage -ImagePath $Iso | Out-Null }
}

function Get-Unattend {
    param($ComputerName, [switch]$Client)
    $c = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"'
    $pw = [Security.SecurityElement]::Escape($Password)
    $local = if ($Client) { @"
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>labadmin</Name><Group>Administrators</Group><DisplayName>labadmin</DisplayName>
            <Password><Value>$pw</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
"@ } else { "" }
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>$TimeZone</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $c>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $c>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword><Value>$pw</Value><PlainText>true</PlainText></AdministratorPassword>
$local      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

function New-LabVM {
    param($Name, $BaseVhd, [switch]$Client, [int64]$Memory = 4GB)
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { Log "VM $Name exists, skipping create"; return }
    Log "Creating VM $Name"
    $vmDir = "$LabPath\$Name"; New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
    $vhd = "$vmDir\$Name.vhdx"
    Copy-Item $BaseVhd $vhd

    # inject unattend.xml
    $disk = Mount-VHD -Path $vhd -Passthru | Get-Disk
    try {
        $W = (Get-Partition -DiskNumber $disk.Number | Where-Object Type -eq 'Basic' | Select-Object -Last 1)
        if (-not $W.DriveLetter -or $W.DriveLetter -eq [char]0) { $W | Add-PartitionAccessPath -AssignDriveLetter; $W = Get-Partition -DiskNumber $disk.Number -PartitionNumber $W.PartitionNumber }
        $panther = "$($W.DriveLetter):\Windows\Panther"
        New-Item -ItemType Directory -Force -Path $panther | Out-Null
        Get-Unattend -ComputerName $Name -Client:$Client | Set-Content -Path "$panther\unattend.xml" -Encoding UTF8
    } finally { Dismount-VHD -Path $vhd }

    New-VM -Name $Name -Generation 2 -MemoryStartupBytes $Memory -VHDPath $vhd -SwitchName $SwitchName -Path $LabPath | Out-Null
    Set-VM -Name $Name -ProcessorCount 2 -DynamicMemory -MemoryMinimumBytes 2GB -MemoryMaximumBytes $Memory -AutomaticCheckpointsEnabled $false
    Set-VMFirmware -VMName $Name -SecureBootTemplate MicrosoftWindows
    if ($Client) {
        Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
        Enable-VMTPM -VMName $Name
    }
    Start-VM -Name $Name
}

function Wait-PSDirect {
    param($VMName, [PSCredential]$Cred, [scriptblock]$Test = { $true }, [int]$TimeoutMin = 40)
    Log "Waiting for $VMName ..."
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        try { if (Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock $Test -ErrorAction Stop) { Log "  $VMName ready"; return } } catch {}
        Start-Sleep 15
    }
    throw "Timed out waiting for $VMName"
}

$SetIP = {
    param($IP, $Gw, $Dns)
    $nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceIndex $nic.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IP -PrefixLength 24 -DefaultGateway $Gw | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $Dns
}

# ---------- base images ----------
$serverBase = "$LabPath\Base\server-base.vhdx"
$clientBase = "$LabPath\Base\win11-base.vhdx"
New-BaseVhd -Iso $ServerIso -EditionPattern '*Standard*Desktop*' -VhdPath $serverBase
New-BaseVhd -Iso $ClientIso -EditionPattern 'Windows 11 Pro' -VhdPath $clientBase

# ---------- domain controller ----------
New-LabVM -Name $DCName -BaseVhd $serverBase -Memory 4GB
$adUp = { try { Import-Module ActiveDirectory -ErrorAction Stop; [bool](Get-ADDomain -ErrorAction Stop) } catch { $false } }

$alreadyDC = $false
try { $alreadyDC = Invoke-Command -VMName $DCName -Credential $domainCred -ScriptBlock $adUp -ErrorAction Stop } catch {}
if (-not $alreadyDC) {
    Wait-PSDirect -VMName $DCName -Cred $dcLocalCred
    Log "Configuring DC network and promoting to forest root $DomainName"
    Invoke-Command -VMName $DCName -Credential $dcLocalCred -ScriptBlock $SetIP -ArgumentList $DCIP, $Gateway, "127.0.0.1"
    Invoke-Command -VMName $DCName -Credential $dcLocalCred -ScriptBlock {
        param($Dom, $Nb, $Pw)
        Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
        Install-ADDSForest -DomainName $Dom -DomainNetbiosName $Nb -InstallDns -Force -NoRebootOnCompletion:$false `
            -SafeModeAdministratorPassword (ConvertTo-SecureString $Pw -AsPlainText -Force) -WarningAction SilentlyContinue | Out-Null
    } -ArgumentList $DomainName, $NetBIOSName, $Password -ErrorAction SilentlyContinue
    Start-Sleep 60
    Wait-PSDirect -VMName $DCName -Cred $domainCred -Test $adUp
}

Log "Seeding OU, users, domain admin and SQL service account"
Invoke-Command -VMName $DCName -Credential $domainCred -ScriptBlock {
    param($Pw, $SqlPw, $SqlHost, $Dom)
    $dn = (Get-ADDomain).DistinguishedName
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Lab'")) { New-ADOrganizationalUnit -Name Lab -Path $dn }
    $ou = "OU=Lab,$dn"
    function Add-LabUser($sam, $pw, $desc) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'")) {
            New-ADUser -Name $sam -SamAccountName $sam -UserPrincipalName "$sam@$Dom" -Description $desc -Path $ou `
                -Enabled $true -PasswordNeverExpires $true -AccountPassword (ConvertTo-SecureString $pw -AsPlainText -Force)
        }
    }
    Add-LabUser alice    $Pw    'Standard user'
    Add-LabUser bob      $Pw    'Standard user'
    Add-LabUser da_admin $Pw    'Domain admin'
    Add-LabUser svc_sql  $SqlPw 'SQL Server service account'

    if (-not (Get-ADGroup -Filter "Name -eq 'Lab Users'")) { New-ADGroup -Name 'Lab Users' -GroupScope Global -Path $ou }
    Add-ADGroupMember 'Lab Users'    -Members alice, bob
    Add-ADGroupMember 'Domain Admins' -Members da_admin

    # SPNs for the SQL instance on the SQL host, owned by the service account
    $fqdn = "$SqlHost.$Dom"
    foreach ($spn in "MSSQLSvc/${fqdn}:1433", "MSSQLSvc/$fqdn", "MSSQLSvc/${SqlHost}:1433") {
        Set-ADUser svc_sql -ServicePrincipalNames @{ Add = $spn } -ErrorAction SilentlyContinue
    }
    # forward outside names so VMs can reach the internet through the host NAT
    try { Set-DnsServerForwarder -IPAddress 1.1.1.1, 8.8.8.8 } catch {}
} -ArgumentList $Password, $SqlSvcPassword, $SqlHost, $DomainName

# ---------- AD CS: Enterprise Root CA + Web Enrollment on the DC ----------
Log "Installing AD CS (Enterprise Root CA + Web Enrollment) on $DCName"
Invoke-Command -VMName $DCName -Credential $domainCred -ScriptBlock {
    param($Nb)
    if (-not (Get-Service CertSvc -ErrorAction SilentlyContinue)) {
        Install-WindowsFeature ADCS-Cert-Authority, ADCS-Web-Enrollment -IncludeManagementTools | Out-Null
        Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName "$Nb-CA" `
            -KeyLength 2048 -HashAlgorithmName SHA256 -ValidityPeriod Years -ValidityPeriodUnits 10 -Force | Out-Null
        Install-AdcsWebEnrollment -Force | Out-Null
    }
    Get-Service CertSvc | Select-Object Name, Status
} -ArgumentList $NetBIOSName | Format-Table -AutoSize | Out-String | Write-Host

# ---------- GPO: turn Defender off across the lab (applies to Authenticated Users) ----------
Log "Creating 'Disable Defender' GPO linked at domain root"
Invoke-Command -VMName $DCName -Credential $domainCred -ScriptBlock {
    $name = 'Disable Defender'
    $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
    if (-not $gpo) { $gpo = New-GPO -Name $name }
    $k = 'HKLM\SOFTWARE\Policies\Microsoft\Windows Defender'
    Set-GPRegistryValue -Name $name -Key $k -ValueName 'DisableAntiSpyware'   -Type DWord -Value 1 | Out-Null
    Set-GPRegistryValue -Name $name -Key "$k\Real-Time Protection" -ValueName 'DisableRealtimeMonitoring' -Type DWord -Value 1 | Out-Null
    Set-GPRegistryValue -Name $name -Key "$k\Real-Time Protection" -ValueName 'DisableBehaviorMonitoring' -Type DWord -Value 1 | Out-Null
    # Security filtering: Authenticated Users already applies by default; make it explicit
    Set-GPPermission -Name $name -TargetName 'Authenticated Users' -TargetType Group -PermissionLevel GpoApply -Replace | Out-Null
    $dn = (Get-ADDomain).DistinguishedName
    if (-not (Get-GPInheritance -Target $dn).GpoLinks.DisplayName -contains $name) {
        New-GPLink -Name $name -Target $dn -LinkEnabled Yes | Out-Null
    }
} -ErrorAction SilentlyContinue

# ---------- clients ----------
foreach ($c in $Clients) { New-LabVM -Name $c.Name -BaseVhd $clientBase -Client -Memory 4GB }

foreach ($c in $Clients) {
    $joined = $false
    try { $joined = Invoke-Command -VMName $c.Name -Credential $domainCred -ScriptBlock { (Get-CimInstance Win32_ComputerSystem).PartOfDomain } -ErrorAction Stop } catch {}
    if ($joined) { Log "$($c.Name) already joined"; continue }

    Wait-PSDirect -VMName $c.Name -Cred $clientCred
    Log "Joining $($c.Name) ($($c.IP)) to $DomainName"
    Invoke-Command -VMName $c.Name -Credential $clientCred -ScriptBlock $SetIP -ArgumentList $c.IP, $Gateway, $DCIP
    Invoke-Command -VMName $c.Name -Credential $clientCred -ScriptBlock {
        param($Dom, $User, $Pw)
        $cred = New-Object PSCredential($User, (ConvertTo-SecureString $Pw -AsPlainText -Force))
        Add-Computer -DomainName $Dom -Credential $cred -Force -Restart
    } -ArgumentList $DomainName, "$NetBIOSName\Administrator", $Password -ErrorAction SilentlyContinue
}

# ---------- verify ----------
foreach ($c in $Clients) {
    Wait-PSDirect -VMName $c.Name -Cred $domainCred -Test { (Get-CimInstance Win32_ComputerSystem).PartOfDomain -and (Test-ComputerSecureChannel) }
}
# ---------- SQL Server 2022 Developer on $SqlHost, running as LAB\svc_sql ----------
if (-not $SkipSql) {
    $installed = Invoke-Command -VMName $SqlHost -Credential $domainCred -ScriptBlock { [bool](Get-Service MSSQLSERVER -ErrorAction SilentlyContinue) }
    if ($installed) { Log "SQL Server already installed on $SqlHost" }
    else {
        $media = "$LabPath\Media\SQL"
        New-Item -ItemType Directory -Force -Path $media | Out-Null
        $pkg = Get-ChildItem $media -Filter 'SQLServer*-x64-*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pkg) {
            Log "Downloading SQL Server 2022 Developer media on the host (~1.2 GB)"
            $boot = "$LabPath\Media\SQL2022-SSEI-Dev.exe"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $SqlBootstrapUrl -OutFile $boot -UseBasicParsing
            Start-Process $boot -ArgumentList "/ACTION=Download /MEDIAPATH=`"$media`" /MEDIATYPE=CAB /QUIET" -Wait
            $pkg = Get-ChildItem $media -Filter 'SQLServer*-x64-*.exe' | Select-Object -First 1
            if (-not $pkg) { throw "SQL media download failed. Check $media or pass -SqlBootstrapUrl." }
        }

        Log "Copying SQL media into $SqlHost"
        $s = New-PSSession -VMName $SqlHost -Credential $domainCred
        try {
            Invoke-Command -Session $s -ScriptBlock { New-Item -ItemType Directory -Force -Path C:\SQLDownload | Out-Null }
            Get-ChildItem $media -File | ForEach-Object { Copy-Item $_.FullName -Destination C:\SQLDownload\ -ToSession $s }

            Log "Installing SQL Server on $SqlHost (10-20 min)"
            Invoke-Command -Session $s -ScriptBlock {
                param($Nb, $SvcPw, $SaPw)
                $exe = Get-ChildItem C:\SQLDownload -Filter 'SQLServer*-x64-*.exe' | Select-Object -First 1
                Start-Process $exe.FullName -ArgumentList '/q /x:C:\SQLMedia' -Wait
                $setupArgs = @(
                    '/Q', '/ACTION=Install', '/FEATURES=SQLENGINE', '/INSTANCENAME=MSSQLSERVER',
                    "/SQLSVCACCOUNT=`"$Nb\svc_sql`"", "/SQLSVCPASSWORD=`"$SvcPw`"", '/SQLSVCSTARTUPTYPE=Automatic',
                    "/SQLSYSADMINACCOUNTS=`"$Nb\Domain Admins`" `"$Nb\da_admin`"",
                    '/SECURITYMODE=SQL', "/SAPWD=`"$SaPw`"", '/TCPENABLED=1',
                    '/UPDATEENABLED=False', '/IACCEPTSQLSERVERLICENSETERMS'
                ) -join ' '
                $p = Start-Process C:\SQLMedia\setup.exe -ArgumentList $setupArgs -Wait -PassThru
                if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
                    throw "SQL setup exit code $($p.ExitCode). See C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\Summary.txt"
                }
                New-NetFirewallRule -DisplayName 'SQL Server 1433' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow | Out-Null
                New-NetFirewallRule -DisplayName 'SQL Browser 1434' -Direction Inbound -Protocol UDP -LocalPort 1434 -Action Allow | Out-Null
                Get-CimInstance Win32_Service -Filter "Name='MSSQLSERVER'" | Select-Object Name, State, StartName
            } -ArgumentList $NetBIOSName, $SqlSvcPassword, $Password | Format-Table Name, State, StartName -AutoSize | Out-String | Write-Host
        } finally { Remove-PSSession $s }
    }
}

Log "Computers in AD:"
Invoke-Command -VMName $DCName -Credential $domainCred -ScriptBlock { Get-ADComputer -Filter * | Select-Object Name, DNSHostName } |
    Format-Table Name, DNSHostName -AutoSize | Out-String | Write-Host

Write-Host ""
Write-Host "AD lab is ready." -ForegroundColor Green
Write-Host "  Domain      : $DomainName ($NetBIOSName)"
Write-Host "  DC01        : $DCIP   sign in as $NetBIOSName\Administrator"
Write-Host "  WS01 / WS02 : $Subnet.21 / $Subnet.22   sign in as $NetBIOSName\alice, $NetBIOSName\bob or $NetBIOSName\da_admin"
Write-Host "  Domain admin: $NetBIOSName\da_admin (member of Domain Admins)"
Write-Host "  AD CS       : Enterprise Root CA '$NetBIOSName-CA' on DC01, web enrollment at http://$DCIP/certsrv"
if (-not $SkipSql) {
Write-Host "  SQL Server  : $SqlHost ($SqlHost.$DomainName,1433) running as $NetBIOSName\svc_sql; sysadmins = Domain Admins, da_admin, sa"
}
Write-Host "  Accounts use the password you entered (svc_sql uses its own if you set one). Open VMs from Hyper-V Manager."
