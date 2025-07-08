# Axis Camera Station Monitoring Script
# Firebird database monitoring for Axis Camera Station
# Export metrics in Prometheus format for wmi_exporter

param(
    [string]$SourceDir = "C:\ProgramData\Axis Communications\AXIS Camera Station Server",
    [string]$TempDir = "C:\temp\axis_monitoring",
    [string]$ExportDir = "C:\windows_exporter",
    [string]$FirebirdPath = "C:\Program Files\Firebird\Firebird_3_0\isql.exe"
)

# Create temp directory if not exists
if (!(Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

# Create export directory if not exists
if (!(Test-Path $ExportDir)) {
    New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
}

# Log file for detailed logging - create in the same directory as the script (disabled)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# $LogFile = "$ScriptDir\axis_monitoring.log"

# Function for logging (disabled)
function Write-Log {
    param([string]$Message)
    # Logging disabled
}

# Function for debug logging (disabled)
function Write-DebugLog {
    param([string]$Message)
    # Debug logging disabled
}

# Create new log file on each run (disabled)
# Write-Log "=== MONITORING SESSION START ==="
# Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
# Write-Log "Current Directory: $(Get-Location)"
# Write-Log "Script Parameters:"
# Write-Log "  SourceDir: $SourceDir"
# Write-Log "  TempDir: $TempDir"
# Write-Log "  ExportDir: $ExportDir"
# Write-Log "  FirebirdPath: $FirebirdPath"

# Function for cleaning temp files
function Cleanup-TempFiles {
    # Write-Log "Cleaning temp files..."
    if (Test-Path "$TempDir\ACS.FDB") {
        # Write-DebugLog "Removing temp file: $TempDir\ACS.FDB"
        Remove-Item "$TempDir\ACS.FDB" -Force
        # Write-DebugLog "ACS.FDB file removed"
    } else {
        # Write-DebugLog "Temp ACS.FDB file not found"
    }
    if (Test-Path "$TempDir\ACS_RECORDINGS.FDB") {
        # Write-DebugLog "Removing temp file: $TempDir\ACS_RECORDINGS.FDB"
        Remove-Item "$TempDir\ACS_RECORDINGS.FDB" -Force
        # Write-DebugLog "ACS_RECORDINGS.FDB file removed"
    } else {
        # Write-DebugLog "Temp ACS_RECORDINGS.FDB file not found"
    }
}

# Function for executing SQL queries
function Invoke-FirebirdQuery {
    param(
        [string]$Database,
        [string]$Query,
        [string]$Username = "SYSDBA",
        [string]$Password = "masterkey"
    )
    # Write-DebugLog "Executing SQL query to database: $Database"
    # Write-DebugLog "User: $Username"
    # Write-DebugLog "isql path: $FirebirdPath"
    # Write-DebugLog "SQL query: $Query"
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        # Write-DebugLog "Created temp SQL file: $tempFile"
        $Query | Out-File -FilePath $tempFile -Encoding ASCII
        # Write-DebugLog "SQL query written to file"
        # Write-DebugLog "Starting isql command (direct path)..."
        $absolutePath = [System.IO.Path]::GetFullPath($Database)
        $result = & $FirebirdPath -u $Username -p $Password -i $tempFile $absolutePath 2>&1
        # Write-DebugLog "isql command completed"
        Remove-Item $tempFile -Force
        # Write-DebugLog "Temp SQL file removed"
        return $result
    }
    catch {
        # Write-Log "SQL query execution error: $($_.Exception.Message)"
        # Write-DebugLog "Error details: $($_.Exception.ToString())"
        return $null
    }
}

# Function for getting camera name by ID
function Get-CameraName {
    param([int]$CameraId)
    
    # Write-DebugLog "Getting camera name for ID: $CameraId"
    
    $query = @"
SELECT NAME FROM CAMERA WHERE ID = $CameraId;
"@
    
    $result = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $query
    
    if ($result -and $result.Count -gt 0) {
        # Write-DebugLog "Got result for camera $CameraId, lines: $($result.Count)"
        # Extract camera name from result
        foreach ($line in $result) {
            # Write-DebugLog "Processing line: '$line'"
            if ($line -match '^\s*(\S+)\s*$' -and $line.Trim() -ne 'NAME') {
                $cameraName = $matches[1].Trim()
                # Write-DebugLog "Found camera name: $cameraName"
                return $cameraName
            }
        }
        # Write-DebugLog "Camera name not found in result"
    } else {
        # Write-DebugLog "Empty result for camera $CameraId"
    }
    
    $unknownName = "Unknown_Camera_$CameraId"
    # Write-DebugLog "Returning unknown name: $unknownName"
    return $unknownName
}

# Function for environment testing
function Test-Environment {
    # Write-Log "=== ENVIRONMENT TESTING ==="
    
    # PowerShell testing
    $executionPolicy = Get-ExecutionPolicy
    $policyOk = $executionPolicy -in @("RemoteSigned", "Unrestricted", "Bypass")
    # Write-Log "PowerShell Execution Policy: $executionPolicy $(if ($policyOk) { '(OK)' } else { '(WARNING)' })"
    
    $psVersion = $PSVersionTable.PSVersion
    # Write-Log "PowerShell Version: $psVersion"
    
    # Firebird testing
    $firebirdExists = Test-Path $FirebirdPath
    # Write-Log "Firebird isql.exe: $(if ($firebirdExists) { 'Found' } else { 'NOT FOUND' }) - $FirebirdPath"
    
    if ($firebirdExists) {
        try {
            $job = Start-Job -ScriptBlock { 
                param($path)
                & $path -z 2>$null
            } -ArgumentList $FirebirdPath
            
            $version = Wait-Job -Job $job -Timeout 10
            if ($version) {
                $result = Receive-Job -Job $job
                Remove-Job -Job $job
                # Write-Log "Firebird Version: $result"
            } else {
                Remove-Job -Job $job -Force
                # Write-Log "Firebird Version: Timeout (10s)"
            }
        }
        catch {
            # Write-Log "Firebird Version: Error getting version"
        }
    }
    
    # Directory testing
    $tempExists = Test-Path $TempDir
    # Write-Log "Temp Directory: $(if ($tempExists) { 'Exists' } else { 'Missing' }) - $TempDir"
    
    $exportExists = Test-Path $ExportDir
    # Write-Log "Export Directory: $(if ($exportExists) { 'Exists' } else { 'Missing' }) - $ExportDir"
    
    # Create directories if needed
    if (!(Test-Path $TempDir)) {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
        # Write-Log "Created Temp Directory: $TempDir"
    }
    
    if (!(Test-Path $ExportDir)) {
        New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
        # Write-Log "Created Export Directory: $ExportDir"
    }
}

# Function for database testing
function Test-Databases {
    # Write-Log "=== DATABASE TESTING ==="
    
    $acsSourcePath = "$SourceDir\ACS.FDB"
    $recordingsSourcePath = "$SourceDir\ACS_RECORDINGS.FDB"
    
    # Check source files existence
    $acsExists = Test-Path $acsSourcePath
    # Write-Log "ACS.FDB Source: $(if ($acsExists) { 'Found' } else { 'NOT FOUND' }) - $acsSourcePath"
    
    $recordingsExists = Test-Path $recordingsSourcePath
    # Write-Log "ACS_RECORDINGS.FDB Source: $(if ($recordingsExists) { 'Found' } else { 'NOT FOUND' }) - $recordingsSourcePath"
    
    if ($acsExists) {
        $acsSize = (Get-Item $acsSourcePath).Length
        # Write-Log "ACS.FDB Size: $($acsSize / 1MB) MB"
    }
    
    if ($recordingsExists) {
        $recordingsSize = (Get-Item $recordingsSourcePath).Length
        # Write-Log "ACS_RECORDINGS.FDB Size: $($recordingsSize / 1MB) MB"
    }
    
    return $acsExists -and $recordingsExists
}

# Function for testing database access
function Test-DatabaseAccess {
    # Write-Log "=== DATABASE ACCESS TESTING ==="
    
    $testResults = @{}
    
    # Test ACS.FDB
    # Write-Log "Testing ACS.FDB access..."
    try {
        # Test copying
        $copySuccess = $false
        try {
            Copy-Item "$SourceDir\ACS.FDB" "$TempDir\ACS.FDB" -Force
            $copySuccess = Test-Path "$TempDir\ACS.FDB"
        }
        catch {
            Write-Log "ACS.FDB Copy: FAILED - File is locked by Axis Camera Station"
            $testResults["ACS_FDB"] = $false
            return $testResults
        }
        
        if (-not $copySuccess) {
            Write-Log "ACS.FDB Copy: FAILED - Failed to copy database file"
            $testResults["ACS_FDB"] = $false
            return $testResults
        }
        
        # Write-Log "ACS.FDB Copy: SUCCESS"
        
        # Test connection
        $query = "SELECT COUNT(*) FROM CAMERA;"
        $tempFile = [System.IO.Path]::GetTempFileName()
        $query | Out-File -FilePath $tempFile -Encoding ASCII
        
        $job = Start-Job -ScriptBlock { param($path, $queryFile, $dbFile) $result = & $path -u SYSDBA -p masterkey -i $queryFile $dbFile 2>&1; return $result } -ArgumentList $FirebirdPath, $tempFile, "$TempDir\ACS.FDB"
        
        $result = Wait-Job -Job $job -Timeout 15
        if ($result) {
            $output = Receive-Job -Job $job
            Remove-Job -Job $job
            
            if ($output -and $output.Count -gt 0) {
                Write-Log "ACS.FDB Query output:"
                for ($i = 0; $i -lt [Math]::Min(10, $output.Count); $i++) {
                    Write-Log "  [$i]: '$($output[$i])'"
                }
                
                $found = $false
                foreach ($line in $output) {
                    $str = $line.ToString()
                    if ($str -match '^\s*(\d+)\s*$') {
                        $count = $matches[1]
                        Write-Log "ACS.FDB Connection: SUCCESS - Cameras found: $count"
                        $testResults["ACS_FDB"] = $true
                        $found = $true
                        break
                    }
                    elseif ($str -match '^\s*COUNT\s+(\d+)\s*$') {
                        $count = $matches[1]
                        Write-Log "ACS.FDB Connection: SUCCESS - Cameras found: $count"
                        $testResults["ACS_FDB"] = $true
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    $debugOutput = $output[0..2] -join ' | '
                    Write-Log "ACS.FDB Connection: SUCCESS - Connection working (debug: $debugOutput)"
                    $testResults["ACS_FDB"] = $true
                }
            } else {
                Write-Log "ACS.FDB Connection: FAILED - No output from query"
                $testResults["ACS_FDB"] = $false
            }
        } else {
            Remove-Job -Job $job -Force
            Write-Log "ACS.FDB Connection: FAILED - Connection timeout (15s)"
            $testResults["ACS_FDB"] = $false
        }
        
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Remove-Item "$TempDir\ACS.FDB" -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "ACS.FDB Test: FAILED - $($_.Exception.Message)"
        $testResults["ACS_FDB"] = $false
    }
    
    # Test ACS_RECORDINGS.FDB
    # Write-Log "Testing ACS_RECORDINGS.FDB access..."
    try {
        # Test copying
        $copySuccess = $false
        try {
            Copy-Item "$SourceDir\ACS_RECORDINGS.FDB" "$TempDir\ACS_RECORDINGS.FDB" -Force
            $copySuccess = Test-Path "$TempDir\ACS_RECORDINGS.FDB"
        }
        catch {
            Write-Log "ACS_RECORDINGS.FDB Copy: FAILED - File is locked by Axis Camera Station"
            $testResults["ACS_RECORDINGS_FDB"] = $false
            return $testResults
        }
        
        if (-not $copySuccess) {
            Write-Log "ACS_RECORDINGS.FDB Copy: FAILED - Failed to copy database file"
            $testResults["ACS_RECORDINGS_FDB"] = $false
            return $testResults
        }
        
        # Write-Log "ACS_RECORDINGS.FDB Copy: SUCCESS"
        
        # Test connection
        $query = "SELECT COUNT(*) FROM RECORDING;"
        $tempFile = [System.IO.Path]::GetTempFileName()
        $query | Out-File -FilePath $tempFile -Encoding ASCII
        
        $job = Start-Job -ScriptBlock { param($path, $queryFile, $dbFile) $result = & $path -u SYSDBA -p masterkey -i $queryFile $dbFile 2>&1; return $result } -ArgumentList $FirebirdPath, $tempFile, "$TempDir\ACS_RECORDINGS.FDB"
        
        $result = Wait-Job -Job $job -Timeout 15
        if ($result) {
            $output = Receive-Job -Job $job
            Remove-Job -Job $job
            
            if ($output -and $output.Count -gt 0) {
                Write-Log "ACS_RECORDINGS.FDB Query output:"
                for ($i = 0; $i -lt [Math]::Min(10, $output.Count); $i++) {
                    Write-Log "  [$i]: '$($output[$i])'"
                }
                
                $found = $false
                foreach ($line in $output) {
                    $str = $line.ToString()
                    if ($str -match '^\s*(\d+)\s*$') {
                        $count = $matches[1]
                        Write-Log "ACS_RECORDINGS.FDB Connection: SUCCESS - Records found: $count"
                        $testResults["ACS_RECORDINGS_FDB"] = $true
                        $found = $true
                        break
                    }
                    elseif ($str -match '^\s*COUNT\s+(\d+)\s*$') {
                        $count = $matches[1]
                        Write-Log "ACS_RECORDINGS.FDB Connection: SUCCESS - Records found: $count"
                        $testResults["ACS_RECORDINGS_FDB"] = $true
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    $debugOutput = $output[0..2] -join ' | '
                    Write-Log "ACS_RECORDINGS.FDB Connection: SUCCESS - Connection working (debug: $debugOutput)"
                    $testResults["ACS_RECORDINGS_FDB"] = $true
                }
            } else {
                Write-Log "ACS_RECORDINGS.FDB Connection: FAILED - No output from query"
                $testResults["ACS_RECORDINGS_FDB"] = $false
            }
        } else {
            Remove-Job -Job $job -Force
            Write-Log "ACS_RECORDINGS.FDB Connection: FAILED - Connection timeout (15s)"
            $testResults["ACS_RECORDINGS_FDB"] = $false
        }
        
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        Remove-Item "$TempDir\ACS_RECORDINGS.FDB" -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "ACS_RECORDINGS.FDB Test: FAILED - $($_.Exception.Message)"
        $testResults["ACS_RECORDINGS_FDB"] = $false
    }
    
    return $testResults
}

# Main monitoring function
function Start-AxisMonitoring {
    Write-Log "Starting Axis Camera Station monitoring..."
    
    try {
        # 1. Environment testing
        Test-Environment
        
        # 2. Database testing
        $databasesExist = Test-Databases
        if (-not $databasesExist) {
            throw "Databases not found"
        }
        
        # 3. Database access testing
        $testResults = Test-DatabaseAccess
        if (-not $testResults["ACS_FDB"] -or -not $testResults["ACS_RECORDINGS_FDB"]) {
            # Write-Log "WARNING: Some database access tests failed"
            Write-Log "Continuing execution, but there may be issues..."
        }
        
        # 4. Copy databases for analysis
        # Write-Log "Copying databases..."
        Copy-Item "$SourceDir\ACS.FDB" "$TempDir\ACS.FDB" -Force
        Copy-Item "$SourceDir\ACS_RECORDINGS.FDB" "$TempDir\ACS_RECORDINGS.FDB" -Force
        
        # 5. Analyze metrics
        Write-Log "Analyzing metrics..."
        
        # Check Firebird availability
        Write-DebugLog "Checking Firebird availability..."
        if (!(Test-Path $FirebirdPath)) {
            Write-Log "ERROR: Firebird isql.exe not found at: $FirebirdPath"
            Write-DebugLog "Searching for alternative paths..."
            $possiblePaths = @(
                "C:\Program Files\Firebird\Firebird_3_0\isql.exe",
                "C:\Program Files (x86)\Firebird\Firebird_3_0\isql.exe",
                "C:\Firebird\bin\isql.exe"
            )
            
            foreach ($path in $possiblePaths) {
                if (Test-Path $path) {
                    Write-Log "Found Firebird at: $path"
                    $FirebirdPath = $path
                    break
                }
            }
            
            if (!(Test-Path $FirebirdPath)) {
                throw "Firebird isql.exe not found. Please install Firebird 3.0 with Development Tools."
            }
        }
        
        # Get total recordings count
        Write-DebugLog "Getting total recordings count..."
        $totalRecordingsQuery = "SELECT COUNT(*) FROM RECORDING;"
        $totalRecordingsResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $totalRecordingsQuery
        
        Write-Log "Total recordings query result:"
        if ($totalRecordingsResult) {
            Write-Log "Result lines: $($totalRecordingsResult.Count)"
            for ($i = 0; $i -lt [Math]::Min(10, $totalRecordingsResult.Count); $i++) {
                Write-Log "  [$i]: '$($totalRecordingsResult[$i])'"
            }
        } else {
            Write-Log "  No result returned"
        }
        
        $totalRecordings = 0
        if ($totalRecordingsResult -and $totalRecordingsResult.Count -gt 0) {
            foreach ($line in $totalRecordingsResult) {
                $str = $line.ToString()
                if ($str -match '^\s*(\d+)\s*$') {
                    $totalRecordings = [int]$str.Trim()
                    Write-DebugLog "Total recordings: $totalRecordings"
                    break
                }
                # Try other patterns
                elseif ($str -match '^\s*COUNT\s+(\d+)\s*$') {
                    $totalRecordings = [int]$str.Trim()
                    Write-DebugLog "Total recordings (with COUNT): $totalRecordings"
                    break
                }
                elseif ($str -match '^\s*(\d+)\s*$' -and $str.Trim() -ne '') {
                    $totalRecordings = [int]$str.Trim()
                    Write-DebugLog "Total recordings (trimmed): $totalRecordings"
                    break
                }
            }
        }
        
        if ($totalRecordings -eq 0) {
            # Write-Log "WARNING: No recordings found in database"
        } else {
            Write-Log "SUCCESS: Found $totalRecordings recordings"
        }
        
        # Initialize variables for oldest recording
        $oldestRecording = $null
        $oldestCameraName = "Unknown"
        $oldestCameraId = 0
        $oldestTimestamp = 0
        
        # Get newest recording
        Write-DebugLog "Getting newest recording..."
        $newestRecordingQuery = "SELECT FIRST 1 START_TIME FROM RECORDING_FILE ORDER BY START_TIME DESC;"
        $newestRecordingResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $newestRecordingQuery
        
        $newestRecording = $null
        if ($newestRecordingResult -and $newestRecordingResult.Count -gt 0) {
            Write-DebugLog "Newest recording result: $($newestRecordingResult -join ' | ')"
            foreach ($line in $newestRecordingResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing newest recording line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $newestTimestampTicks = [long]$str.Trim()
                    # Конвертируем ticks в Unix timestamp (секунды)
                    $newestTimestamp = [long]($newestTimestampTicks / 10000000 - 62135596800)
                    Write-DebugLog "Found newest recording at ticks $newestTimestampTicks, unix $newestTimestamp"
                    break
                }
            }
        }
        
        # Get unique cameras count
        Write-DebugLog "Getting unique cameras count..."
        $uniqueCamerasQuery = "SELECT COUNT(DISTINCT CAMERA_ID) FROM RECORDING;"
        $uniqueCamerasResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $uniqueCamerasQuery
        
        $uniqueCameras = 0
        if ($uniqueCamerasResult -and $uniqueCamerasResult.Count -gt 0) {
            foreach ($line in $uniqueCamerasResult) {
                $str = $line.ToString()
                if ($str -match '^\s*(\d+)\s*$') {
                    $uniqueCameras = [int]$str.Trim()
                    Write-DebugLog "Unique cameras: $uniqueCameras"
                    break
                }
            }
        }
        
        # Initialize timestamps
        if (-not $oldestTimestamp) {
            $oldestTimestamp = 0
        }
        $newestTimestamp = 0
        
        # Current timestamp
        $currentTimestamp = [long]([DateTime]::Now - [DateTime]::new(1970, 1, 1)).TotalSeconds
        
        # Получаем список камер (ID, NAME)
        $cameraList = @{}
        $cameraQuery = "SELECT ID, NAME FROM CAMERA;"
        $cameraResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $cameraQuery
        Write-DebugLog "Camera query result: $($cameraResult -join ' | ')"
        if ($cameraResult) {
            foreach ($line in $cameraResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing camera line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(.+?)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $cname = $matches[2].Trim()
                    $cameraList[$cid] = $cname
                    Write-DebugLog "Found camera $cid with name '$cname'"
                }
            }
        }
        Write-DebugLog "Cameras found: $($cameraList.Count)"

        # Get storage list
        Write-DebugLog "Getting storage list..."
        $storageQuery = "SELECT STORAGE_ID, ROOT_PATH, RECORDING_DIRECTORY FROM STORAGE_LOCAL_DISK;"
        $storageResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $storageQuery
        Write-DebugLog "Storage query result: $($storageResult -join ' | ')"
        $storageList = @{}
        if ($storageResult) {
            foreach ($line in $storageResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing storage line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(.+?)\s+(.+?)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $sid = $matches[1]
                    $rootPath = $matches[2].Trim()
                    $recordingDir = $matches[3].Trim()
                    $storageName = "$rootPath$recordingDir"
                    $storageList[$sid] = $storageName
                    Write-DebugLog "Found storage $sid with name '$storageName'"
                }
            }
        }
        Write-DebugLog "Storages found: $($storageList.Count)"

        # Get oldest recording with camera name (after camera list is populated)
        Write-DebugLog "Getting oldest recording..."
        $oldestRecordingQuery = @"
SELECT FIRST 1 
    RF.CAMERA_ID,
    RF.START_TIME
FROM RECORDING_FILE RF
ORDER BY RF.START_TIME ASC;
"@
        
        $oldestRecordingResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $oldestRecordingQuery
        
        if ($oldestRecordingResult -and $oldestRecordingResult.Count -gt 0) {
            Write-DebugLog "Processing oldest recording result..."
            Write-DebugLog "Oldest recording result: $($oldestRecordingResult -join ' | ')"
            foreach ($line in $oldestRecordingResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing oldest recording line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $oldestCameraId = [int]$matches[1]
                    $oldestTimestampTicks = [long]$matches[2]
                    # Конвертируем ticks в Unix timestamp (секунды)
                    $oldestTimestamp = [long]($oldestTimestampTicks / 10000000 - 62135596800)
                    Write-DebugLog "Found oldest recording: Camera $oldestCameraId at ticks $oldestTimestampTicks, unix $oldestTimestamp (getting name separately)"
                    $oldestCameraName = $cameraList[$oldestCameraId]
                    if (-not $oldestCameraName) {
                        $oldestCameraName = "Unknown"
                    }
                    break
                }
            }
        }

        # Количество активных камер
        $enabledCameras = 0
        $enabledQuery = "SELECT COUNT(*) FROM CAMERA WHERE IS_ENABLED = TRUE;"
        $enabledResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $enabledQuery
        Write-DebugLog "Enabled cameras query result: $($enabledResult -join ' | ')"
        if ($enabledResult) {
            foreach ($line in $enabledResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing enabled cameras line: '$str'"
                if ($str -match '^\s*\d+\s*$') { 
                    $enabledCameras = [int]$str.Trim(); 
                    Write-DebugLog "Found enabled cameras: $enabledCameras"
                    break 
                }
            }
        }

        # Количество отключенных камер
        $disabledCameras = 0
        $disabledQuery = "SELECT COUNT(*) FROM CAMERA WHERE IS_ENABLED = FALSE;"
        $disabledResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $disabledQuery
        Write-DebugLog "Disabled cameras query result: $($disabledResult -join ' | ')"
        if ($disabledResult) {
            foreach ($line in $disabledResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing disabled cameras line: '$str'"
                if ($str -match '^\s*\d+\s*$') { 
                    $disabledCameras = [int]$str.Trim(); 
                    Write-DebugLog "Found disabled cameras: $disabledCameras"
                    break 
                }
            }
        }

        # Общий объём всех записей
        $totalStorage = 0
        $totalStorageQuery = "SELECT SUM(STORAGE_SIZE) AS TOTAL_SIZE FROM RECORDING_FILE;"
        $totalStorageResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $totalStorageQuery
        Write-DebugLog "Total storage query result: $($totalStorageResult -join ' | ')"
        if ($totalStorageResult) {
            foreach ($line in $totalStorageResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing total storage line: '$str'"
                if ($str -match '^\s*\d+\s*$') { 
                    $totalStorage = [long]$str.Trim(); 
                    Write-DebugLog "Found total storage: $totalStorage"
                    break 
                }
            }
        }

        # Объём записей по каждой камере
        $cameraStorage = @{}
        $cameraStorageQuery = "SELECT CAMERA_ID, SUM(STORAGE_SIZE) AS CAMERA_SIZE FROM RECORDING_FILE GROUP BY CAMERA_ID;"
        $cameraStorageResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $cameraStorageQuery
        Write-DebugLog "Camera storage query result: $($cameraStorageResult -join ' | ')"
        if ($cameraStorageResult) {
            foreach ($line in $cameraStorageResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing camera storage line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $size = [long]$matches[2]
                    $cameraStorage[$cid] = $size
                    Write-DebugLog "Found camera $cid with storage $size"
                }
            }
        }
        Write-DebugLog "Camera storage found: $($cameraStorage.Count)"

        # Количество записей на камеру
        $recordingsPerCamera = @{}
        $recordingsPerCameraQuery = "SELECT CAMERA_ID, COUNT(*) as recording_count FROM RECORDING GROUP BY CAMERA_ID;"
        $recordingsPerCameraResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $recordingsPerCameraQuery
        Write-DebugLog "Recordings per camera query result: $($recordingsPerCameraResult -join ' | ')"
        if ($recordingsPerCameraResult) {
            foreach ($line in $recordingsPerCameraResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $count = [int]$matches[2]
                    $recordingsPerCamera[$cid] = $count
                    Write-DebugLog "Found camera $cid with $count recordings"
                }
            }
        }
        Write-DebugLog "Recordings per camera found: $($recordingsPerCamera.Count)"

        # Количество незавершенных записей
        $incompleteRecordings = 0
        $incompleteQuery = "SELECT COUNT(*) FROM RECORDING_FILE WHERE IS_COMPLETE = FALSE;"
        $incompleteResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $incompleteQuery
        Write-DebugLog "Incomplete recordings query result: $($incompleteResult -join ' | ')"
        if ($incompleteResult) {
            foreach ($line in $incompleteResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing incomplete recordings line: '$str'"
                if ($str -match '^\s*\d+\s*$') { 
                    $incompleteRecordings = [int]$str.Trim(); 
                    Write-DebugLog "Found incomplete recordings: $incompleteRecordings"
                    break 
                }
            }
        }

        # Средний размер записи
        $avgRecordingSize = 0
        $avgSizeQuery = "SELECT COALESCE(AVG(STORAGE_SIZE), 0) FROM RECORDING_FILE WHERE IS_COMPLETE = TRUE;"
        $avgSizeResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $avgSizeQuery
        Write-DebugLog "Average size query result: $($avgSizeResult -join ' | ')"
        if ($avgSizeResult) {
            foreach ($line in $avgSizeResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing avg size line: '$str'"
                if ($str -match '^\s*\d+\s*$') { 
                    $avgRecordingSize = [long]$str.Trim(); 
                    Write-DebugLog "Found average size: $avgRecordingSize"
                    break 
                }
            }
        }

        # Средняя длительность записи
        $avgRecordingDuration = 0
        $avgDurationQuery = "SELECT COALESCE(AVG(STOP_TIME - START_TIME), 0) FROM RECORDING_FILE WHERE IS_COMPLETE = TRUE AND STOP_TIME > START_TIME;"
        $avgDurationResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $avgDurationQuery
        Write-DebugLog "Average duration query result: $($avgDurationResult -join ' | ')"
        if ($avgDurationResult) {
            foreach ($line in $avgDurationResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing average duration line: '$str'"
                if ($str -match '^\s*\d+\s*$') { 
                    $avgRecordingDuration = [long]$str.Trim(); 
                    Write-DebugLog "Found average duration: $avgRecordingDuration"
                    break 
                }
            }
        }

        # События по категориям
        $eventsByCategory = @{}
        $eventsQuery = @"
SELECT ec.NAME, COUNT(rfec.RECORDING_FILE_ID) as event_count 
FROM EVENT_CATEGORY ec 
LEFT JOIN RECORDING_FILE_EVENT_CATEGORY rfec ON ec.ID = rfec.EVENT_CATEGORY_ID 
GROUP BY ec.ID, ec.NAME;
"@
        $eventsResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $eventsQuery
        Write-DebugLog "Events query result: $($eventsResult -join ' | ')"
        Write-DebugLog "Events result count: $($eventsResult.Count)"
        if ($eventsResult) {
            foreach ($line in $eventsResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing events line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(.+?)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $category = $matches[1].Trim()
                    $count = [int]$matches[2]
                    $eventsByCategory[$category] = $count
                    Write-DebugLog "Found category '$category' with $count events"
                }
            }
        }
        Write-DebugLog "Events categories found: $($eventsByCategory.Count)"

        # Записи по хранилищам
        $recordingsByStorage = @{}
        $storageRecordingsQuery = "SELECT STORAGE_ID, COUNT(*) as recording_count FROM RECORDING_FILE GROUP BY STORAGE_ID;"
        $storageRecordingsResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $storageRecordingsQuery
        Write-DebugLog "Storage recordings query result: $($storageRecordingsResult -join ' | ')"
        if ($storageRecordingsResult) {
            foreach ($line in $storageRecordingsResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing storage recordings line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $storageId = $matches[1]
                    $count = [int]$matches[2]
                    $recordingsByStorage[$storageId] = $count
                    Write-DebugLog "Found storage $storageId with $count recordings"
                }
            }
        }
        Write-DebugLog "Storage recordings found: $($recordingsByStorage.Count)"

        # Размер по хранилищам
        $storageByStorage = @{}
        $storageSizeQuery = "SELECT STORAGE_ID, COALESCE(SUM(STORAGE_SIZE), 0) as storage_size FROM RECORDING_FILE GROUP BY STORAGE_ID;"
        $storageSizeResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $storageSizeQuery
        Write-DebugLog "Storage size query result: $($storageSizeResult -join ' | ')"
        if ($storageSizeResult) {
            foreach ($line in $storageSizeResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing storage size line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $storageId = $matches[1]
                    $size = [long]$matches[2]
                    $storageByStorage[$storageId] = $size
                    Write-DebugLog "Found storage $storageId with size $size"
                }
            }
        }
        Write-DebugLog "Storage sizes found: $($storageByStorage.Count)"

        # Дата последней записи по каждой камере (ticks и unix)
        $lastStopTimes = @{}
        $lastStartTimes = @{}
        $lastTimeQuery = "SELECT CAMERA_ID, MAX(STOP_TIME) AS LAST_STOP_TIME, MAX(START_TIME) AS LAST_START_TIME FROM RECORDING_FILE GROUP BY CAMERA_ID;"
        $lastTimeResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $lastTimeQuery
        Write-DebugLog "Last time query result: $($lastTimeResult -join ' | ')"
        if ($lastTimeResult) {
            foreach ($line in $lastTimeResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing last time line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $stopTicks = [long]$matches[2]
                    $startTicks = [long]$matches[3]
                    $lastStopTimes[$cid] = $stopTicks
                    $lastStartTimes[$cid] = $startTicks
                    Write-DebugLog "Found camera $cid with stop time $stopTicks and start time $startTicks"
                }
            }
        }
        Write-DebugLog "Last times found: $($lastStopTimes.Count)"

        # Retention time per camera
        $retentionByCamera = @{}
        $retentionQuery = "SELECT CAMERA_ID, KEEP_TIME FROM CAMERA_STORAGE;"
        $retentionResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $retentionQuery
        Write-DebugLog "Retention query result: $($retentionResult -join ' | ')"
        if ($retentionResult) {
            foreach ($line in $retentionResult) {
                $str = $line.ToString()
                Write-DebugLog "Processing retention line: '$str'"
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+<null>\s*$' -or $str -match '([0-9]+).*<null>') {
                    $cid = $matches[1]
                    $retentionByCamera[$cid] = -1
                    Write-DebugLog "Found camera $cid with unlimited retention (NULL in DB)"
                } elseif ($str -match '^[\s\t]*(\d+)[\s\t]+(\d+)[\s\t]*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $keepTimeTicks = [long]$matches[2]
                    $retentionDays = [long]($keepTimeTicks / 864000000000)
                    $retentionByCamera[$cid] = $retentionDays
                    Write-DebugLog "Found camera $cid with retention $retentionDays days (ticks: $keepTimeTicks)"
                } else {
                    # Дополнительная отладка для строк, которые не попадают в регулярки
                    if ($str -match '^\s*\d+\s+\d+\s*$') {
                        Write-DebugLog "DEBUG: String matches basic pattern but not detailed: '$str'"
                    } elseif ($str -match '^\s*\d+\s+<null>\s*$') {
                        Write-DebugLog "DEBUG: String matches null pattern but not detailed: '$str'"
                    } else {
                        Write-DebugLog "DEBUG: String doesn't match any retention pattern: '$str'"
                    }
                }
            }
        }
        Write-DebugLog "Retention times found: $($retentionByCamera.Count)"

        # 6. Write metrics to export file
        Write-Log "Writing metrics to export file..."
        $metricsFile = "$ExportDir\axis_camera_station_metrics.prom"
        
        $metrics = @()
        
        # Старейшая запись по каждой камере
        $metrics += "# HELP axis_camera_station_oldest_recording_timestamp Oldest recording timestamp per camera"
        $metrics += "# TYPE axis_camera_station_oldest_recording_timestamp gauge"
        foreach ($cid in $cameraList.Keys) {
            $oldestQuery = "SELECT MIN(START_TIME) FROM RECORDING_FILE WHERE CAMERA_ID = $cid;"
            $oldestResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $oldestQuery
            $oldestTimestamp = 0
            if ($oldestResult) {
                foreach ($line in $oldestResult) {
                    $str = $line.ToString()
                    if ($str -match '^\s*(\d+)\s*$') {
                        $ticks = [long]$str.Trim()
                        $oldestTimestamp = [long]($ticks / 10000000 - 62135596800)
                        break
                    }
                }
            }
            $cname = $cameraList[$cid]
            if ($cname) { $cname = $cname -replace '\\', '\\\\' }
            if ($oldestTimestamp -gt 0) {
                $metrics += "axis_camera_station_oldest_recording_timestamp{camera_id=`"$cid`",camera_name=`"$cname`"} $oldestTimestamp"
            }
        }
        
        # Total recordings
        $metrics += "axis_camera_station_total_recordings $totalRecordings"
        
        # Total cameras
        $metrics += "axis_camera_station_total_cameras $uniqueCameras"
        
        # Newest recording
        if ($newestTimestamp -gt 0) {
            $metrics += "axis_camera_station_newest_recording_timestamp $newestTimestamp"
        }
        
        # Last update timestamp
        $metrics += "axis_camera_station_monitoring_last_update $currentTimestamp"
        
        # Все новые метрики
        $metrics += "# HELP axis_camera_station_storage_used_bytes Total storage used by all recordings"
        $metrics += "# TYPE axis_camera_station_storage_used_bytes gauge"
        $metrics += "axis_camera_station_storage_used_bytes $totalStorage"

        $metrics += "# HELP axis_camera_station_enabled_total Number of enabled cameras"
        $metrics += "# TYPE axis_camera_station_enabled_total gauge"
        $metrics += "axis_camera_station_enabled_total $enabledCameras"

        $metrics += "# HELP axis_camera_station_disabled_total Number of disabled cameras"
        $metrics += "# TYPE axis_camera_station_disabled_total gauge"
        $metrics += "axis_camera_station_disabled_total $disabledCameras"

        # Метрики по камерам (storage_used_bytes_per_camera)
        $metrics += "# HELP axis_camera_station_storage_used_bytes_per_camera Storage used by camera"
        $metrics += "# TYPE axis_camera_station_storage_used_bytes_per_camera gauge"
        foreach ($cid in $cameraStorage.Keys) {
            $size = $cameraStorage[$cid]
            $cname = $cameraList[$cid]
            if ($cname) { $cname = $cname -replace '\\', '\\\\' }
            $metrics += "axis_camera_station_storage_used_bytes_per_camera{camera_id=`"$cid`",camera_name=`"$cname`"} $size"
        }

        # Метрики по камерам (last_recording_stop/start_timestamp_seconds)
        $metrics += "# HELP axis_camera_station_last_recording_stop_timestamp_seconds Last recording stop time (unix timestamp, seconds) for camera"
        $metrics += "# TYPE axis_camera_station_last_recording_stop_timestamp_seconds gauge"
        $metrics += "# HELP axis_camera_station_last_recording_start_timestamp_seconds Last recording start time (unix timestamp, seconds) for camera"
        $metrics += "# TYPE axis_camera_station_last_recording_start_timestamp_seconds gauge"
        foreach ($cid in $lastStopTimes.Keys) {
            $stopUnix = $lastStopTimes[$cid]
            $startUnix = $lastStartTimes[$cid]
            $cname = $cameraList[$cid]
            if ($cname) { $cname = $cname -replace '\\', '\\\\' }
            $metrics += "axis_camera_station_last_recording_stop_timestamp_seconds{camera_id=`"$cid`",camera_name=`"$cname`"} $stopUnix"
            $metrics += "axis_camera_station_last_recording_start_timestamp_seconds{camera_id=`"$cid`",camera_name=`"$cname`"} $startUnix"
        }

        # Метрики по камерам (recordings_total_per_camera)
        $metrics += "# HELP axis_camera_station_recordings_total_per_camera Number of recordings per camera"
        $metrics += "# TYPE axis_camera_station_recordings_total_per_camera gauge"
        foreach ($cid in $recordingsPerCamera.Keys) {
            $count = $recordingsPerCamera[$cid]
            $cname = $cameraList[$cid]
            if ($cname) { $cname = $cname -replace '\\', '\\\\' }
            $metrics += "axis_camera_station_recordings_total_per_camera{camera_id=`"$cid`",camera_name=`"$cname`"} $count"
        }

        # Метрики по камерам (retention_days_per_camera)
        $metrics += "# HELP axis_camera_station_retention_days_per_camera Retention time in days per camera"
        $metrics += "# TYPE axis_camera_station_retention_days_per_camera gauge"
        foreach ($cid in $retentionByCamera.Keys) {
            $retentionDays = $retentionByCamera[$cid]
            $cname = $cameraList[$cid]
            if ($cname) { $cname = $cname -replace '\\', '\\\\' }
            $metrics += "axis_camera_station_retention_days_per_camera{camera_id=`"$cid`",camera_name=`"$cname`"} $retentionDays"
        }

        # Метрики по хранилищам (recordings_total_by_storage)
        $metrics += "# HELP axis_camera_station_recordings_total_by_storage Number of recordings by storage"
        $metrics += "# TYPE axis_camera_station_recordings_total_by_storage gauge"
        foreach ($storageId in $recordingsByStorage.Keys) {
            $count = $recordingsByStorage[$storageId]
            $sname = $storageList[$storageId]
            if (-not $sname) { $sname = "Unknown" }
            $sname = $sname -replace '\\', '\\\\'
            $metrics += "axis_camera_station_recordings_total_by_storage{storage_id=`"$storageId`",storage_name=`"$sname`"} $count"
        }

        # Метрики по хранилищам (storage_used_bytes_by_storage)
        $metrics += "# HELP axis_camera_station_storage_used_bytes_by_storage Storage used by storage in bytes"
        $metrics += "# TYPE axis_camera_station_storage_used_bytes_by_storage gauge"
        foreach ($storageId in $storageByStorage.Keys) {
            $size = $storageByStorage[$storageId]
            $sname = $storageList[$storageId]
            if (-not $sname) { $sname = "Unknown" }
            $sname = $sname -replace '\\', '\\\\'
            $metrics += "axis_camera_station_storage_used_bytes_by_storage{storage_id=`"$storageId`",storage_name=`"$sname`"} $size"
        }
        
        # Write to file
        $metrics | Out-File -FilePath $metricsFile -Encoding UTF8 -Force
        
        Write-Log "Metrics written to file: $metricsFile"
        
        # Log summary
        if ($oldestTimestamp -gt 0) {
            $oldestDate = [DateTimeOffset]::FromUnixTimeSeconds($oldestTimestamp).DateTime
            # Get camera name from camera list
            $oldestCameraName = "Unknown"
            if ($cameraList -and $cameraList.ContainsKey($oldestCameraId)) {
                $oldestCameraName = $cameraList[$oldestCameraId]
            }
            Write-Log "Oldest recording: $oldestCameraName ($oldestDate)"
        }
        Write-Log "Total recordings: $totalRecordings"
        Write-Log "Total cameras: $uniqueCameras"
        if ($newestTimestamp -gt 0) {
            $newestDate = [DateTimeOffset]::FromUnixTimeSeconds($newestTimestamp).DateTime
            Write-Log "Newest recording: $newestDate"
        }
        
        Write-Log "Monitoring completed successfully!"
    }
    catch {
        Write-Log "ERROR: $($_.Exception.Message)"
        Write-DebugLog "Exception details: $($_.Exception.ToString())"
        throw
    }
    finally {
        # Cleanup temp files
        Cleanup-TempFiles
        Write-Log "=== MONITORING SESSION END ==="
    }
}

# Start monitoring
Start-AxisMonitoring 