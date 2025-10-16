#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Migrates FSLogix profiles and redirected folders using Robocopy
    
.DESCRIPTION
    This script migrates user data from a source file share to a destination file share by:
    1. Copying FSLogix profiles from source to destination
    2. Mounting each FSLogix VHDX file using DiskPart
    3. Copying redirected folders (Documents, Videos, Pictures, Music, Desktop, Downloads, Favorites) 
       from source into the mounted FSLogix profile
    4. Repairing registry references (Explorer paths)
    5. Safely unmounting the VHDX files

    This consolidates separated redirected folders back into FSLogix profiles.
    All Robocopy operations preserve security (ACLs, owner, SACL), timestamps and attributes using /COPYALL and /DCOPY:DAT (directory copy flags only support D,A,T)
    with /SECFIX and /TIMFIX to repair security or timestamp discrepancies on retries.
    The VHD/VHDX mounting process now explicitly assigns a free drive letter using DiskPart (select vdisk -> attach vdisk -> select partition 1 -> assign letter=) to avoid
    situations where Windows does not automatically allocate a letter. A fallback using Mount-DiskImage is attempted if DiskPart assignment fails.
    
.PARAMETER SourceShare
    Source FSLogix file share path (e.g., "\\server1\fslogix$")
    
.PARAMETER DestinationShare
    Destination file share path (e.g., "\\server2\fslogix$")
    
.PARAMETER RedirectedShare
    Separate file share root containing redirected folders by username (e.g., "\\server1\Redirected$" where paths are Username\Documents, Username\Desktop, etc.)
    
.PARAMETER LogPath
    Path for migration log files (default: C:\Temp\FSLogix-Migration-Logs)
    
.PARAMETER TestMode
    Run in test mode (no actual data copying, just validation)
    
.EXAMPLE
    Run for all users discovered in source share:
    .\FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix" -DestinationShare "\\new-server\fslogix" -RedirectedShare "\\server1\Redirected" -LogPath "C:\Temp\FSLogix-Migration-Logs" -AllUsers

    Run for specific users by prefix:
    .\FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix" -DestinationShare "\\new-server\fslogix" -RedirectedShare "\\server1\Redirected" -LogPath "C:\Temp\FSLogix-Migration-Logs" -UserPrefix "eng,test"
    
    Run for specific users by explicit list:
    .\FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix" -DestinationShare "\\new-server\fslogix" -RedirectedShare "\\server1\Redirected" -LogPath "C:\Temp\FSLogix-Migration-Logs" -UserList "user1,user2"
    
    Run with existing profile action set to Maintain (skip existing profiles):
    .\FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix" -DestinationShare "\\new-server\fslogix" -RedirectedShare "\\server1\Redirected" -LogPath "C:\Temp\FSLogix-Migration-Logs" -UserList "user1,user2" -ExistingProfileAction Maintain
    
    Run with only destination as Azure Files share:
    $dstKey = ConvertTo-SecureString 'DEST_ACCOUNT_KEY_VALUE' -AsPlainText -Force
    .\FSLogix-Profile-Migration.ps1 `
    -SourceShare "\\src-fileserver\\profiles" -SourceAzure:$false `
    -DestinationShare "\\destacct.file.core.windows.net\\profiles" -DestinationAzure -DestinationStorageAccountName "destacct" -DestinationStorageAccountKey $dstKey `
    -RedirectedShare "\\src-redirected-fileserver\\Redirected" `
    -LogPath "C:\\Temp\\FSLogix-Migration-Logs" `
    -UserList "user1,user2"

    Run with both Azure Files shares and non-interactive (no prompts):
    $srcKey = ConvertTo-SecureString 'SOURCE_ACCOUNT_KEY_VALUE' -AsPlainText -Force
    $dstKey = ConvertTo-SecureString 'DEST_ACCOUNT_KEY_VALUE' -AsPlainText -Force
    .\FSLogix-Profile-Migration.ps1 `
    -SourceShare "\\sourceacct.file.core.windows.net\\profiles" -SourceAzure -SourceStorageAccountName "sourceacct" -SourceStorageAccountKey $srcKey`
    -DestinationShare "\\destacct.file.core.windows.net\\profiles" -DestinationAzure -DestinationStorageAccountName "destacct" -DestinationStorageAccountKey $dstKey`
    -RedirectedShare "\\sourceacct.file.core.windows.net\\Redirected" `
    -LogPath "C:\\Temp\\FSLogix-Migration-Logs" `
    -AllUsers

#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceShare,
    
    [Parameter(Mandatory=$true)]
    [string]$DestinationShare,
    
    [Parameter(Mandatory=$true)]
    [string]$RedirectedShare,
    
    [Parameter(Mandatory=$true)]
    [string]$LogPath = "C:\Temp\FSLogix-Migration-Logs",
    
    [Parameter(Mandatory=$false)]
    [switch]$TestMode,

    # New targeting parameters
    [Parameter(Mandatory=$false, HelpMessage='Process all discovered FSLogix users')]
    [switch]$AllUsers,

    [Parameter(Mandatory=$false, HelpMessage='Comma-separated or array list of specific usernames to process')]
    [string[]]$UserList,

    [Parameter(Mandatory=$false, HelpMessage='One or more username prefixes (comma-separated accepted)')]
    [string[]]$UserPrefix,

    [Parameter(Mandatory=$false, HelpMessage='Action when destination FSLogix profile already exists: Overwrite or Maintain (default: Overwrite)')]
    [ValidateSet('Overwrite','Maintain')]
    [string]$ExistingProfileAction = 'Overwrite'
    ,
    # Azure Files support (optional)
    [Parameter(Mandatory=$false, HelpMessage='Treat source share as Azure Files UNC (\\\\<account>.file.core.windows.net\\\\<share>)')]
    [switch]$SourceAzure,
    [Parameter(Mandatory=$false, HelpMessage='Treat destination share as Azure Files UNC (\\\\<account>.file.core.windows.net\\\\<share>)')]
    [switch]$DestinationAzure,
    [Parameter(Mandatory=$false, HelpMessage='Storage account name for source Azure Files share')]
    [string]$SourceStorageAccountName,
    [Parameter(Mandatory=$false, HelpMessage='Storage account key (secure) for source Azure Files share')]
    [SecureString]$SourceStorageAccountKey,
    [Parameter(Mandatory=$false, HelpMessage='Storage account name for destination Azure Files share')]
    [string]$DestinationStorageAccountName,
    [Parameter(Mandatory=$false, HelpMessage='Storage account key (secure) for destination Azure Files share')]
    [SecureString]$DestinationStorageAccountKey
)

# Normalize spelling (Mantain -> Maintain)
if ($ExistingProfileAction -eq 'Mantain') { $ExistingProfileAction = 'Maintain' }

# Script configuration
$ErrorActionPreference = "Stop"
$RedirectedFolders = @("Documents", "Videos", "Pictures", "Music", "Desktop", "Downloads", "Favorites")
$StartTime = Get-Date
$Global:AzureMountedShares = @() # Track azure shares mounted
$script:FinalExitCode = 0

# Create base log path if missing
if (!(Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }

# Create dated subdirectory (format: YYYY-MM-dd_hh-mm)
$LogRunFolderName = (Get-Date -Format 'yyyy-MM-dd_HH-mm')
$LogRunPath = Join-Path $LogPath $LogRunFolderName
if (!(Test-Path $LogRunPath)) { New-Item -ItemType Directory -Path $LogRunPath -Force | Out-Null }

# Primary session log now resides in run folder
$LogFile = Join-Path $LogRunPath "FSLogix-Migration-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$Global:VHDXMountMethod = @{}  # Tracks mount method per VHD path (DiskPart | MountDiskImage)

# Initialize logging
if (!(Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console with color coding
    switch ($Level) {
        "ERROR" { Write-Host $logEntry -ForegroundColor Red }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        default { Write-Host $logEntry -ForegroundColor White }
    }
    
    # Write to log file
    Add-Content -Path $LogFile -Value $logEntry
}

function Test-Prerequisites {
    Write-Log "Checking prerequisites..."
    
    # Check if running as administrator
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator"
    }
    
    # Check source share accessibility
    if (!(Test-Path $SourceShare)) {
        throw "Source share not accessible: $SourceShare"
    }
    
    # Check destination share accessibility
    if (!(Test-Path $DestinationShare)) {
        throw "Destination share not accessible: $DestinationShare"
    }
    
    # Check redirected share accessibility
    if (!(Test-Path $RedirectedShare)) {
        throw "Redirected share not accessible: $RedirectedShare"
    }
    
    # Check if DiskPart is available
    if (!(Get-Command "diskpart.exe" -ErrorAction SilentlyContinue)) {
        throw "DiskPart is not available on this system"
    }
    
    # Check if Robocopy is available
    if (!(Get-Command "robocopy.exe" -ErrorAction SilentlyContinue)) {
        throw "Robocopy is not available on this system"
    }
    
    Write-Log "Prerequisites check passed" -Level "SUCCESS"
}

#region AzureFilesHelpers
function Invoke-AzureDecision {
    param(
        [string]$SharePath,
        [string]$Role,  # 'Source' or 'Destination'
        [bool]$ExplicitAzureValue,   # Value of switch (true if present and set, false if present and explicitly negative)
        [bool]$WasParameterSpecified  # Did caller specify parameter at all
    )
    $patternMatch = ($SharePath -match '^\\\\[a-z0-9\-]+\.file\.core\.windows\.net\\')
    if ($WasParameterSpecified) { return $ExplicitAzureValue }
    if ($patternMatch) {
        $resp = Read-Host "Detected Azure Files pattern for $Role share ($SharePath). Treat as Azure? (Y/N)"
        return ($resp.ToUpper() -eq 'Y')
    }
    $resp2 = Read-Host "Treat $Role share as Azure Files? (Y/N)"
    return ($resp2.ToUpper() -eq 'Y')
}
function Convert-SecureToPlain {
    param([SecureString]$Secure)
    if (-not $Secure) { return $null }
    return (New-Object System.Net.NetworkCredential('', $Secure)).Password
}
function Get-AzureAccountNameFromUNC {
    param([string]$UNC)
    if ($UNC -match '^\\\\([a-z0-9\-]+)\.file\.core\.windows\.net\\') { return $Matches[1] }
    return $null
}
function Connect-AzureFileShare {
    param(
        [Parameter(Mandatory)] [string]$UNCPath,
        [Parameter(Mandatory)] [string]$StorageAccountName,
        [Parameter(Mandatory)] [SecureString]$StorageAccountKey,
        [switch]$TestOnly
    )
    Write-Log "Establishing Azure Files connection: $UNCPath" -Level INFO
    if ($TestOnly) { Write-Log "TEST MODE: Would connect Azure Files share $UNCPath" -Level WARNING; return $true }
    $plain = Convert-SecureToPlain $StorageAccountKey
    if (-not $plain) { throw "Storage account key not provided for $UNCPath" }
    $masked = if ($plain.Length -ge 8) { $plain.Substring(0,4)+'...'+$plain.Substring($plain.Length-4) } else { '***' }
    Write-Log "Using account '$StorageAccountName' (Key: $masked)" -Level INFO
    $cmd = "net use $UNCPath /user:localhost\$StorageAccountName $plain /persistent:no"
    cmd.exe /c $cmd 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to connect Azure Files share ($LASTEXITCODE): $out" -Level ERROR
        return $false
    }
    $Global:AzureMountedShares += $UNCPath
    Write-Log "Azure Files share connected: $UNCPath" -Level SUCCESS
    return $true
}
#endregion AzureFilesHelpers

function Get-FSLogixUsers {
    Write-Log "Discovering FSLogix users from source share (username-based folders)..."

    $users = @()
    $userFolders = Get-ChildItem -Path $SourceShare -Directory -ErrorAction SilentlyContinue

    foreach ($userFolder in $userFolders) {
        $username = $userFolder.Name
        $profilePath = $userFolder.FullName

        # Find container (prefer .vhdx then .vhd)
        $containerFiles = @(Get-ChildItem -Path $profilePath -Filter "Profile_*.vhdx" -ErrorAction SilentlyContinue)
        if (-not $containerFiles -or $containerFiles.Count -eq 0) {
            $containerFiles = @(Get-ChildItem -Path $profilePath -Filter "Profile_*.vhd" -ErrorAction SilentlyContinue)
        }
        if (-not $containerFiles -or $containerFiles.Count -eq 0) { continue }

        $container = $containerFiles[0].FullName

        $userInfo = [PSCustomObject]@{
            Username   = $username
            SourcePath = $profilePath
            ProfilePath= $profilePath
            VHDXFile   = $container
        }
        $users += $userInfo
        Write-Log "Found user '$username' (Container: $([IO.Path]::GetFileName($container)))"
    }

    Write-Log "Discovered $($users.Count) FSLogix users" -Level "SUCCESS"
    return $users
}

# New helper to resolve which users to process based on parameters or interactive selection
function Resolve-TargetUsers {
    param(
        [Parameter(Mandatory)] [array]$AllDiscoveredUsers,
        [switch]$AllUsers,
        [string[]]$UserList,
        [string[]]$UserPrefix
    )

    if (-not $AllDiscoveredUsers -or $AllDiscoveredUsers.Count -eq 0) { return @() }

    $allNames = $AllDiscoveredUsers.Username

    # Normalize comma-separated inputs for UserList and UserPrefix
    $normalize = {
        param($items)
        if (-not $items) { return @() }
        $flat = @()
        foreach ($i in $items) { $flat += ($i -split ',') }
        return ($flat | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    if ($AllUsers) {
        Write-Log 'Target selection: All users (parameter)' -Level INFO
        return $AllDiscoveredUsers
    }

    $normalizedList   = & $normalize $UserList
    $normalizedPrefix = & $normalize $UserPrefix

    if ($normalizedList.Count -gt 0) {
        Write-Log "Target selection: Explicit list provided ($($normalizedList -join ', '))" -Level INFO
        $selected = $AllDiscoveredUsers | Where-Object { $_.Username -in $normalizedList }
        $missing = $normalizedList | Where-Object { $_ -notin $allNames }
        if ($missing) { Write-Log "These specified users were not found: $($missing -join ', ')" -Level WARNING }
        return $selected
    }

    if ($normalizedPrefix.Count -gt 0) {
        Write-Log "Target selection: Prefix match on ($($normalizedPrefix -join ', '))" -Level INFO
        $selected = foreach ($p in $normalizedPrefix) { $AllDiscoveredUsers | Where-Object { $_.Username.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase) } }
        $selected = $selected | Sort-Object Username -Unique
        if (-not $selected) { Write-Log 'No users matched provided prefix(es).' -Level WARNING }
        return $selected
    }

    # Interactive selection if nothing specified
    Write-Host ''
    Write-Host 'Select scope of users to process:' -ForegroundColor Cyan
    Write-Host '[A] All users'
    Write-Host '[L] Explicit comma-separated list'
    Write-Host '[P] Prefix-based (users whose names start with given string(s))'
    Write-Host ''
    $choice = Read-Host 'Enter choice (A/L/P)'

    switch ($choice.ToUpperInvariant()) {
        'A' { Write-Log 'Interactive selection: All users' -Level INFO; return $AllDiscoveredUsers }
        'L' {
            $raw = Read-Host 'Enter comma-separated list of usernames'
            $items = ($raw -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if (-not $items) { Write-Log 'No users entered.' -Level ERROR; return @() }
            $selected = $AllDiscoveredUsers | Where-Object { $_.Username -in $items }
            $missing = $items | Where-Object { $_ -notin $allNames }
            if ($missing) { Write-Log "Users not found: $($missing -join ', ')" -Level WARNING }
            return $selected
        }
        'P' {
            $raw = Read-Host 'Enter one or more prefixes (comma-separated)'
            $prefixes = ($raw -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if (-not $prefixes) { Write-Log 'No prefixes entered.' -Level ERROR; return @() }
            $selected = foreach ($p in $prefixes) { $AllDiscoveredUsers | Where-Object { $_.Username.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase) } }
            $selected = $selected | Sort-Object Username -Unique
            if (-not $selected) { Write-Log 'No users matched your prefix(es).' -Level WARNING }
            Write-Log "Interactive selection: Prefix(es) $($prefixes -join ', ') matched $($selected.Count) user(s)" -Level INFO
            return $selected
        }
        Default { Write-Log "Invalid selection '$choice'" -Level ERROR; return @() }
    }
}

function Get-FreeDriveLetter {
    # Prefer starting near T: (often unused) then fall back through the alphabet
    $preferredOrder = @('T','U','V','W','X','Y','Z') + ([char[]]([int][char]'D'..[int][char]'S'))
    $inUse = [System.IO.DriveInfo]::GetDrives().Name.Replace(':\\','')
    foreach ($l in $preferredOrder | Select-Object -Unique) {
        if ($inUse -notcontains $l) { return $l }
    }
    throw "No free drive letters available for mounting VHDX"
}
function Copy-FSLogixProfile {
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$UserInfo,
        [Parameter(Mandatory=$true)] [string]$ExistingProfileAction
    )
    $destinationUserPath = Join-Path $DestinationShare $UserInfo.Username
    $profileExists = Test-Path $destinationUserPath
    if ($profileExists -and $ExistingProfileAction -eq 'Maintain') {
        Write-Log "Destination profile exists for $($UserInfo.Username); maintain mode selected: skipping profile copy." -Level INFO
        return @{ Path=$destinationUserPath; Copied=$false; SkippedReason='MaintainExisting' }
    }
    Write-Log "Copying FSLogix profile for user: $($UserInfo.Username) (Mode: $ExistingProfileAction)"
    if ($TestMode) {
        $modePhrase = if ($profileExists) { 'overwrite existing' } else { 'create new' }
        Write-Log "TEST MODE: Would $modePhrase profile at $destinationUserPath" -Level WARNING
        return @{ Path=$destinationUserPath; Copied=$false; SkippedReason='TestMode' }
    }
    if (-not $profileExists) { New-Item -ItemType Directory -Path $destinationUserPath -Force | Out-Null }
    elseif ($ExistingProfileAction -eq 'Overwrite') { Write-Log "Overwrite mode: existing content may be updated via robocopy /MIR" -Level INFO }
    $robocopyArgs = @(
        "`"$($UserInfo.SourcePath)`"",
        "`"$destinationUserPath`"",
        "/MIR","/COPYALL","/DCOPY:DAT","/SECFIX","/TIMFIX","/MT:8","/R:3","/W:10",
        "/LOG+:`"$LogRunPath/robocopy-profile-$($UserInfo.Username).log`"","/TEE","/NP","/NDL"
    )
    $result = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
    if ($result.ExitCode -ge 8) { throw "Robocopy failed with exit code $($result.ExitCode) for user $($UserInfo.Username)" }
    Write-Log "Successfully processed FSLogix profile for user: $($UserInfo.Username)" -Level SUCCESS
    return @{ Path=$destinationUserPath; Copied=$true }
}

function Mount-FSLogixVHDX {
    param(
        [Parameter(Mandatory=$true)]
        [string]$VHDXPath
    )
    
    Write-Log "Mounting VHDX file: $VHDXPath"
    
    if ($TestMode) {
        Write-Log "TEST MODE: Would mount VHDX: $VHDXPath" -Level "WARNING"
        return "T:"  # Return fake drive letter for testing
    }
    
    $driveLetterChar = Get-FreeDriveLetter
    $diskPartScript = @"
select vdisk file="$VHDXPath"
attach vdisk
select partition 1
assign letter=$driveLetterChar
"@

    $tempScriptPath = Join-Path $env:TEMP "diskpart_mount_$(Get-Random).txt"
    $diskPartScript | Out-File -FilePath $tempScriptPath -Encoding ASCII

    $driveLetter = ("{0}:" -f $driveLetterChar)
    $mounted = $false
    try {
        $result = Start-Process -FilePath "diskpart.exe" -ArgumentList "/s `"$tempScriptPath`"" -Wait -PassThru -NoNewWindow
        if ($result.ExitCode -eq 0 -and (Test-Path "$driveLetter\")) {
            $mounted = $true
            $Global:VHDXMountMethod[$VHDXPath] = 'DiskPart'
        } else {
            Write-Log "DiskPart did not successfully assign drive letter $driveLetter. Attempting Mount-DiskImage fallback." -Level "WARNING"
        }
    } catch {
        Write-Log "DiskPart mount attempt failed: $($_.Exception.Message). Will try Mount-DiskImage." -Level "WARNING"
    } finally {
        if (Test-Path $tempScriptPath) { Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue }
    }

    if (-not $mounted) {
        try {
            $img = Mount-DiskImage -ImagePath $VHDXPath -PassThru -ErrorAction Stop
            Start-Sleep -Seconds 2
            $disk = ($img | Get-Disk -ErrorAction Stop)
            $part = ($disk | Get-Partition | Where-Object { $_.Type -ne 'Reserved' } | Sort-Object -Property Size -Descending | Select-Object -First 1)
            if (-not $part) { throw "Unable to find data partition inside VHDX" }
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $driveLetterChar -ErrorAction Stop | Out-Null
            $mounted = $true
            $Global:VHDXMountMethod[$VHDXPath] = 'MountDiskImage'
        } catch {
            throw "Failed to mount and assign drive letter for VHDX '$VHDXPath': $($_.Exception.Message)"
        }
    }

    if (-not (Test-Path $driveLetter)) { throw "Drive letter $driveLetter not accessible after mount" }
    Write-Log "Successfully mounted VHDX to drive $driveLetter (Method: $($Global:VHDXMountMethod[$VHDXPath]))" -Level "SUCCESS"
    return $driveLetter
}

function Dismount-FSLogixVHDX {
    param(
        [Parameter(Mandatory=$true)]
        [string]$VHDXPath,
        
        [Parameter(Mandatory=$true)]
        [string]$DriveLetter
    )
    
    Write-Log "Dismounting VHDX file: $VHDXPath (Drive: $DriveLetter)"
    
    if ($TestMode) {
        Write-Log "TEST MODE: Would dismount VHDX: $VHDXPath" -Level "WARNING"
        return
    }
    
    $method = $Global:VHDXMountMethod[$VHDXPath]
    if (-not $method) { $method = 'DiskPart' }

    if ($method -eq 'MountDiskImage') {
        try {
            Dismount-DiskImage -ImagePath $VHDXPath -ErrorAction Stop
            Write-Log "Successfully dismounted VHDX (Mount-DiskImage)" -Level "SUCCESS"
        } catch {
            Write-Log "Failed to dismount via Dismount-DiskImage: $($_.Exception.Message)" -Level "ERROR"
        }
        return
    }

    # DiskPart path
    $diskPartScript = @"
select vdisk file="$VHDXPath"
detach vdisk
"@
    $tempScriptPath = Join-Path $env:TEMP "diskpart_dismount_$(Get-Random).txt"
    $diskPartScript | Out-File -FilePath $tempScriptPath -Encoding ASCII
    try {
        $result = Start-Process -FilePath "diskpart.exe" -ArgumentList "/s `"$tempScriptPath`"" -Wait -PassThru -NoNewWindow
        if ($result.ExitCode -ne 0) {
            Write-Log "DiskPart dismount failed with exit code $($result.ExitCode)" -Level "WARNING"
        } else {
            Write-Log "Successfully dismounted VHDX" -Level "SUCCESS"
        }
    } finally {
        if (Test-Path $tempScriptPath) { Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue }
    }
}

function Copy-RedirectedFolders {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Username,
        
        [Parameter(Mandatory=$true)]
        [string]$MountedDrive
        
    )
    
    Write-Log "Copying redirected folders for user: $Username"
    
    $successCount = 0
    $errorCount = 0
    
    # Destination user profile root inside mounted VHDX
    $userProfileInVHDXPath = Join-Path "$MountedDrive" "Profile"
    if (!(Test-Path $userProfileInVHDXPath)) {
        # Fallback: pick first non-default profile dir if exact username dir not found
        $candidates = Get-ChildItem -Path "$MountedDrive\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'Public','Default','Default User','All Users' }
        if ($candidates.Count -gt 0) {
            Write-Log "Username directory '$Username' not found in VHDX. Using fallback: $($candidates[0].Name)" -Level "WARNING"
            $userProfileInVHDXPath = $candidates[0].FullName
        } else {
            Write-Log "No suitable user profile directory found inside mounted VHDX for $Username" -Level "ERROR"
            return @{ Success = 0; Errors = $RedirectedFolders.Count }
        }
    }
    
    foreach ($folder in $RedirectedFolders) {
        try {
            # Source redirected folder path (separate share): <RedirectedShare>\<Username>\<Folder>
            $sourceFolderPath = Join-Path (Join-Path $RedirectedShare $Username) $folder
            $destinationFolderPath = Join-Path $userProfileInVHDXPath $folder
            
            if (!(Test-Path $sourceFolderPath)) {
                Write-Log "Source redirected folder not found, skipping: $sourceFolderPath" -Level "WARNING"
                continue
            }
            
            Write-Log "Copying $folder from $sourceFolderPath to $destinationFolderPath"
            
            if ($TestMode) {
                Write-Log "TEST MODE: Would copy $folder for $Username" -Level "WARNING"
                continue
            }
            
            if (!(Test-Path $destinationFolderPath)) {
                New-Item -ItemType Directory -Path $destinationFolderPath -Force | Out-Null
            }
            
            $robocopyArgs = @(
                "`"$sourceFolderPath`"",
                "`"$destinationFolderPath`"",
                "/MIR",
                "/COPYALL",
                "/DCOPY:DAT",
                "/SECFIX",
                "/TIMFIX",
                "/MT:4",
                "/R:3",
                "/W:10",
                "/LOG+:`"$LogRunPath/robocopy-$folder-$Username.log`"",
                "/NP",
                "/NDL",
                "/XJ"
            )
            $result = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow
            if ($result.ExitCode -ge 8) {
                Write-Log "Failed to copy $folder for $Username ($Username) - Exit code: $($result.ExitCode)" -Level "ERROR"
                $errorCount++
            } else {
                Write-Log "Successfully copied $folder for $Username" -Level "SUCCESS"
                $successCount++
            }
        } catch {
            Write-Log "Error copying $folder for $Username : $($_.Exception.Message)"
            $errorCount++
        }
    }
    Write-Log "Redirected folders migration completed for $Username : $successCount success, $errorCount errors"
    return @{ Success = $successCount; Errors = $errorCount }
}

# New: fix user registry entries inside mounted profile (Explorer Shell Folders)
function Repair-UserRegistry {
    param(
        [Parameter(Mandatory=$true)] [string]$MountedDrive,
        [Parameter(Mandatory=$true)] [string]$Username,
        [Parameter(Mandatory=$true)] [string]$RedirectedShare,
        [int]$HiveLoadRetries = 5,
        [int]$HiveLoadDelaySeconds = 2
    )
    Write-Log "Repairing registry entries for user $Username in mounted profile ($MountedDrive)"

    if ($TestMode) {
        Write-Log "TEST MODE: Would load and modify registry hive for $Username" -Level WARNING
        return @{ Updated = $false; Reason = 'TestMode' }
    }

    $ntUserDat = Join-Path (Join-Path $MountedDrive 'Profile') 'NTUSER.DAT'
    if (!(Test-Path $ntUserDat)) {
        $candidate = Get-ChildItem -Path (Join-Path $MountedDrive 'Users') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'NTUSER.DAT') } | Select-Object -First 1
        if ($candidate) { $ntUserDat = Join-Path $candidate.FullName 'NTUSER.DAT' }
    }
    if (!(Test-Path $ntUserDat)) {
        Write-Log "NTUSER.DAT not found for $Username; skipping registry repair" -Level WARNING
        return @{ Updated = $false; Reason = 'NoHive' }
    }

    $hiveName = 'TempHive_' + ([System.Guid]::NewGuid().ToString('N').Substring(0,8))
    $loaded = $false

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
    }
    function Invoke-RegUnloadWithRetry {
        param(
            [string]$HiveName,
            [int]$Attempts = 5,
            [int]$DelaySeconds = 2
        )
        for ($i=1; $i -le $Attempts; $i++) {
            $unloadResult = & reg.exe unload "HKU\$HiveName" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Unloaded hive $HiveName (attempt $i)" -Level INFO
                return $true
            }
            Write-Log "Hive unload attempt $i failed for $HiveName : $unloadResult" -Level WARNING
            [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Seconds $DelaySeconds
        }
        return $false
    }

    # Retry hive load
    $loadSucceeded = $false
    for ($l=1; $l -le $HiveLoadRetries -and -not $loadSucceeded; $l++) {
        $loadResult = & reg.exe load "HKU\$hiveName" "$ntUserDat" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $loadSucceeded = $true
            $loaded = $true
            Write-Log "Hive load succeeded for $Username (attempt $l)" -Level INFO
        } else {
            Write-Log "Hive load attempt $l failed for $Username : $loadResult" -Level WARNING
            if ($l -lt $HiveLoadRetries) { Start-Sleep -Seconds $HiveLoadDelaySeconds }
        }
    }

    if (-not $loadSucceeded) {
        Write-Log "Abandoning registry repair for $Username after $HiveLoadRetries failed hive load attempts" -Level ERROR
        return @{ Updated = $false; Error = 'HiveLoadFailed' }
    }

    try {
        $pathsToCheck = @(
            "HKU:$hiveName\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders",
            "HKU:$hiveName\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
        )

        $redirectRoot = (Join-Path $RedirectedShare $Username)
        $replacement = '%USERPROFILE%'
        $changes = 0

        foreach ($regPath in $pathsToCheck) {
            if (Test-Path $regPath) {
                try {
                    $key = Get-Item -LiteralPath $regPath
                    $valueNames = $key.GetValueNames()
                    foreach ($vn in $valueNames) {
                        $value = $key.GetValue($vn)
                        if ($value -and ($value -like "$redirectRoot*")) {
                            $newValue = $value -replace [regex]::Escape($redirectRoot), $replacement
                            if ($newValue -ne $value) {
                                Set-ItemProperty -LiteralPath $regPath -Name $vn -Value $newValue
                                Write-Log "Updated registry value $regPath::$vn" -Level SUCCESS
                                $changes++
                            }
                        }
                    }
                } finally {
                    if ($key -and $key.PSObject.Properties.Name -contains 'Handle') { try { $key.Close() } catch {} }
                }
            } else {
                Write-Log "Registry path not found (skipping): $regPath" -Level WARNING
            }
        }

        Write-Log "Registry repair completed for $Username (Changes: $changes)" -Level INFO
        return @{ Updated = $true; Changes = $changes }
    }
    catch {
        Write-Log "Registry repair error for $Username : $($_.Exception.Message)" -Level ERROR
        return @{ Updated = $false; Error = $_.Exception.Message }
    }
    finally {
        if ($loaded) {
            if (-not (Invoke-RegUnloadWithRetry -HiveName $hiveName)) {
                Write-Log "Final failure unloading hive $hiveName after retries" -Level ERROR
            }
        } else {
            Write-Log "Skipping hive unload for $Username because hive was never loaded" -Level INFO
        }
    }
}

function Start-UserProfileMigration {
    param(
        [Parameter(Mandatory=$true)] [PSCustomObject]$UserInfo,
        [Parameter(Mandatory=$true)] [string]$ExistingProfileAction
    )
    Write-Log "=== Starting migration for user: $($UserInfo.Username) ===" -Level INFO
    $driveLetter = $null
    $migrationResult = [ordered]@{
        Username = $UserInfo.Username
        ProfileCopied = $false
        ProfileCopySkippedReason = $null
        OverwriteAction = $ExistingProfileAction
        VHDXMounted = $false
        RedirectedFoldersCopied = 0
        RedirectedFoldersErrors = 0
        Success = $false
    }
    $phase='Init'
    try {
        $phase='CopyProfile'
        $copyOutcome = Copy-FSLogixProfile -UserInfo $UserInfo -ExistingProfileAction $ExistingProfileAction
        $destinationPath = $copyOutcome.Path
        $migrationResult.ProfileCopied = $copyOutcome.Copied
        $migrationResult.ProfileCopySkippedReason = $copyOutcome.SkippedReason
        $phase='MountVHD'
        $destinationVHDXPath = Join-Path $destinationPath (Split-Path $UserInfo.VHDXFile -Leaf)
        if (-not (Test-Path $destinationVHDXPath)) {
            if ($ExistingProfileAction -eq 'Maintain' -and -not $migrationResult.ProfileCopied) {
                $destinationVHDXPath = Get-ChildItem -Path $destinationPath -Filter 'Profile_*.vhd*' -File -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName }
            }
        }
        if (-not $destinationVHDXPath) { throw "Unable to locate destination VHD(X) for user $($UserInfo.Username)" }
        $driveLetter = Mount-FSLogixVHDX -VHDXPath $destinationVHDXPath
        $migrationResult.VHDXMounted = $true
        $phase='CopyRedirectedFolders'
        $folderResults = Copy-RedirectedFolders -Username $UserInfo.Username -MountedDrive $driveLetter
        $migrationResult.RedirectedFoldersCopied = $folderResults.Success
        $migrationResult.RedirectedFoldersErrors = $folderResults.Errors
        $phase='RepairRegistry'
        $regFix = Repair-UserRegistry -MountedDrive $driveLetter -Username $UserInfo.Username -RedirectedShare $RedirectedShare
        $phase='FinalizeUser'
        $migrationResult.Success = ($folderResults.Errors -eq 0)
        Write-Log "Migration completed for user: $($UserInfo.Username)" -Level SUCCESS
    } catch {
        Write-Log "Migration failed for user $($UserInfo.Username) during phase '$phase': $($_.Exception.Message)" -Level ERROR
        $migrationResult.Success = $false
    } finally {
        $phase='Dismount'
        if ($driveLetter -and $migrationResult.VHDXMounted) {
            try { Dismount-FSLogixVHDX -VHDXPath $destinationVHDXPath -DriveLetter $driveLetter } catch { Write-Log "Failed to dismount VHDX for user $($UserInfo.Username): $($_.Exception.Message)" -Level ERROR }
        }
    }
    Write-Log "=== Completed migration for user: $($UserInfo.Username) ===" -Level INFO
    return $migrationResult
}

# Main execution logic
try {
    Write-Log "=== FSLogix Profile Migration Script Started ===" -Level "INFO"
    Write-Log "Source (FSLogix) Share: $SourceShare" -Level "INFO"
    Write-Log "Destination (FSLogix) Share: $DestinationShare" -Level "INFO"
    Write-Log "Redirected Folders Share: $RedirectedShare" -Level "INFO"
    Write-Log "Log Path: $LogPath" -Level "INFO"
    Write-Log "Test Mode: $TestMode" -Level "INFO"
    # Azure Files hybrid detection:
    # 1. If switch provided -> treat as Azure (override)
    # 2. Else if UNC matches pattern -> ask for confirmation
    # 3. Else prompt user (Y/N) to treat as Azure (default N)

    # Determine if user specified switches (even if false) using PSBoundParameters
    $sourceAzureSpecified = $PSBoundParameters.ContainsKey('SourceAzure')
    $destAzureSpecified   = $PSBoundParameters.ContainsKey('DestinationAzure')
    # Derive explicit boolean values: if specified, use the switch value ($true or $false); else placeholder false (will trigger prompt logic later)
    $explicitSourceAzureValue = if ($sourceAzureSpecified) { [bool]$SourceAzure } else { $false }
    $explicitDestAzureValue   = if ($destAzureSpecified)   { [bool]$DestinationAzure } else { $false }
    $isSourceAzure = Invoke-AzureDecision -SharePath $SourceShare -Role 'Source' -ExplicitAzureValue $explicitSourceAzureValue -WasParameterSpecified $sourceAzureSpecified
    $isDestinationAzure = Invoke-AzureDecision -SharePath $DestinationShare -Role 'Destination' -ExplicitAzureValue $explicitDestAzureValue -WasParameterSpecified $destAzureSpecified
    Write-Log "Azure decision (Source): Specified=$sourceAzureSpecified Value=$isSourceAzure" -Level INFO
    Write-Log "Azure decision (Destination): Specified=$destAzureSpecified Value=$isDestinationAzure" -Level INFO

    if ($isSourceAzure) {
        Write-Log 'Source share treated as Azure Files.' -Level INFO
        if (-not $SourceStorageAccountName) { $SourceStorageAccountName = Get-AzureAccountNameFromUNC -UNC $SourceShare }
        if (-not $SourceStorageAccountName) { $SourceStorageAccountName = Read-Host 'Enter Source storage account name' }
        if (-not $SourceStorageAccountKey) { $SourceStorageAccountKey = Read-Host 'Enter Source storage account key' -AsSecureString }
        [void](Connect-AzureFileShare -UNCPath $SourceShare -StorageAccountName $SourceStorageAccountName -StorageAccountKey $SourceStorageAccountKey -TestOnly:$TestMode)
    } else {
        Write-Log 'Source share treated as standard SMB (not Azure Files).' -Level INFO
    }
    if ($isDestinationAzure) {
        Write-Log 'Destination share treated as Azure Files.' -Level INFO
        if (-not $DestinationStorageAccountName) { $DestinationStorageAccountName = Get-AzureAccountNameFromUNC -UNC $DestinationShare }
        if (-not $DestinationStorageAccountName) { $DestinationStorageAccountName = Read-Host 'Enter Destination storage account name' }
        if (-not $DestinationStorageAccountKey) { $DestinationStorageAccountKey = Read-Host 'Enter Destination storage account key' -AsSecureString }
        [void](Connect-AzureFileShare -UNCPath $DestinationShare -StorageAccountName $DestinationStorageAccountName -StorageAccountKey $DestinationStorageAccountKey -TestOnly:$TestMode)
    } else {
        Write-Log 'Destination share treated as standard SMB (not Azure Files).' -Level INFO
    }
    
    # Test prerequisites after potential Azure Files connections
    Test-Prerequisites
    
    # Get list of FSLogix users
    $users = Get-FSLogixUsers
    
    if ($users.Count -eq 0) {
        Write-Log "No FSLogix users found in source share" -Level "WARNING"
        $script:FinalExitCode = 0
        throw [System.Exception]::new('TerminateEarlyNoUsers')
    }

    # Apply selection logic (wrap in @( ) to force array so .Count works when a single object is returned)
    $targetUsers = Resolve-TargetUsers -AllDiscoveredUsers $users -AllUsers:$AllUsers -UserList $UserList -UserPrefix $UserPrefix
    if ($null -eq $targetUsers) { $targetUsers = @() } elseif ($targetUsers -isnot [System.Array]) { $targetUsers = @($targetUsers) }
    if (-not $targetUsers -or $targetUsers.Count -eq 0) {
        Write-Log 'No target users resolved after selection. Exiting.' -Level ERROR
        $script:FinalExitCode = 0
        throw [System.Exception]::new('TerminateEarlyNoTargets')
    }

    Write-Log "Users selected for processing ($($targetUsers.Count)): $($targetUsers.Username -join ', ')" -Level INFO
    
    # Initialize counters
    $totalUsers = $targetUsers.Count
    $successfulMigrations = 0
    $failedMigrations = 0
    $migrationResults = @()
    
    Write-Log "Starting migration for $totalUsers users..." -Level "INFO"
    
    # Process each user
    foreach ($user in $targetUsers) {
        $userResult = Start-UserProfileMigration -UserInfo $user -ExistingProfileAction $ExistingProfileAction
        $migrationResults += $userResult
        if ($userResult.Success) { $successfulMigrations++ } else { $failedMigrations++ }
        $completedUsers = $successfulMigrations + $failedMigrations
        $percentComplete = [math]::Round(($completedUsers / $totalUsers) * 100, 1)
        Write-Log "Progress: $completedUsers/$totalUsers users completed ($percentComplete%)" -Level INFO
    }

    # Final summary
    $endTime = Get-Date
    $duration = $endTime - $StartTime

    Write-Log "=== MIGRATION SUMMARY ===" -Level "INFO"
    Write-Log "Total Users (selected): $totalUsers" -Level "INFO"
    Write-Log "Successful Migrations: $successfulMigrations" -Level "SUCCESS"
    Write-Log "Failed Migrations: $failedMigrations" -Level $(if ($failedMigrations -gt 0) { "ERROR" } else { "INFO" })
    # Use composite formatting for TimeSpan to avoid invalid custom format exceptions
    Write-Log ("Total Duration: {0:hh\:mm\:ss}" -f $duration) -Level "INFO"
    Write-Log "Log File: $LogFile" -Level "INFO"

    # Detailed results
    if ($migrationResults | Where-Object { -not $_.Success }) {
        Write-Log "=== FAILED MIGRATIONS DETAILS ===" -Level "ERROR"
        foreach ($result in $migrationResults | Where-Object { -not $_.Success }) {
            Write-Log "Username: $($result.Username) - Profile Copied: $($result.ProfileCopied), VHDX Mounted: $($result.VHDXMounted), Folders Copied: $($result.RedirectedFoldersCopied), Folder Errors: $($result.RedirectedFoldersErrors)" -Level "ERROR"
        }
    }

    # Create summary report
    $summaryReport = @{
        StartTime = $StartTime
        EndTime = $endTime
        Duration = $duration
        TotalUsers = $totalUsers
        SuccessfulMigrations = $successfulMigrations
        FailedMigrations = $failedMigrations
        TestMode = $TestMode
        SourceShare = $SourceShare
        DestinationShare = $DestinationShare
        RedirectedShare = $RedirectedShare
        SelectedUsers = $targetUsers.Username
        ExistingProfileAction = $ExistingProfileAction
        Results = $migrationResults
    }
    $summaryPath = Join-Path $LogRunPath "Migration-Summary-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $summaryReport | ConvertTo-Json -Depth 10 | Out-File -FilePath $summaryPath -Encoding UTF8
    Write-Log "Summary report saved to: $summaryPath" -Level "INFO"

    Write-Log "=== FSLogix Profile Migration Script Completed ===" -Level "SUCCESS"

    $script:FinalExitCode = if ($failedMigrations -gt 0) { 1 } else { 0 }
}
catch {
    Write-Log "Critical error in migration script: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack trace: $($_.Exception.StackTrace)" -Level "ERROR"
    if ($script:FinalExitCode -eq 0 -and $_.Exception.Message -notin 'TerminateEarlyNoUsers','TerminateEarlyNoTargets') { $script:FinalExitCode = 2 }
}
finally {
    foreach ($share in $Global:AzureMountedShares) {
        try {
            Write-Log "Disconnecting Azure Files share: $share" -Level INFO
            $out = & cmd.exe /c "net use $share /delete /y" 2>&1
            if ($LASTEXITCODE -eq 0) { Write-Log "Disconnected $share" -Level SUCCESS } else { Write-Log "Failed to disconnect $share ($LASTEXITCODE): $out" -Level WARNING }
        } catch {
            Write-Log "Exception while disconnecting $share : $($_.Exception.Message)" -Level WARNING
        }
    }
    exit $script:FinalExitCode
}