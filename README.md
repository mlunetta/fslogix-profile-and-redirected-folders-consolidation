# FSLogix Profile & Redirected Folders Migration Script

A robust, idempotent PowerShell script to consolidate user data by migrating existing FSLogix profile containers and merging separately redirected user shell folders (Documents, Desktop, Downloads, Pictures, Videos, Music, Favorites) back into each user profile VHD/VHDX.

The script:
- Copies each user's FSLogix directory (preserving ACLs, ownership, SACL, timestamps) using `robocopy /MIR /COPYALL /DCOPY:DAT /SECFIX /TIMFIX`
- Mounts the destination `Profile_*.vhdx` (or `.vhd`) and deterministically assigns an available drive letter via DiskPart (with Mount-DiskImage fallback)
- Copies redirected folders from a separate share into the mounted profile
- Repairs per-user registry references inside `NTUSER.DAT` (Explorer Shell Folders & User Shell Folders) replacing legacy redirected UNC roots with `%USERPROFILE%`
- Generates per-user logs and a JSON summary report containing granular success / error state

> Designed for migration scenarios (e.g., server refresh, consolidation, or decommissioning classic redirected folders while keeping FSLogix).

---
## ✨ Key Features
- Safe, repeatable runs (idempotent logic & skip/overwrite modes)
- Supports selection of users: all, explicit list, or by username prefix(es)
- Test / dry-run mode (`-TestMode`) – validates access and selection without copying or mounting
- Detailed colored console + file logging and JSON summary artifact
- Robust registry hive load/unload with retry logic
- Graceful fallback when the expected profile path inside container differs (uses first non-default profile directory)
- Explicit drive letter allocation avoids ambiguous automatic mount behavior

---
## 🧱 Prerequisites
| Requirement | Notes |
|-------------|-------|
| Windows (Admin session) | Script must run elevated (`#Requires -RunAsAdministrator`) |
| PowerShell 5.1+ (or Core with required modules) | Uses built-in cmdlets + DISK APIs |
| Access to Source FSLogix share | UNC path readable (e.g. `\\old-server\fslogix$`) |
| Access to Destination FSLogix share | UNC path writable |
| Access to Redirected Folders share | Root path containing `Username\Documents`, etc. |
| DiskPart available | Used for controlled VHD drive letter assignment |
| Robocopy available | Standard on Windows Server / Enterprise editions |
| Sufficient free disk space | Destination share must accommodate copied containers |

Optional but recommended:
- Run during a maintenance window (avoid active user sessions writing to source containers)
- Antivirus exclusions for VHDX mount path to reduce interference

---
## 🗂 Folder Sources & Targets
- Source FSLogix Share (per-user directories containing `Profile_*.vhdx` or `.vhd`)
- Redirected Share (per-user root containing redirected Windows Known Folders)
- Destination FSLogix Share (mirrors user directories; containers copied first, then enriched with merged data)

Redirected folders processed (case-sensitive in script constant):
```
Documents, Videos, Pictures, Music, Desktop, Downloads, Favorites
```

---
## 🔐 Security & Integrity
- Uses `robocopy /COPYALL /SECFIX /TIMFIX` to preserve and repair ACLs & timestamps
- Does not alter ACLs beyond mirroring source state
- Registry updates only affect values whose data starts with the legacy redirected UNC root; replacement uses `%USERPROFILE%`
- No credentials are stored; relies on current security context

---
## 🚀 Usage
Run in an elevated PowerShell session on an administrative host with access to all involved shares.

### Parameters
| Parameter | Type | Mandatory | Description |
|-----------|------|-----------|-------------|
| `-SourceShare` | String | Yes | Source FSLogix root share (per-user folders) |
| `-DestinationShare` | String | Yes | Destination FSLogix root share |
| `-RedirectedShare` | String | Yes | Root of redirected folders (per-user subfolders) |
| `-LogPath` | String | Yes | Where logs and summary reports are written (auto timestamped subfolder) |
| `-TestMode` | Switch | No | Dry-run: no copy, no mount, no registry modification |
| `-AllUsers` | Switch | No | Process all discovered users |
| `-UserList` | String[] | No | Comma-separated or array of explicit usernames |
| `-UserPrefix` | String[] | No | One or more prefixes (supports comma-separated) |
| `-UserListExcelPath` | String | No | Path to an `.xlsx` file containing usernames (first worksheet, first column named "Username"). Auto-installs ImportExcel if missing. Overrides other selection switches. |
| `-ExistingProfileAction` | Overwrite/Maintain | No | Overwrite (default) or Maintain (skip copy if destination exists) |
| `-SourceAzure` | Switch | No | Treat SourceShare as Azure Files (or auto-detected by UNC pattern) |
| `-DestinationAzure` | Switch | No | Treat DestinationShare as Azure Files (or auto-detected by UNC pattern) |
| `-SourceStorageAccountName` | String | Conditional | Storage account name for source Azure Files (prompted if omitted) |
| `-SourceStorageAccountKey` | SecureString | Conditional | Account key (secure) for source Azure Files (prompted if omitted) |
| `-DestinationStorageAccountName` | String | Conditional | Storage account name for destination Azure Files (prompted if omitted) |
| `-DestinationStorageAccountKey` | SecureString | Conditional | Account key (secure) for destination Azure Files (prompted if omitted) |

### Examples
Process ALL users:
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix$" -DestinationShare "\\new-server\fslogix$" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\FSLogix-Migration-Logs" -AllUsers
```
Explicit list:
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix$" -DestinationShare "\\new-server\fslogix$" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\FSLogix-Migration-Logs" -UserList "alice,bob,carol"
```
Prefix filter (e.g., engineering & test accounts):
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix$" -DestinationShare "\\new-server\fslogix$" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\FSLogix-Migration-Logs" -UserPrefix "eng,test"
```
Maintain existing (skip if destination user folder already present):
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix$" -DestinationShare "\\new-server\fslogix$" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\FSLogix-Migration-Logs" -UserList "alice" -ExistingProfileAction Maintain
```
Dry-run (no writes):
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix$" -DestinationShare "\\new-server\fslogix$" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\FSLogix-Migration-Logs" -AllUsers -TestMode
```
Interactive user selection (omit targeting switches):
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix$" -DestinationShare "\\new-server\fslogix$" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\FSLogix-Migration-Logs"
```

Excel-based user list:
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix$" -DestinationShare "\\new-server\fslogix$" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\FSLogix-Migration-Logs" -UserListExcelPath "C:\Temp\UsersToMigrate.xlsx"
```

Azure Files (explicit flags + passed credentials):
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\myacctsrc.file.core.windows.net\profiles" -DestinationShare "\\myaccdst.file.core.windows.net\profiles" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\Logs" -AllUsers -SourceAzure -DestinationAzure -SourceStorageAccountName "myacctsrc" -DestinationStorageAccountName "myaccdst" -SourceStorageAccountKey (Read-Host 'Source Key' -AsSecureString) -DestinationStorageAccountKey (Read-Host 'Dest Key' -AsSecureString)
```

Azure Files (auto-detect pattern, interactive key prompt):
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\myacctsrc.file.core.windows.net\profiles" -DestinationShare "\\myaccdst.file.core.windows.net\profiles" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\Logs" -AllUsers
```
The script will detect the `*.file.core.windows.net` UNC and prompt for missing storage account name/key (if not derivable from UNC) and mount using `net use` with `Azure\<account>`.

### Azure Files Tri-State Behavior
`-SourceAzure` and `-DestinationAzure` behave as tri-state controls:
| Case | Action | Prompt? | Result |
|------|--------|---------|--------|
| Explicit Azure | Include switch (e.g. `-SourceAzure`) | No | Treated as Azure Files |
| Explicit Non-Azure | Include switch with false (e.g. `-SourceAzure:$false`) | No | Treated as standard SMB |
| Unspecified | Omit switch | Yes* | Prompt (pattern-based first) |

*If the UNC matches the Azure Files pattern (`\\account.file.core.windows.net\share`), the prompt clarifies detection; otherwise a generic Y/N question is used.

Force non-Azure (suppresses prompt despite pattern):
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\myacctsrc.file.core.windows.net\profiles" -DestinationShare "\\new-server\fslogix$" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\Logs" -AllUsers -SourceAzure:$false -DestinationAzure:$false
```

Hybrid (Source Azure, Destination standard SMB):
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\myacctsrc.file.core.windows.net\profiles" -DestinationShare "\\new-server\fslogix$" -DestinationAzure:$false -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\Logs" -AllUsers -SourceAzure -SourceStorageAccountName "myacctsrc" -SourceStorageAccountKey (Read-Host 'Source Key' -AsSecureString)
```

Hybrid (Destination Azure only):
```powershell
./FSLogix-Profile-Migration.ps1 -SourceShare "\\old-server\fslogix$" -SourceAzure:$false -DestinationShare "\\myaccdst.file.core.windows.net\profiles" -RedirectedShare "\\filesvr\Redirected$" -LogPath "C:\Temp\Logs" -UserList "alice,bob" -DestinationAzure -DestinationStorageAccountName "myaccdst" -DestinationStorageAccountKey (Read-Host 'Dest Key' -AsSecureString)
```

> Authentication: The script connects to Azure Files using `net use` with `/user:localhost\<StorageAccountName>` and the storage account key.

---
## 🧪 Test Mode Behavior
When `-TestMode` is present:
- No directories are created
- No robocopy operations execute (intent logged)
- VHD/VHDX not actually mounted (fake drive letter returned)
- Registry not modified
- Flow & selection logic still validated
- Azure Files shares are NOT mounted; connection steps are logged only

---
## 📄 Logging & Reports
Structure inside `-LogPath`:
```
<LogPath>/YYYY-MM-dd_HH-mm/
  FSLogix-Migration-<timestamp>.log          # Master session log
  robocopy-profile-<username>.log            # Profile copy per user
  robocopy-<Folder>-<username>.log           # Redirected folder copy logs
  Migration-Summary-<timestamp>.json         # Machine-readable summary
```
Exit codes:
| Code | Meaning |
|------|---------|
| 0 | All selected migrations succeeded |
| 1 | One or more user migrations failed |
| 2 | Script-level critical error |

---
## 🔄 Idempotency & Reruns
- Safe to rerun: existing user folders can be skipped with `-ExistingProfileAction Maintain`
- Robocopy `/MIR` ensures destination mirrors source (be cautious—deleted source data will be removed in destination on rerun)
- Registry repair only updates values pointing to the old redirected root

---
## 🛠 Troubleshooting
| Scenario | Guidance |
|----------|----------|
| Exit code 2 | Check top of master log for prerequisite failure or unhandled exception |
| VHD mount failures | Confirm disk is not locked; ensure no antivirus lock; review mount method in log (DiskPart vs Mount-DiskImage) |
| Registry hive load fails repeatedly | File lock or corruption; verify `NTUSER.DAT` integrity and no open handles |
| Missing redirected folders | Ensure correct share root layout: `\\redirected\share\<username>\Documents` etc. |
| Permission denied on copy | Validate current context has Full Control or adequate read/write/ownership rights |
| Timeouts or slowness | Reduce `/MT` threads or run off-hours; network latency or contention may be a factor |
| Azure Files connect fails | Verify storage account key & that port 445 outbound is allowed; ensure UNC format `\\account.file.core.windows.net\share` |
| Azure share disconnect warnings | Usually benign if share already disconnected; script attempts cleanup in `finally` |

---
## 🤝 Contributing
1. Fork the repository
2. Create a feature branch (`feat/parallel-migration`)
3. Commit with conventional messages (`feat: add parallel processing`)
4. Open a Pull Request with details & sample logs

---
## 🧯 Support & Disclaimer
This script is provided under the MIT License (see `LICENSE`).
Validate thoroughly in a non-production environment before running at scale.

---
## 📜 License
MIT License – see `LICENSE` file.
