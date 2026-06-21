<#
.SYNOPSIS
    Purview eDiscovery Search & Export Tool (App-only authentication)
    
.DESCRIPTION
    Interactive PowerShell application for managing Microsoft Purview eDiscovery searches and exports.
    Connects using app-only (client credentials) authentication via Microsoft Graph API.
    
    Features:
    - Search eDiscovery cases with item counts and sizes
    - Export and download case files
    - Real-time statistics and case information
    
    Authentication: Requires TenantId, ClientId, and ClientSecret for service principal.
    Config file loading: Reads Invoke-eDiscoverySearchExport-AppOnly.config.json if present (optional).

.NOTES
    Developer: Dr Muataz Awad
    
.USAGE
    .\Invoke-eDiscoverySearchExport-AppOnly.ps1
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = ".\Invoke-eDiscoverySearchExport-AppOnly.config.json",
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret
)

# Set execution policy for current process to allow script execution
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# ============================================================================
# MODULE IMPORTS
# ============================================================================
# Import Microsoft Graph Authentication module for connecting to Microsoft Graph API
try {
    Import-Module Microsoft.Graph.Authentication -Force -ErrorAction Stop
}
catch {
    Write-Error "Failed to load Microsoft.Graph.Authentication. Run: Install-Module Microsoft.Graph -Scope CurrentUser -Force"
    return
}

# ============================================================================
# FUNCTION: Get-ExportFilesFromCase
# ============================================================================
# Retrieves all downloadable export files for a case from Microsoft Graph API.
# Filters operations by type (contentExport, exportResult, exportReport) and
# extracts file metadata including download URLs, file names, and sizes.
#
# Parameters:
#   -CaseId (string, required): The eDiscovery case identifier
#   -SearchId (string, optional): Filter files for a specific search ID
#
# Returns: Array of custom objects with properties:
#   ExportName, Action, Status, Created, Completed, CreatedBy, SearchName,
#   FileName, SizeBytes, SizeMB, DownloadUrl, OperationId
function Get-ExportFilesFromCase {
    param(
        [Parameter(Mandatory)][string]$CaseId,
        [string]$SearchId
    )

    # Fetch all operations for the case from Graph API
    $operations = @(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/operations" -OutputType PSObject | Select-Object -ExpandProperty value)
    
    # Define which operation types are export-related
    $exportActions = @('contentExport', 'exportResult', 'exportReport')
    $report = @()

    # Iterate through all operations and extract export files
    foreach ($operation in $operations) {
        # Skip non-export operations
        if ($operation.action -notin $exportActions) { continue }
        # If SearchId specified, skip operations for other searches
        if ($SearchId -and $operation.search.id -and $operation.search.id -ne $SearchId) { continue }

        # Extract file metadata from the operation's export files
        foreach ($file in @($operation.exportFileMetadata)) {
            if (-not $file) { continue }
            
            # Create custom object with file and operation metadata
            $report += [PSCustomObject]@{
                ExportName   = $operation.outputName
                Action       = $operation.action
                Status       = $operation.status
                Created      = $operation.createdDateTime
                Completed    = $operation.completedDateTime
                CreatedBy    = $operation.createdBy.user.displayName
                SearchName   = $operation.search.displayName
                FileName     = $file.fileName
                SizeBytes    = [int64]$file.size
                SizeMB       = [math]::Round(([double]$file.size / 1MB), 2)
                DownloadUrl  = $file.downloadUrl
                OperationId  = $operation.id
            }
        }
    }

    return $report
}

# ============================================================================
# FUNCTION: Save-ExportFilesFromCase
# ============================================================================
# Downloads all export files for a case to local disk.
# Automatically handles filename collisions by appending OperationId.
#
# Parameters:
#   -CaseId (string, required): The eDiscovery case identifier
#   -SearchId (string, optional): Filter downloads for a specific search ID
#   -OutputDirectory (string, optional): Destination folder (default: current working directory)
#
# Returns: Array of custom objects with download details (ExportName, FileName, SavedTo, SizeMB)
function Save-ExportFilesFromCase {
    param(
        [Parameter(Mandatory)][string]$CaseId,
        [string]$SearchId,
        [string]$OutputDirectory = (Get-Location).Path
    )

    # Create output directory if it doesn't exist
    if (-not (Test-Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    }

    # Retrieve all downloadable export files
    $files = @(Get-ExportFilesFromCase -CaseId $CaseId -SearchId $SearchId)
    if ($files.Count -eq 0) {
        Write-Host "[INFO] No export files found for this case/search." -ForegroundColor Yellow
        return @()
    }

    # Download each file to the output directory
    $downloaded = @()
    foreach ($file in $files) {
        # Use provided filename or generate fallback name
        $safeName = $file.FileName
        if ([string]::IsNullOrWhiteSpace($safeName)) {
            $safeName = "export-$($file.OperationId).bin"
        }

        $targetPath = Join-Path $OutputDirectory $safeName
        
        # Handle filename collisions by appending OperationId
        if (Test-Path $targetPath) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
            $ext = [System.IO.Path]::GetExtension($safeName)
            $targetPath = Join-Path $OutputDirectory ("{0}-{1}{2}" -f $base, $file.OperationId, $ext)
        }

        # Download the file
        Write-Host "[*] Downloading $($file.FileName) ..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $file.DownloadUrl -OutFile $targetPath
        Write-Host "[OK] Saved: $targetPath" -ForegroundColor Green
        
        # Track successful downloads
        $downloaded += [PSCustomObject]@{
            ExportName = $file.ExportName
            FileName   = $file.FileName
            SavedTo    = $targetPath
            SizeMB     = $file.SizeMB
        }
    }

    return $downloaded
}

# ============================================================================
# FUNCTION: Get-CaseExportOperations
# ============================================================================
# Retrieves all export operations for a case (contentExport, exportResult, exportReport).
# Export operations represent export jobs and their metadata, not necessarily
# downloadable files (some operations may not have file packages exposed).
#
# Parameters:
#   -CaseId (string, required): The eDiscovery case identifier
#
# Returns: Array of export operation objects from Microsoft Graph API
function Get-CaseExportOperations {
    param([Parameter(Mandatory)][string]$CaseId)

    # Fetch all operations and filter for export-related types
    $ops = @(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/operations" -OutputType PSObject | Select-Object -ExpandProperty value)
    $exportActions = @('contentExport', 'exportResult', 'exportReport')
    return @($ops | Where-Object { $_.action -in $exportActions })
}

# ============================================================================
# FUNCTION: Get-ExportDisplayName
# ============================================================================
# Generates a user-friendly display name for an export operation.
# Falls back to a readable pattern if the operation's outputName is blank.
# This handles cases where Microsoft Graph doesn't populate the name field.
#
# Parameters:
#   -ExportOperation (object, required): Export operation object from Graph API
#
# Returns: String display name for the export operation
function Get-ExportDisplayName {
    param([Parameter(Mandatory)]$ExportOperation)

    # Return provided name if available
    if (-not [string]::IsNullOrWhiteSpace($ExportOperation.outputName)) {
        return $ExportOperation.outputName
    }

    # Build fallback name from operation details
    $searchName = $ExportOperation.search.displayName
    if ([string]::IsNullOrWhiteSpace($searchName)) {
        $searchName = 'Unnamed search'
    }

    $actionName = $ExportOperation.action
    if ([string]::IsNullOrWhiteSpace($actionName)) {
        $actionName = 'export'
    }

    # Include timestamp if available: "contentExport for Demo Search (6/20/2026 12:47:29 PM)"
    $created = $ExportOperation.createdDateTime
    if ($created) {
        return ("{0} for {1} ({2})" -f $actionName, $searchName, $created)
    }

    return ("{0} for {1}" -f $actionName, $searchName)
}

# ============================================================================
# FUNCTION: Get-SearchSummaryRows
# ============================================================================
# Retrieves search statistics for all searches in a case.
# Fetches item counts and sizes from the latest estimation statistics operation.
#
# Parameters:
#   -CaseId (string, required): The eDiscovery case identifier
#
# Returns: Array of custom objects with search statistics (Name, Status, ItemCount, SizeMB, LastUpdate)
function Get-SearchSummaryRows {
    param([Parameter(Mandatory)][string]$CaseId)

    # Get all searches in the case
    $searches = @(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/searches" -OutputType PSObject | Select-Object -ExpandProperty value)
    $rows = @()
    
    foreach ($search in $searches) {
        # Fetch latest statistics for this search
        $statsUri = "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/searches/$($search.id)/lastEstimateStatisticsOperation"
        $itemCount = 0
        $sizeBytes = 0
        try {
            $stats = Invoke-MgGraphRequest -Method GET -Uri $statsUri -OutputType PSObject -ErrorAction SilentlyContinue
            if ($stats.indexedItemCount) { $itemCount = $stats.indexedItemCount }
            if ($stats.indexedItemsSize) { $sizeBytes = $stats.indexedItemsSize }
        } catch {}

        # Create summary row for this search
        $rows += [PSCustomObject]@{
            Name       = $search.displayName
            Status     = $search.estimationStatus
            ItemCount  = $itemCount
            SizeMB     = [math]::Round($sizeBytes / 1MB, 2)
            LastUpdate = $search.lastModifiedDateTime
        }
    }

    return $rows
}

# ============================================================================
# FUNCTION: Get-HoldPolicies
# ============================================================================
# Retrieves hold policies for a case.
# Tries legalHolds endpoint first, falls back to custodians endpoint if unavailable.
# This handles API variations across different Graph versions.
#
# Parameters:
#   -CaseId (string, required): The eDiscovery case identifier
#
# Returns: Array of hold policy or custodian objects
function Get-HoldPolicies {
    param([Parameter(Mandatory)][string]$CaseId)

    # Try primary endpoint for legal holds
    try {
        return @(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/legalHolds" -OutputType PSObject -ErrorAction Stop | Select-Object -ExpandProperty value)
    }
    catch {
        # Fallback to custodians endpoint
        try {
            return @(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases/$CaseId/custodians" -OutputType PSObject -ErrorAction Stop | Select-Object -ExpandProperty value)
        }
        catch {
            # Return empty array if both fail
            return @()
        }
    }
}

# ============================================================================
# FUNCTION: Show-PanelTitle
# ============================================================================
# Displays a formatted bordered panel header in the console.
# Used throughout the UI to clearly delineate menu sections.
#
# Parameters:
#   -Title (string, required): Main title text
#   -Subtitle (string, optional): Secondary text displayed in gray
#
# Output: Formatted header to console (cyan border, optional gray subtitle)
function Show-PanelTitle {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host $Subtitle -ForegroundColor DarkGray
    }
    Write-Host "========================================" -ForegroundColor Cyan
}

# ============================================================================
# FUNCTION: Show-CaseList
# ============================================================================
# Displays the main case picker menu showing all available eDiscovery cases.
# Lists cases with their status and creation date.
#
# Parameters:
#   -Cases (object[], required): Array of case objects from Microsoft Graph API
#
# Output: Formatted numbered case list with option to exit
function Show-CaseList {
    param([Parameter(Mandatory)][object[]]$Cases)

    Show-PanelTitle -Title "Purview eDiscovery Case Picker" -Subtitle "Choose a case to open its workspace"
    
    # Display numbered list of all cases
    for ($i = 0; $i -lt $Cases.Count; $i++) {
        $n = $i + 1
        Write-Host ("[{0}] {1}" -f $n, $Cases[$i].displayName)
        Write-Host ("    Status: {0} | Created: {1}" -f $Cases[$i].status, $Cases[$i].createdDateTime) -ForegroundColor DarkGray
    }
    Write-Host "[X] Exit" -ForegroundColor Yellow
}

# ============================================================================
# FUNCTION: Get-CaseDashboard
# ============================================================================
# Aggregates case-level statistics for display on the workspace dashboard.
# Sums total items and size across all searches and finds latest export timestamp.
#
# Parameters:
#   -SearchRows (object[], required): Array of search statistics objects
#   -Exports (object[], required): Array of export operation objects
#
# Returns: Custom object with TotalItems, TotalSizeMB, and LatestExport timestamp
function Get-CaseDashboard {
    param(
        [Parameter(Mandatory)][object[]]$SearchRows,
        [Parameter(Mandatory)][object[]]$Exports
    )

    # Aggregate total items across all searches
    $totalItems = @($SearchRows | Measure-Object -Property ItemCount -Sum)[0].Sum
    if (-not $totalItems) { $totalItems = 0 }

    # Aggregate total size across all searches
    $totalSizeMb = @($SearchRows | Measure-Object -Property SizeMB -Sum)[0].Sum
    if (-not $totalSizeMb) { $totalSizeMb = 0 }

    # Find the most recent export timestamp
    $latestExport = $null
    if ($Exports.Count -gt 0) {
        $latestExport = ($Exports | Sort-Object createdDateTime -Descending | Select-Object -First 1).createdDateTime
    }

    return [PSCustomObject]@{
        TotalItems   = [int64]$totalItems
        TotalSizeMB  = [math]::Round([double]$totalSizeMb, 2)
        LatestExport = $latestExport
    }
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
# Load optional app auth config file (Invoke-eDiscoverySearchExport-AppOnly.config.json)
# Parameters from file are used if not provided via command line
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $resolvedConfigPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ConfigPath)
    if (Test-Path $resolvedConfigPath) {
        try {
            $cfg = Get-Content -Path $resolvedConfigPath -Raw | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace($TenantId) -and $cfg.TenantId) { $TenantId = [string]$cfg.TenantId }
            if ([string]::IsNullOrWhiteSpace($ClientId) -and $cfg.ClientId) { $ClientId = [string]$cfg.ClientId }
            if ([string]::IsNullOrWhiteSpace($ClientSecret) -and $cfg.ClientSecret) { $ClientSecret = [string]$cfg.ClientSecret }
            $loadedConfigPath = $resolvedConfigPath
        }
        catch {
            Write-Warning "Failed to parse config file '$resolvedConfigPath'. Continuing with prompts/parameters."
        }
    }
}

# ============================================================================
# AUTHENTICATION
# ============================================================================
# Prompt for missing credentials and establish app-only connection to Microsoft Graph
if ([string]::IsNullOrWhiteSpace($TenantId)) { $TenantId = Read-Host "Enter Tenant ID" }
if ([string]::IsNullOrWhiteSpace($ClientId)) { $ClientId = Read-Host "Enter Client ID" }
if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
    $secureSecret = Read-Host -Prompt "Enter Client Secret" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
    try {
        $ClientSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

Show-PanelTitle -Title "Purview eDiscovery Search & Export" -Subtitle "App-only workspace session"
if ($loadedConfigPath) {
    Write-Host "[OK] App profile loaded" -ForegroundColor Green
    Write-Host "     Source: $loadedConfigPath" -ForegroundColor DarkGray
}
Write-Host "[*] Opening secure app-only connection..." -ForegroundColor Cyan
try {
    $secretSecure = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new($ClientId, $secretSecure)
    Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -NoWelcome -ErrorAction Stop
    Write-Host "[OK] App-only connection established" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect app-only: $_"
    return
}

# ============================================================================
# MAIN MENU LOOP: CASE PICKER
# ============================================================================
# Fetch all cases from Microsoft Graph API
Write-Host "[*] Discovering available eDiscovery case workspaces..." -ForegroundColor Cyan
$cases = @(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases" -OutputType PSObject | Select-Object -ExpandProperty value)
Write-Host "[OK] Ready: found $($cases.Count) case workspace(s)" -ForegroundColor Green

if ($cases.Count -eq 0) {
    Write-Warning "No eDiscovery cases found."
    return
}

# Main loop: show case picker until user exits
$exitApp = $false
while (-not $exitApp) {
    Show-CaseList -Cases $cases
    $pick = Read-Host "Open case number"

    if ($pick -match '^(x|exit)$') {
        Write-Host "Exiting..." -ForegroundColor Green
        break
    }

    $idx = 0
    if (-not ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $cases.Count)) {
        Write-Warning "Invalid selection. Choose a listed case number or X to exit."
        continue
    }

    $selected = $cases[$idx - 1]
    $caseId = $selected.id
    $backToCases = $false
    Write-Host "[*] Opening case workspace for $($selected.displayName)..." -ForegroundColor Cyan

    # ====================================================================
    # CASE WORKSPACE MENU LOOP
    # ====================================================================
    # Inner loop: show case workspace options (Searches, Holds, Exports)
    while (-not $backToCases -and -not $exitApp) {
        # Fetch current case data from Graph API
        Write-Host "[*] Loading searches, holds, and exports..." -ForegroundColor DarkCyan
        $searchRows = @(Get-SearchSummaryRows -CaseId $caseId)
        $holds = @(Get-HoldPolicies -CaseId $caseId)
        $exports = @(Get-CaseExportOperations -CaseId $caseId)
        $dashboard = Get-CaseDashboard -SearchRows $searchRows -Exports $exports
        
        # Calculate health status hints
        $searchHint = if ($searchRows.Count -gt 0) { "Searches ready" } else { "No searches" }
        $holdHint = if ($holds.Count -gt 0) { "Holds present" } else { "No holds" }
        $exportHint = if ($exports.Count -gt 0) { "Exports available" } else { "No exports yet" }

        # Display workspace dashboard with statistics and menu options
        Show-PanelTitle -Title $selected.displayName -Subtitle ("Searches: {0} | Holds: {1} | Exports: {2}" -f $searchRows.Count, $holds.Count, $exports.Count)
        Write-Host ("Items: {0} | Size: {1} MB | Latest Export: {2}" -f $dashboard.TotalItems, $dashboard.TotalSizeMB, $(if ($dashboard.LatestExport) { $dashboard.LatestExport } else { 'None' })) -ForegroundColor DarkGray
        Write-Host ("{0} | {1} | {2}" -f $searchHint, $holdHint, $exportHint) -ForegroundColor DarkGray
        Write-Host "[1] Search Explorer      View all searches and estimate stats"
        Write-Host "[2] Hold Center          Review hold policies or custodians"
        Write-Host "[3] Export Operations    Review export jobs and downloadable files"
        Write-Host "[B] Back to case list"
        Write-Host "[X] Exit"
        Write-Host ""

        $choice = Read-Host "Choose an action"

        # Parse user menu selection
        switch -Regex ($choice) {
            # ================================================================
            # OPTION 1: SEARCH EXPLORER
            # ================================================================
            '^1$' {
                Show-PanelTitle -Title "Search Explorer" -Subtitle $selected.displayName
                if ($searchRows.Count -eq 0) {
                    Write-Host "No searches found." -ForegroundColor Yellow
                }
                else {
                    # Display all searches with statistics in table format
                    $searchRows | Format-Table -AutoSize
                }
                Read-Host "Press Enter to return to the workspace menu" | Out-Null
            }

            # ================================================================
            # OPTION 2: HOLD CENTER
            # ================================================================
            '^2$' {
                Show-PanelTitle -Title "Hold Center" -Subtitle $selected.displayName
                if ($holds.Count -eq 0) {
                    Write-Host "No hold policies found for this case." -ForegroundColor Yellow
                }
                else {
                    # Display holds/custodians with key metadata
                    $holds | Select-Object displayName, status, createdDateTime | Format-Table -AutoSize
                }
                Read-Host "Press Enter to return to the workspace menu" | Out-Null
            }

            # ================================================================
            # OPTION 3: EXPORT OPERATIONS
            # ================================================================
            '^3$' {
                if ($exports.Count -eq 0) {
                    Write-Host "No exports found for this case." -ForegroundColor Yellow
                    Read-Host "Press Enter to return to the workspace menu" | Out-Null
                    continue
                }

                # Export operations submenu
                $leaveExports = $false
                while (-not $leaveExports) {
                    # Show list of export operations
                    Show-PanelTitle -Title "Export Operations" -Subtitle $selected.displayName
                    for ($i = 0; $i -lt $exports.Count; $i++) {
                        $n = $i + 1
                        $exportLabel = Get-ExportDisplayName -ExportOperation $exports[$i]
                        Write-Host ("[{0}] {1}" -f $n, $exportLabel)
                        Write-Host ("    Status: {0} | Created: {1}" -f $exports[$i].status, $exports[$i].createdDateTime) -ForegroundColor DarkGray
                    }
                    Write-Host "[B] Back to workspace menu" -ForegroundColor Yellow
                    Write-Host ""

                    $exportPick = Read-Host "Open export number"
                    if ($exportPick -match '^(b|back)$') {
                        $leaveExports = $true
                        continue
                    }

                    # Validate export selection
                    $exportIdx = 0
                    if (-not ([int]::TryParse($exportPick, [ref]$exportIdx) -and $exportIdx -ge 1 -and $exportIdx -le $exports.Count)) {
                        Write-Host "Invalid selection." -ForegroundColor Yellow
                        continue
                    }

                    # Fetch downloadable files for selected export operation
                    $selectedExport = $exports[$exportIdx - 1]
                    Write-Host "[*] Loading export files for $($selectedExport.outputName)..." -ForegroundColor DarkCyan

                    # Get downloadable files for this export operation
                    # Filter by OperationId and exclude entries with null/empty download URLs
                    $files = @(Get-ExportFilesFromCase -CaseId $caseId | Where-Object {
                        $_.OperationId -eq $selectedExport.id -and -not [string]::IsNullOrWhiteSpace($_.DownloadUrl)
                    })

                    # ============================================================
                    # EXPORT FILES SUBMENU
                    # ============================================================
                    Show-PanelTitle -Title "Export Files" -Subtitle (Get-ExportDisplayName -ExportOperation $selectedExport)
                    
                    if ($files.Count -eq 0) {
                        # Export operation exists but no downloadable files
                        Write-Host "This export operation exists, but Graph returned no downloadable file metadata." -ForegroundColor Yellow
                        Write-Host "This usually means the operation is report-only, placeholder metadata, expired content, or no file package is exposed by the API." -ForegroundColor DarkGray
                        Read-Host "Press Enter to return to Export Operations" | Out-Null
                        continue
                    }

                    # List all available files from this export
                    for ($f = 0; $f -lt $files.Count; $f++) {
                        $fileNo = $f + 1
                        $sizeMb = [math]::Round(([double]$files[$f].SizeBytes / 1MB), 2)
                        Write-Host ("[{0}] {1}" -f $fileNo, $files[$f].FileName)
                        Write-Host ("    Search: {0} | Export: {1} | Size: {2} MB" -f $files[$f].SearchName, $files[$f].ExportName, $sizeMb) -ForegroundColor DarkGray
                    }
                    Write-Host "[B] Back to Export Operations" -ForegroundColor Yellow
                    Write-Host ""

                    $downloadPick = Read-Host "Download which file"
                    if ($downloadPick -match '^(b|back)$') {
                        continue
                    }

                    # Validate file selection
                    $fileIdx = 0
                    if (-not ([int]::TryParse($downloadPick, [ref]$fileIdx) -and $fileIdx -ge 1 -and $fileIdx -le $files.Count)) {
                        Write-Host "Invalid selection." -ForegroundColor Yellow
                        continue
                    }

                    # Download selected file
                    $file = $files[$fileIdx - 1]
                    $outputDir = Read-Host "Output folder (blank = current folder)"
                    if ([string]::IsNullOrWhiteSpace($outputDir)) { $outputDir = (Get-Location).Path }
                    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }

                    $targetPath = Join-Path $outputDir $file.FileName
                    Write-Host "[*] Downloading $($file.FileName)..." -ForegroundColor Cyan
                    Invoke-WebRequest -Uri $file.DownloadUrl -OutFile $targetPath
                    Write-Host "[OK] Saved: $targetPath" -ForegroundColor Green
                    Read-Host "Press Enter to continue in Export Operations" | Out-Null
                }
            }

            # Back to case list
            '^(b|back)$' {
                $backToCases = $true
            }

            # Exit application
            '^(x|exit)$' {
                Write-Host "Exiting..." -ForegroundColor Green
                $exitApp = $true
            }

            # Invalid selection
            default {
                Write-Host "Invalid option. Choose 1-3, B, or X." -ForegroundColor Yellow
            }
        }
    }
}
