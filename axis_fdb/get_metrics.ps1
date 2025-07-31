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

# Function for cleaning temp files
function Remove-TempFiles {
    if (Test-Path "$TempDir\ACS.FDB") {
        Remove-Item "$TempDir\ACS.FDB" -Force
    }
    if (Test-Path "$TempDir\ACS_RECORDINGS.FDB") {
        Remove-Item "$TempDir\ACS_RECORDINGS.FDB" -Force
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
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $Query | Out-File -FilePath $tempFile -Encoding ASCII
        $absolutePath = [System.IO.Path]::GetFullPath($Database)
        $result = & $FirebirdPath -u $Username -p $Password -i $tempFile $absolutePath 2>&1
        Remove-Item $tempFile -Force
        return $result
    }
    catch {
        return $null
    }
}

# Function for getting camera name by ID
function Get-CameraName {
    param([int]$CameraId)
    
    $query = @"
SELECT NAME FROM CAMERA WHERE ID = $CameraId;
"@
    
    $result = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $query
    
    if ($result -and $result.Count -gt 0) {
        foreach ($line in $result) {
            if ($line -match '^\s*(\S+)\s*$' -and $line.Trim() -ne 'NAME') {
                $cameraName = $matches[1].Trim()
                return $cameraName
            }
        }
    }
    
    $unknownName = "Unknown_Camera_$CameraId"
    return $unknownName
}

# Function for environment testing
function Test-Environment {
    # Create directories if needed
    if (!(Test-Path $TempDir)) {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    }
    
    if (!(Test-Path $ExportDir)) {
        New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
    }
}

# Function for database testing
function Test-Databases {
    $acsSourcePath = "$SourceDir\ACS.FDB"
    $recordingsSourcePath = "$SourceDir\ACS_RECORDINGS.FDB"
    
    # Check source files existence
    $acsExists = Test-Path $acsSourcePath
    $recordingsExists = Test-Path $recordingsSourcePath
    
    return $acsExists -and $recordingsExists
}



# Main monitoring function
function Start-AxisMonitoring {
    
    
    try {
        # 1. Environment testing
        Test-Environment
        
        # 2. Database testing
        $databasesExist = Test-Databases
        if (-not $databasesExist) {
            throw "Databases not found"
        }
        

        
        # 4. Copy databases for analysis
        Copy-Item "$SourceDir\ACS.FDB" "$TempDir\ACS.FDB" -Force
        Copy-Item "$SourceDir\ACS_RECORDINGS.FDB" "$TempDir\ACS_RECORDINGS.FDB" -Force
        
        # 5. Analyze metrics
        
        # Check Firebird availability
        if (!(Test-Path $FirebirdPath)) {
            $possiblePaths = @(
                "C:\Program Files\Firebird\Firebird_3_0\isql.exe",
                "C:\Program Files (x86)\Firebird\Firebird_3_0\isql.exe",
                "C:\Firebird\bin\isql.exe"
            )
            
            foreach ($path in $possiblePaths) {
                if (Test-Path $path) {
                    $FirebirdPath = $path
                    break
                }
            }
            
            if (!(Test-Path $FirebirdPath)) {
                throw "Firebird isql.exe not found. Please install Firebird 3.0 with Development Tools."
            }
        }
        
        # Get total recordings count
        $totalRecordingsQuery = "SELECT COUNT(*) FROM RECORDING;"
        $totalRecordingsResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $totalRecordingsQuery
        
        $totalRecordings = 0
        if ($totalRecordingsResult -and $totalRecordingsResult.Count -gt 0) {
            foreach ($line in $totalRecordingsResult) {
                $str = $line.ToString()
                if ($str -match '^\s*(\d+)\s*$') {
                    $totalRecordings = [int]$str.Trim()
                    break
                }
                # Try other patterns
                elseif ($str -match '^\s*COUNT\s+(\d+)\s*$') {
                    $totalRecordings = [int]$str.Trim()
                    break
                }
                elseif ($str -match '^\s*(\d+)\s*$' -and $str.Trim() -ne '') {
                    $totalRecordings = [int]$str.Trim()
                    break
                }
            }
        }
        
        # Initialize variables for oldest recording
        $oldestCameraName = "Unknown"
        $oldestCameraId = 0
        $oldestTimestamp = 0
        
        # Get newest recording
        $newestRecordingQuery = "SELECT FIRST 1 START_TIME FROM RECORDING_FILE ORDER BY START_TIME DESC;"
        $newestRecordingResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $newestRecordingQuery
        
        if ($newestRecordingResult -and $newestRecordingResult.Count -gt 0) {
            foreach ($line in $newestRecordingResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $newestTimestampTicks = [long]$str.Trim()
                    # Конвертируем ticks в Unix timestamp (секунды)
                    $newestTimestamp = [long]($newestTimestampTicks / 10000000 - 62135596800)
                    break
                }
            }
        }
        
        # Get unique cameras count
        $uniqueCamerasQuery = "SELECT COUNT(DISTINCT CAMERA_ID) FROM RECORDING;"
        $uniqueCamerasResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $uniqueCamerasQuery
        
        $uniqueCameras = 0
        if ($uniqueCamerasResult -and $uniqueCamerasResult.Count -gt 0) {
            foreach ($line in $uniqueCamerasResult) {
                $str = $line.ToString()
                if ($str -match '^\s*(\d+)\s*$') {
                    $uniqueCameras = [int]$str.Trim()
                    break
                }
            }
        }
        
        # Initialize timestamps
        if (-not $oldestTimestamp) {
            $oldestTimestamp = 0
        }
        
        # Current timestamp
        $currentTimestamp = [long]([DateTime]::Now - [DateTime]::new(1970, 1, 1)).TotalSeconds
        
        # Получаем список камер (ID, NAME)
        $cameraList = @{}
        $cameraQuery = "SELECT ID, NAME FROM CAMERA;"
        $cameraResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $cameraQuery
        if ($cameraResult) {
            foreach ($line in $cameraResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(.+?)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $cname = $matches[2].Trim()
                    $cameraList[$cid] = $cname
                }
            }
        }

        # Get storage list
        $storageQuery = "SELECT STORAGE_ID, ROOT_PATH, RECORDING_DIRECTORY FROM STORAGE_LOCAL_DISK;"
        $storageResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $storageQuery
        $storageList = @{}
        # Hashtable to keep total disk capacity per storage in bytes
        $storageCapacityByStorage = @{}
        # Hashtable to keep free space per storage (bytes)
        $storageFreeByStorage = @{}
        if ($storageResult) {
            foreach ($line in $storageResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(.+?)\s+(.+?)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $sid = $matches[1]
                    $rootPath = $matches[2].Trim()
                    $recordingDir = $matches[3].Trim()
                    $storageName = "$rootPath$recordingDir"
                    $storageList[$sid] = $storageName

                    # Determine total capacity of the drive where storage resides (bytes)
                    try {
                        # Extract drive letter like "E:" from ROOT_PATH
                        $driveId = ($rootPath -replace "\\", "").Substring(0,2)
                        $driveInfo = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveId'"
                        if ($driveInfo) {
                            $capacity = [long]$driveInfo.Size
                            $freeSpace = [long]$driveInfo.FreeSpace
                        } else {
                            $capacity = -1
                            $freeSpace = -1
                        }
                    } catch {
                        $capacity = -1
                    }
                    $storageCapacityByStorage[$sid] = $capacity
                    $storageFreeByStorage[$sid] = $freeSpace
                }
            }
        }

        # Get oldest recording with camera name (after camera list is populated)
        $oldestRecordingQuery = @"
SELECT FIRST 1 
    RF.CAMERA_ID,
    RF.START_TIME
FROM RECORDING_FILE RF
ORDER BY RF.START_TIME ASC;
"@
        
        $oldestRecordingResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $oldestRecordingQuery
        
        if ($oldestRecordingResult -and $oldestRecordingResult.Count -gt 0) {
            foreach ($line in $oldestRecordingResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $oldestCameraId = [int]$matches[1]
                    $oldestTimestampTicks = [long]$matches[2]
                    # Конвертируем ticks в Unix timestamp (секунды)
                    $oldestTimestamp = [long]($oldestTimestampTicks / 10000000 - 62135596800)
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
        if ($enabledResult) {
            foreach ($line in $enabledResult) {
                $str = $line.ToString()
                if ($str -match '^\s*\d+\s*$') { 
                    $enabledCameras = [int]$str.Trim(); 
                    break 
                }
            }
        }

        # Количество отключенных камер
        $disabledCameras = 0
        $disabledQuery = "SELECT COUNT(*) FROM CAMERA WHERE IS_ENABLED = FALSE;"
        $disabledResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $disabledQuery
        if ($disabledResult) {
            foreach ($line in $disabledResult) {
                $str = $line.ToString()
                if ($str -match '^\s*\d+\s*$') { 
                    $disabledCameras = [int]$str.Trim(); 
                    break 
                }
            }
        }

        # Общий объём всех записей
        $totalStorage = 0
        $totalStorageQuery = "SELECT SUM(STORAGE_SIZE) AS TOTAL_SIZE FROM RECORDING_FILE;"
        $totalStorageResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $totalStorageQuery
        if ($totalStorageResult) {
            foreach ($line in $totalStorageResult) {
                $str = $line.ToString()
                if ($str -match '^\s*\d+\s*$') { 
                    $totalStorage = [long]$str.Trim(); 
                    break 
                }
            }
        }

        # Объём записей по каждой камере
        $cameraStorage = @{}
        $cameraStorageQuery = "SELECT CAMERA_ID, SUM(STORAGE_SIZE) AS CAMERA_SIZE FROM RECORDING_FILE GROUP BY CAMERA_ID;"
        $cameraStorageResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $cameraStorageQuery
        if ($cameraStorageResult) {
            foreach ($line in $cameraStorageResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $size = [long]$matches[2]
                    $cameraStorage[$cid] = $size
                }
            }
        }

        # Количество записей на камеру
        $recordingsPerCamera = @{}
        $recordingsPerCameraQuery = "SELECT CAMERA_ID, COUNT(*) as recording_count FROM RECORDING GROUP BY CAMERA_ID;"
        $recordingsPerCameraResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $recordingsPerCameraQuery
        if ($recordingsPerCameraResult) {
            foreach ($line in $recordingsPerCameraResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $count = [int]$matches[2]
                    $recordingsPerCamera[$cid] = $count
                }
            }
        }

        # Записи по хранилищам
        $recordingsByStorage = @{}
        $storageRecordingsQuery = "SELECT STORAGE_ID, COUNT(*) as recording_count FROM RECORDING_FILE GROUP BY STORAGE_ID;"
        $storageRecordingsResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $storageRecordingsQuery
        if ($storageRecordingsResult) {
            foreach ($line in $storageRecordingsResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $storageId = $matches[1]
                    $count = [int]$matches[2]
                    $recordingsByStorage[$storageId] = $count
                }
            }
        }

        # Размер по хранилищам
        $storageByStorage = @{}
        $storageSizeQuery = "SELECT STORAGE_ID, COALESCE(SUM(STORAGE_SIZE), 0) as storage_size FROM RECORDING_FILE GROUP BY STORAGE_ID;"
        $storageSizeResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $storageSizeQuery
        if ($storageSizeResult) {
            foreach ($line in $storageSizeResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $storageId = $matches[1]
                    $size = [long]$matches[2]
                    $storageByStorage[$storageId] = $size
                }
            }
        }

        # Дата последней записи по каждой камере (ticks и unix)
        $lastStopTimes = @{}
        $lastStartTimes = @{}
        $lastTimeQuery = "SELECT CAMERA_ID, MAX(STOP_TIME) AS LAST_STOP_TIME, MAX(START_TIME) AS LAST_START_TIME FROM RECORDING_FILE GROUP BY CAMERA_ID;"
        $lastTimeResult = Invoke-FirebirdQuery -Database "$TempDir\ACS_RECORDINGS.FDB" -Query $lastTimeQuery
        if ($lastTimeResult) {
            foreach ($line in $lastTimeResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $stopTicks = [long]$matches[2]
                    $startTicks = [long]$matches[3]
                    $lastStopTimes[$cid] = $stopTicks
                    $lastStartTimes[$cid] = $startTicks
                }
            }
        }

        # Retention time per camera
        $retentionByCamera = @{}
        $retentionQuery = "SELECT CAMERA_ID, KEEP_TIME FROM CAMERA_STORAGE;"
        $retentionResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $retentionQuery
        if ($retentionResult) {
            foreach ($line in $retentionResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+<null>\s*$' -or $str -match '([0-9]+).*<null>') {
                    $cid = $matches[1]
                    $retentionByCamera[$cid] = -1
                } elseif ($str -match '^[\s\t]*(\d+)[\s\t]+(\d+)[\s\t]*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $keepTimeTicks = [long]$matches[2]
                    $retentionDays = [long]($keepTimeTicks / 864000000000)
                    $retentionByCamera[$cid] = $retentionDays
                } else {
                    # Дополнительная отладка для строк, которые не попадают в регулярки
                    if ($str -match '^\s*\d+\s+\d+\s*$') {
                        # DEBUG: String matches basic pattern but not detailed: '$str'
                    } elseif ($str -match '^\s*\d+\s+<null>\s*$') {
                        # DEBUG: String matches null pattern but not detailed: '$str'
                    } else {
                        # DEBUG: String doesn't match any retention pattern: '$str'
                    }
                }
            }
        }

        # HTTPS статус по камерам
        $httpsStatusByCamera = @{}
        $httpsStatusQuery = @"
SELECT c.ID, c.NAME, d.HOSTNAME, dcs.IS_HTTPS_ENABLED 
FROM CAMERA c 
JOIN DEVICE d ON c.DEVICE_ID = d.ID 
JOIN DEVICE_CERTIFICATE_SETTINGS dcs ON d.ID = dcs.DEVICE_ID
ORDER BY c.ID;
"@
        $httpsStatusResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $httpsStatusQuery
        if ($httpsStatusResult) {
            foreach ($line in $httpsStatusResult) {
                $str = $line.ToString()
                # Пропускаем заголовки и разделители, парсим только строки с данными
                if ($str -match '^\s*(\d+)\s+(.+?)\s+(.+?)\s+(.+?)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $parts = $str -split '\s+'
                    $parts = $parts | Where-Object { $_ -ne "" }
                    if ($parts.Count -ge 4) {
                        $cid = $parts[0]
                        $httpsEnabled = $parts[-1]  # Последнее поле - HTTPS статус
                        $hostname = $parts[-2]      # Предпоследнее поле - hostname
                        $cname = ($parts[1..($parts.Count-3)] -join " ").Trim()  # Все поля между ID и hostname
                        
                        # Конвертируем <true>/<false> в 1/0
                        $httpsValue = if ($httpsEnabled -eq "<true>") { 1 } else { 0 }
                        $httpsStatusByCamera[$cid] = @{
                            CameraName = $cname
                            Hostname = $hostname
                            HttpsEnabled = $httpsValue
                        }
                    }
                }
            }
        }

        # NTP DHCP статус по камерам
        $ntpDhcpStatusByCamera = @{}
        $ntpDhcpQuery = @"
SELECT c.ID,
       IIF(dts.SERVER_AS_PRIMARY_NTP, 0, 1) AS NTP_DHCP
FROM CAMERA c
JOIN DEVICE d ON c.DEVICE_ID = d.ID
JOIN DEVICE_TIME_SETTINGS dts ON dts.DEVICE_ID = d.ID;
"@
        $ntpDhcpResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $ntpDhcpQuery
        if ($ntpDhcpResult) {
            foreach ($line in $ntpDhcpResult) {
                $str = $line.ToString()
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $cid = $matches[1]
                    $dhcpVal = [int]$matches[2]
                    $ntpDhcpStatusByCamera[$cid] = $dhcpVal
                }
            }
        }

        # Лицензионный статус и дата создания камер
        $licenseStatusByCamera = @{}
        $cameraCreationByCamera = @{}

        # Получаем JSON с лицензиями из KEY_VALUE
        # --- LICENSE JSON PARSING ---
        $licenseJsonQuery = @"
SELECT "VALUE" FROM KEY_VALUE WHERE KEY = 'LicenseState';
"@
        $licenseJsonResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $licenseJsonQuery

        $licenseStatusByMac = @{}
        if ($licenseJsonResult) {
            foreach ($line in $licenseJsonResult) {
                $str = $line.ToString()
                # Try to extract JSON from the line
                $jsonStart = $str.IndexOf('{')
                $jsonEnd = $str.LastIndexOf('}') + 1
                if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
                    $jsonString = $str.Substring($jsonStart, $jsonEnd - $jsonStart)
                    try {
                        $jsonData = $jsonString | ConvertFrom-Json

                        if ($jsonData.LicenseStateJson) {
                            $licenseStateBytes = [System.Convert]::FromBase64String($jsonData.LicenseStateJson)
                            $licenseStateString = [System.Text.Encoding]::UTF8.GetString($licenseStateBytes)

                            # Находим конец валидного JSON (до символа |)
                            $jsonEndIndex = $licenseStateString.IndexOf('|')
                            if ($jsonEndIndex -gt 0) {
                                $cleanJsonString = $licenseStateString.Substring(0, $jsonEndIndex)
                            } else {
                                $cleanJsonString = $licenseStateString
                            }

                            $licenseStateJson = $cleanJsonString | ConvertFrom-Json

                            if ($licenseStateJson.system_description -and $licenseStateJson.system_description.acs -and $licenseStateJson.system_description.acs.known_devices) {
                                foreach ($device in $licenseStateJson.system_description.acs.known_devices) {
                                    $mac = $device.device_identifier
                                    $accumulatedTimestamp = $device.accumulated_timestamp
                                    
                                    # Определяем статус лицензии: если accumulated_timestamp = "00:00:00", то нелицензированная
                                    if ($accumulatedTimestamp -eq "00:00:00") {
                                        $licenseStatus = 0
                                    } else {
                                        $licenseStatus = 1
                                    }
                                    $licenseStatusByMac[$mac] = $licenseStatus
                                }
                            }
                        }
                    } catch {
                        # Error parsing LicenseStateJson: $_
                    }
                } else {
                    # Could not extract JSON from line: jsonStart=$jsonStart, jsonEnd=$jsonEnd
                }
            }
        } else {
            # No license JSON result returned from database
        }

        # --- CAMERA CREATION DATES ---
        $cameraCreationQuery = @"
SELECT c.ID, c.NAME, c.CREATED_TIME 
FROM CAMERA c 
ORDER BY c.ID;
"@
        $cameraCreationResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $cameraCreationQuery

        $cameraCreationByCamera = @{}
        if ($cameraCreationResult) {
            foreach ($line in $cameraCreationResult) {
                $str = $line.ToString()
                # Fix: Allow for missing milliseconds in date, and tolerate extra whitespace
                if ($str -match '^\s*(\d+)\s+(.+?)\s+(\d{4}-\d{2}-\d{2}(?:\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)?)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $parts = $str -split '\s+'
                    $parts = $parts | Where-Object { $_ -ne "" }
                    if ($parts.Count -ge 3) {
                        $cid = $parts[0]
                        $cname = ($parts[1..($parts.Count-2)] -join " ").Trim()
                        $createdTime = $parts[-1]
                        $creationDateStr = $null
                        if ($createdTime -match '(\d{4}-\d{2}-\d{2})') {
                            $creationDateStr = $matches[1]
                        } else {
                            foreach ($part in $parts) {
                                if ($part -match '^\d{4}-\d{2}-\d{2}$') {
                                    $creationDateStr = $part
                                    break
                                }
                            }
                            if (-not $creationDateStr) {
                                $creationDateStr = "N/A"
                            }
                        }
                        $cameraCreationByCamera[$cid] = @{
                            CameraName = $cname
                            CreationDate = $creationDateStr
                        }
                    }
                }
            }
        } else {
            # No camera creation result returned from database
        }

        # --- CAMERAS WITH MAC ADDRESSES ---
        $camerasQuery = @"
SELECT c.ID, c.NAME, d.MAC_ADDRESS 
FROM CAMERA c 
JOIN DEVICE d ON c.DEVICE_ID = d.ID 
ORDER BY c.ID;
"@
        $camerasResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $camerasQuery

        # This will be the final $licenseStatusByCamera: keyed by camera ID, value is hashtable with CameraName, MacAddress, LicenseStatus, CreationDate
        $licenseStatusByCamera = @{}
        if ($camerasResult) {
            foreach ($line in $camerasResult) {
                $str = $line.ToString()
                # Fix: MAC address may contain colons or dashes, so match more flexibly
                if ($str -match '^\s*(\d+)\s+(.+?)\s+([A-Fa-f0-9:-]+)\s*$' -and $str -notmatch '^[=\-\s]*$' -and $str -notmatch '^\s*[A-Z_]+\s*$') {
                    $parts = $str -split '\s+'
                    $parts = $parts | Where-Object { $_ -ne "" }
                    if ($parts.Count -ge 3) {
                        $cid = $parts[0]
                        $cname = ($parts[1..($parts.Count-2)] -join " ").Trim()
                        $mac = $parts[-1]
                        $licenseStatus = 1
                        if ($licenseStatusByMac.ContainsKey($mac)) {
                            $licenseStatus = $licenseStatusByMac[$mac]
                        } else {
                            # Try to match MAC address without colons/dashes if not found
                            $macSimple = $mac -replace '[:-]', ''
                            foreach ($key in $licenseStatusByMac.Keys) {
                                if (($key -replace '[:-]', '') -eq $macSimple) {
                                    $licenseStatus = $licenseStatusByMac[$key]
                                    break
                                }
                            }
                        }
                        $creationDate = "N/A"
                        if ($cameraCreationByCamera.ContainsKey($cid)) {
                            $creationDate = $cameraCreationByCamera[$cid].CreationDate
                        }
                        $licenseStatusByCamera[$cid] = @{
                            CameraName = $cname
                            MacAddress = $mac
                            LicenseStatus = $licenseStatus
                            CreationDate = $creationDate
                        }
                    }
                }
            }
        } else {
            # No cameras result returned from database
        }

        # --- CONTINUOUS RECORDING STATUS ---
        $recordingStatusByCamera = @{}
        $recordingStatusQuery = @"
SELECT crs.CAMERA_ID,
       IIF(crs.IS_RECORDING, 1, 0) AS IS_RECORDING
FROM CAMERA_RECORDING_STATE crs
JOIN (
    SELECT CAMERA_ID, MAX(CREATED_TIME) AS MAX_TIME
    FROM CAMERA_RECORDING_STATE
    GROUP BY CAMERA_ID
) mx ON mx.CAMERA_ID = crs.CAMERA_ID AND mx.MAX_TIME = crs.CREATED_TIME;
"@
        $recordingStatusResult = Invoke-FirebirdQuery -Database "$TempDir\ACS.FDB" -Query $recordingStatusQuery
        if ($recordingStatusResult) {
            foreach ($line in $recordingStatusResult) {
                $str = $line.ToString()
                if ($str -match '^\s*(\d+)\s+(\d+)\s*$') {
                    $cid = $matches[1]
                    $status = [int]$matches[2]
                    $recordingStatusByCamera[$cid] = $status
                }
            }
        }

        # 6. Write metrics to export file
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
            $stopTicks = $lastStopTimes[$cid]
            $startTicks = $lastStartTimes[$cid]
            # Конвертируем ticks в Unix timestamp (секунды)
            $stopUnix = [long]($stopTicks / 10000000 - 62135596800)
            $startUnix = [long]($startTicks / 10000000 - 62135596800)
            
            # Проверяем, что timestamp'ы в разумных пределах (не слишком большие)
            $currentYear = [DateTime]::Now.Year
            $maxTimestamp = [long]([DateTime]::new($currentYear + 10, 1, 1) - [DateTime]::new(1970, 1, 1)).TotalSeconds
            
            if ($stopUnix -gt $maxTimestamp) {
                # Если STOP_TIME слишком большое, используем START_TIME + 1 час как приближение
                $stopUnix = $startUnix + 3600
            }
            
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

        # Storage used bytes per storage
        $metrics += "# HELP axis_camera_station_storage_used_bytes Storage used by storage in bytes"
        $metrics += "# TYPE axis_camera_station_storage_used_bytes gauge"
        foreach ($storageId in $storageByStorage.Keys) {
            $size = $storageByStorage[$storageId]
            $sname = $storageList[$storageId]
            if (-not $sname) { $sname = "Unknown" }
            $sname = $sname -replace '\\', '\\\\'
            $metrics += "axis_camera_station_storage_used_bytes{storage_id=`"$storageId`",storage_name=`"$sname`"} $size"
        }

        # Storage capacity metrics (total bytes per storage)
        $metrics += "# HELP axis_camera_station_storage_size_bytes Total capacity of storage in bytes"
        $metrics += "# TYPE axis_camera_station_storage_size_bytes gauge"
        foreach ($storageId in $storageCapacityByStorage.Keys) {
            $sizeCap = $storageCapacityByStorage[$storageId]
            $sname = $storageList[$storageId]
            if (-not $sname) { $sname = "Unknown" }
            $sname = $sname -replace '\\', '\\\\'
            $metrics += "axis_camera_station_storage_size_bytes{storage_id=`"$storageId`",storage_name=`"$sname`"} $sizeCap"
        }

        # Storage free bytes per storage
        $metrics += "# HELP axis_camera_station_storage_free_bytes Free space of storage in bytes"
        $metrics += "# TYPE axis_camera_station_storage_free_bytes gauge"
        foreach ($storageId in $storageFreeByStorage.Keys) {
            $free = $storageFreeByStorage[$storageId]
            $sname = $storageList[$storageId]
            if (-not $sname) { $sname = "Unknown" }
            $sname = $sname -replace '\\', '\\\\'
            $metrics += "axis_camera_station_storage_free_bytes{storage_id=`"$storageId`",storage_name=`"$sname`"} $free"
        }

        # Метрики по камерам (https_status)
        $metrics += "# HELP axis_camera_station_device_https_status HTTPS enabled status per camera"
        $metrics += "# TYPE axis_camera_station_device_https_status gauge"
        foreach ($cid in $httpsStatusByCamera.Keys) {
            $httpsData = $httpsStatusByCamera[$cid]
            $cname = $httpsData.CameraName
            $httpsValue = $httpsData.HttpsEnabled
            if ($cname) { $cname = $cname -replace '\\', '\\\\' }
            $metrics += "axis_camera_station_device_https_status{camera_id=`"$cid`",camera_name=`"$cname`"} $httpsValue"
        }

        # Метрики по камерам (license_status)
        $metrics += "# HELP axis_camera_station_device_license_status License status per camera (0=unlicensed, 1=licensed)"
        $metrics += "# TYPE axis_camera_station_device_license_status gauge"
        foreach ($cid in $licenseStatusByCamera.Keys) {
            $licenseData = $licenseStatusByCamera[$cid]
            if ($licenseData -is [hashtable]) {
                $cname = $licenseData.CameraName
                $licenseValue = $licenseData.LicenseStatus
                if ($cname) { $cname = $cname -replace '\\', '\\\\' }
                $metrics += "axis_camera_station_device_license_status{camera_id=`"$cid`",camera_name=`"$cname`"} $licenseValue"
            } else {
                # License data for camera $cid is not a hashtable: $($licenseData.GetType())
            }
        }

        # Метрики по камерам (ntp_dhcp_status)
        $metrics += "# HELP axis_camera_station_camera_ntp_dhcp_status NTP source DHCP status per camera (1=DHCP, 0=Static)"
        $metrics += "# TYPE axis_camera_station_camera_ntp_dhcp_status gauge"
        foreach ($cid in $cameraList.Keys) {
            $dhcpStatus = 0
            if ($ntpDhcpStatusByCamera.ContainsKey($cid)) {
                $dhcpStatus = $ntpDhcpStatusByCamera[$cid]
            }
            $cname = $cameraList[$cid]
            if ($cname) { $cname = $cname -replace '\\', '\\\\' }
            $metrics += "axis_camera_station_camera_ntp_dhcp_status{camera_id=`"$cid`",camera_name=`"$cname`"} $dhcpStatus"
        }

        # Метрики по камерам (creation_date)
        $metrics += "# HELP axis_camera_station_device_creation_date Camera creation date as Unix timestamp (seconds)"
        $metrics += "# TYPE axis_camera_station_device_creation_date gauge"
        foreach ($cid in $licenseStatusByCamera.Keys) {
            $licenseData = $licenseStatusByCamera[$cid]
            if ($licenseData -is [hashtable]) {
                $cname = $licenseData.CameraName
                $creationDate = $licenseData.CreationDate
                if ($cname) { $cname = $cname -replace '\\', '\\\\' }
                
                # Конвертируем дату в Unix timestamp
                $creationTimestamp = -1  # Значение по умолчанию для отсутствующих данных
                if ($creationDate -ne "N/A" -and $creationDate -match '^\d{4}-\d{2}-\d{2}$') {
                    try {
                        # Добавляем время 00:00:00 к дате и конвертируем в Unix timestamp
                        $dateTime = [DateTime]::ParseExact("$creationDate 00:00:00", "yyyy-MM-dd HH:mm:ss", $null)
                        $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, 0, [DateTimeKind]::Utc)
                        $creationTimestamp = [long]($dateTime.ToUniversalTime() - $epoch).TotalSeconds
                    }
                    catch {
                        # В случае ошибки парсинга оставляем -1
                        $creationTimestamp = -1
                    }
                } else {
                    # Creation date $creationDate is N/A or doesn't match format, using -1
                }
                
                $metrics += "axis_camera_station_device_creation_date{camera_id=`"$cid`",camera_name=`"$cname`"} $creationTimestamp"
            } else {
                # License data for camera $cid is not a hashtable: $($licenseData.GetType())
            }
        }

        # Метрики по камерам (continuous recording status)
        $metrics += "# HELP axis_camera_station_camera_continuous_recording_status Continuous recording status per camera (1=Recording, 0=Stopped)"
        $metrics += "# TYPE axis_camera_station_camera_continuous_recording_status gauge"
        foreach ($cid in $cameraList.Keys) {
            $status = 0
            if ($recordingStatusByCamera.ContainsKey($cid)) {
                $status = $recordingStatusByCamera[$cid]
            }
            $cname = $cameraList[$cid]
            if ($cname) { $cname = $cname -replace '\\', '\\\\' }
            $metrics += "axis_camera_station_camera_continuous_recording_status{camera_id=`"$cid`",camera_name=`"$cname`"} $status"
        }

        # Write to file
        $metrics | Out-File -FilePath $metricsFile -Encoding UTF8 -Force
    }
    catch {
        # Exception details: $($_.Exception.ToString())
        throw
    }
    finally {
        # Cleanup temp files
        Remove-TempFiles
    }
}

# Start monitoring
Start-AxisMonitoring