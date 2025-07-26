# Axis Camera Station Prometheus Metrics Generator
# Extracts camera data from Firebird DB, collects metrics via API, generates Prometheus file

param(
    [string]$SourceDatabase = "C:\ProgramData\Axis Communications\AXIS Camera Station Server\ACS.FDB",
    [string]$TempDir = "C:\temp\axis_monitoring",
    [string]$FirebirdPath = "C:\Program Files\Firebird\Firebird_3_0\isql.exe",
    [string]$OutputFile = "axis_camera_vapix_metrics.prom",
    [string]$CredentialFile = "C:\ProgramData\AxisCameraStation\camera_credentials.dat",
    [int]$MaxConcurrentPing = 100,
    [int]$MaxConcurrentMetrics = 50,
    [int]$PingTimeoutSeconds = 5,
    [int]$ApiTimeoutSeconds = 30
)

# --- Время выполнения скрипта ---
$script:scriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Early check for credential file
if (!(Test-Path $CredentialFile)) {
    Write-Host "ERROR: Credential file not found: $CredentialFile" -ForegroundColor Red
    Write-Host "Please run install_service.ps1 first to set up credentials" -ForegroundColor Yellow
    exit 1
}

# Load required assembly for Windows Data Protection API
try {
    Add-Type -AssemblyName System.Security
} catch {
    Write-Host "ERROR: Failed to load System.Security assembly: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Function to decrypt credentials using Windows Data Protection API
function Unprotect-Credentials {
    param(
        [byte[]]$EncryptedData
    )
    
    try {
        # Decrypt using Windows Data Protection API (LocalMachine for multi-user access)
        $decryptedBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $EncryptedData, 
            [System.Text.Encoding]::UTF8.GetBytes("AxisCameraStation"), 
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        
        # Convert back to string
        $jsonData = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
        
        # Convert back to object
        $credentialData = $jsonData | ConvertFrom-Json
        
        return $credentialData
    }
    catch {
        Write-Host "ERROR: Failed to decrypt credentials: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# Function to load credentials from encrypted file
function Load-CredentialsFromFile {
    param(
        [string]$FilePath
    )
    
    try {
        if (Test-Path $FilePath) {
            $encryptedBytes = [System.IO.File]::ReadAllBytes($FilePath)
            
            $credentialData = Unprotect-Credentials -EncryptedData $encryptedBytes
            
            if ($credentialData) {
                return @{
                    Username = $credentialData.Username
                    Password = $credentialData.Password
                    Created = $credentialData.Created
                    Success = $true
                }
            } else {
                return @{
                    Success = $false
                    Error = "Failed to decrypt credentials"
                }
            }
        } else {
            return @{
                Success = $false
                Error = "Credential file not found"
            }
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

# Функция для получения credentials из зашифрованного файла
function Get-CameraCredentials {
    $creds = Load-CredentialsFromFile -FilePath $CredentialFile
    if ($creds.Success) {
        return @{
            Username = $creds.Username
            Password = $creds.Password
        }
    } else {
        Write-Host "ERROR: Could not retrieve camera credentials from encrypted file" -ForegroundColor Red
        Write-Host "Please run install_service.ps1 first to set up credentials" -ForegroundColor Yellow
        exit 1
    }
}

# Helper function for debug logging (disabled by default)
function Add-DebugLog {
    param([string]$Message)
    # Debug logs disabled by default - uncomment the line below to enable
    # $script:debugLogs += $Message
}

# Создаем временную папку
if (!(Test-Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

# Функция для выполнения SQL запросов
function Invoke-FirebirdQuery {
    param(
        [string]$Database,
        [string]$Query
    )
    try {
        $tempSql = [System.IO.Path]::GetTempFileName()
        $sqlContent = @"
CONNECT '$Database' USER 'SYSDBA' PASSWORD 'masterkey';
$Query
EXIT;
"@
        Set-Content -Path $tempSql -Value $sqlContent -Encoding ASCII
        $output = & "$FirebirdPath" -i $tempSql 2>&1
        Remove-Item $tempSql -Force
        return $output
    }
    catch {
        Write-Host "ERROR: Failed to execute SQL query: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# Функция для параллельной проверки доступности камер
function Get-AvailableCameras {
    param(
        [array]$Cameras,
        [int]$MaxConcurrent = 10,
        [int]$PingCount = 2,
        [int]$TimeoutSeconds = 5
    )
    
    # Старт таймера для измерения производительности
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Шаг 1: Удаляем дублирующиеся hostname
    $groups = $Cameras | Group-Object { $_.Hostname }
    
    $uniqueCameras = @()
    foreach ($group in $groups) {
        $firstCamera = $group.Group[0]
        $newCamera = @{
            CameraID   = $firstCamera.CameraID
            CameraName = $firstCamera.CameraName
            Hostname   = $firstCamera.Hostname
        }
        $uniqueCameras += $newCamera
    }
    
    # Шаг 2: Используем .NET Ping.SendPingAsync для параллельной ICMP-проверки
    $availableCameras = @()

    for ($i = 0; $i -lt $uniqueCameras.Count; $i += $MaxConcurrent) {
        $batch = $uniqueCameras[$i..([math]::Min($i + $MaxConcurrent - 1, $uniqueCameras.Count - 1))]
        
        # Формируем задачи Ping
        $tasks = @()
        foreach ($cam in $batch) {
            if (-not $cam.Hostname -or $cam.Hostname -eq "") { continue }
            $pingObj = New-Object System.Net.NetworkInformation.Ping
            $tasks   += $pingObj.SendPingAsync($cam.Hostname, $TimeoutSeconds * 1000)
        }
        
        # Ожидание завершения всей пачки и обработка результатов
        if ($tasks.Count -gt 0) {
            [void][System.Threading.Tasks.Task]::WhenAll($tasks)
            for ($j = 0; $j -lt $tasks.Count; $j++) {
                $reply = $tasks[$j].Result
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $availableCameras += $batch[$j]
                }
            }
        }
    }
    
    # Останавливаем таймер и выводим время
    $sw.Stop()
    Write-Host ("Get-AvailableCameras executed in {0} ms" -f $sw.ElapsedMilliseconds) -ForegroundColor Cyan
    
    return $availableCameras
}

# Function to generate Prometheus metrics file
function Generate-PrometheusMetrics {
    param(
        [array]$Metrics
    )
    
    $promContent = @"
# Axis Camera Station VAPIX Metrics
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
# Total cameras: $($Metrics.Count)

# HELP axis_camera_station_vapix_camera_availability_status Camera reachability via ping (1=OK, 0=Not accessible)
# TYPE axis_camera_station_vapix_camera_availability_status gauge

# HELP axis_camera_station_vapix_api_auth_status Camera API authentication status (1=OK, 0=Auth failed)
# TYPE axis_camera_station_vapix_api_auth_status gauge

# HELP axis_camera_station_vapix_snmp_enabled SNMP enabled status (1=enabled, 0=disabled)
# TYPE axis_camera_station_vapix_snmp_enabled gauge

# HELP axis_camera_station_vapix_encryption_enabled SD card encryption feature enabled (1=enabled, 0=disabled)
# TYPE axis_camera_station_vapix_encryption_enabled gauge

# HELP axis_camera_station_vapix_disk_encrypted SD card currently encrypted (1=encrypted, 0=not encrypted)
# TYPE axis_camera_station_vapix_disk_encrypted gauge

# HELP axis_camera_station_vapix_sd_total_size_bytes SD card total size in bytes
# TYPE axis_camera_station_vapix_sd_total_size_bytes gauge

# HELP axis_camera_station_vapix_sd_free_size_bytes SD card free size in bytes
# TYPE axis_camera_station_vapix_sd_free_size_bytes gauge

# HELP axis_camera_station_vapix_sd_cleanup_level SD card cleanup level percentage
# TYPE axis_camera_station_vapix_sd_cleanup_level gauge

# HELP axis_camera_station_vapix_sd_max_age_hours SD card recordings maximum age in hours
# TYPE axis_camera_station_vapix_sd_max_age_hours gauge

# HELP axis_camera_station_vapix_sd_status_ok SD card status (1=OK, 0=Error)
# TYPE axis_camera_station_vapix_sd_status_ok gauge

# HELP axis_camera_station_vapix_sd_usage_percent SD card usage percentage
# TYPE axis_camera_station_vapix_sd_usage_percent gauge

# HELP axis_camera_station_vapix_sd_recordings_total Total recordings found on SD card
# TYPE axis_camera_station_vapix_sd_recordings_total gauge

# HELP axis_camera_station_vapix_request_success API request success flag (1=success, 0=failed)
# TYPE axis_camera_station_vapix_request_success gauge

# HELP axis_camera_station_vapix_ssh_status SSH service enabled status (1=enabled, 0=disabled)
# TYPE axis_camera_station_vapix_ssh_status gauge

# HELP axis_camera_station_vapix_VMD_status VMD (motion detection) running status (1=running, 0=stopped)
# TYPE axis_camera_station_vapix_VMD_status gauge

# HELP axis_camera_station_vapix_event_rules_count Number of event rules configured on camera
# TYPE axis_camera_station_vapix_event_rules_count gauge

# HELP axis_camera_station_vapix_syslog_enabled Remote syslog enabled status (1=enabled, 0=disabled)
# TYPE axis_camera_station_vapix_syslog_enabled gauge

# HELP axis_camera_station_vapix_firmware_version Firmware version label (value always 1)
# TYPE axis_camera_station_vapix_firmware_version gauge

# HELP axis_camera_station_vapix_camera_model Camera model label (value always 1)
# TYPE axis_camera_station_vapix_camera_model gauge

# HELP axis_camera_station_vapix_power_line_frequency_hz Power-line frequency setting in Hz
# TYPE axis_camera_station_vapix_power_line_frequency_hz gauge

"@
    
    foreach ($metric in $Metrics) {
        # Метрика доступности камеры (результат пинга)
        $availability = if ($metric.PingAvailable -eq 1) { 1 } else { 0 }
        $promContent += "axis_camera_station_vapix_camera_availability_status{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $availability`n"

        # API authentication metric
        $apiAuthVal = if ($metric.ApiAuthOK -eq 1) { 1 } else { 0 }
        $promContent += "axis_camera_station_vapix_api_auth_status{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $apiAuthVal`n"

        # SNMP enabled metric
        $snmpVal = if ($metric.SnmpEnabled -eq 1) { 1 } else { 0 }
        $promContent += "axis_camera_station_vapix_snmp_enabled{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $snmpVal`n"

        if ($metric.Success) {
            # Основные метрики шифрования
            $promContent += "axis_camera_station_vapix_encryption_enabled{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.EncryptionEnabled)`n"
            $promContent += "axis_camera_station_vapix_disk_encrypted{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.DiskEncrypted)`n"
            
            # Метрики размера SD карты
            if ($metric.TotalSize) {
                $promContent += "axis_camera_station_vapix_sd_total_size_bytes{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.TotalSize)`n"
            }
            if ($metric.FreeSize) {
                $promContent += "axis_camera_station_vapix_sd_free_size_bytes{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.FreeSize)`n"
            }
            
            # Метрики политики очистки
            if ($metric.CleanupLevel) {
                $promContent += "axis_camera_station_vapix_sd_cleanup_level{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.CleanupLevel)`n"
            }
            if ($metric.MaxAge) {
                $promContent += "axis_camera_station_vapix_sd_max_age_hours{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.MaxAge)`n"
            }
            
            # Метрика статуса диска
            $diskStatusValue = if ($metric.DiskStatus -eq "OK") { "1" } else { "0" }
            $promContent += "axis_camera_station_vapix_sd_status_ok{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $diskStatusValue`n"
            
            # Метрика использования диска (в процентах)
            if ($metric.TotalSize -and $metric.TotalSize -gt 0 -and $metric.FreeSize) {
                $usedSize = $metric.TotalSize - $metric.FreeSize
                $usagePercent = [math]::Round(($usedSize / $metric.TotalSize) * 100, 2)
                $promContent += "axis_camera_station_vapix_sd_usage_percent{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $usagePercent`n"
            }
            
            # Новая метрика: total recordings
            $recordingsValue = if ($metric.TotalRecordings) { $metric.TotalRecordings } else { 0 }
            $promContent += "axis_camera_station_vapix_sd_recordings_total{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $recordingsValue`n"
            
            # Метрика успешности запроса
            $promContent += "axis_camera_station_vapix_request_success{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} 1`n"

            # Если $metric.SshEnabled существует, добавить строку:
            if ($metric.SshEnabled -ne $null) {
                $promContent += "axis_camera_station_vapix_ssh_status{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.SshEnabled)`n"
            }

            # VMD status metric (always present)
            if ($metric.VmdStatus -ne $null) {
                $promContent += "axis_camera_station_vapix_VMD_status{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.VmdStatus)`n"
            }

            # Event Rules Count metric (always present)
            if ($metric.EventRulesCount -ne $null) {
                $promContent += "axis_camera_station_vapix_event_rules_count{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.EventRulesCount)`n"
            }

            # Syslog Enabled metric (always present)
            if ($metric.SyslogEnabled -ne $null) {
                $promContent += "axis_camera_station_vapix_syslog_enabled{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.SyslogEnabled)`n"
            }

            # Firmware Version metric (always present)
            if ($metric.FirmwareVersion -ne $null) {
                $promContent += "axis_camera_station_vapix_firmware_version{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`",firmware=`"$($metric.FirmwareVersion)`"} 1`n"
            }

            # Camera Model metric (always present)
            if ($metric.CameraModel -ne $null) {
                $promContent += "axis_camera_station_vapix_camera_model{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`",model=`"$($metric.CameraModel)`"} 1`n"
            }

            # Power Line Frequency metric (always present)
            if ($metric.PowerLineFrequency -ne $null) {
                $promContent += "axis_camera_station_vapix_power_line_frequency_hz{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.PowerLineFrequency)`n"
            }
        } else {
            # Метрика неуспешного запроса
            $promContent += "axis_camera_station_vapix_request_success{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} 0`n"
            
            # Новая метрика: total recordings = 0 при ошибке
            $promContent += "axis_camera_station_vapix_sd_recordings_total{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} 0`n"

            # Add SSH status if available (for failed cameras)
            if ($metric.SshEnabled -ne $null) {
                $promContent += "axis_camera_station_vapix_ssh_status{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.SshEnabled)`n"
            }

            # VMD status metric (always present, even for failed cameras)
            if ($metric.VmdStatus -ne $null) {
                $promContent += "axis_camera_station_vapix_VMD_status{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.VmdStatus)`n"
            }

            # Event Rules Count metric (always present, even for failed cameras)
            if ($metric.EventRulesCount -ne $null) {
                $promContent += "axis_camera_station_vapix_event_rules_count{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.EventRulesCount)`n"
            }

            # Syslog Enabled metric (always present, even for failed cameras)
            if ($metric.SyslogEnabled -ne $null) {
                $promContent += "axis_camera_station_vapix_syslog_enabled{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.SyslogEnabled)`n"
            }

            # Firmware Version metric (always present, even for failed cameras)
            if ($metric.FirmwareVersion -ne $null) {
                $promContent += "axis_camera_station_vapix_firmware_version{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`",firmware=`"$($metric.FirmwareVersion)`"} 1`n"
            }

            # Camera Model metric (always present, even for failed cameras)
            if ($metric.CameraModel -ne $null) {
                $promContent += "axis_camera_station_vapix_camera_model{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`",model=`"$($metric.CameraModel)`"} 1`n"
            }

            # Power Line Frequency metric (always present, even for failed cameras)
            if ($metric.PowerLineFrequency -ne $null) {
                $promContent += "axis_camera_station_vapix_power_line_frequency_hz{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.PowerLineFrequency)`n"
            }
        }
    }
    
    return $promContent
}

# Check if credentials are available
$testCreds = Load-CredentialsFromFile -FilePath $CredentialFile
if (-not $testCreds.Success) {
    Write-Host "ERROR: No camera credentials found in encrypted file" -ForegroundColor Red
    Write-Host "Please run install_service.ps1 first to set up credentials" -ForegroundColor Yellow
    exit 1
}

# Загружаем credentials один раз
$CameraUsername = $testCreds.Username
$CameraPassword = $testCreds.Password

# Копируем базу данных
$TempDatabase = "$TempDir\ACS.FDB"
Copy-Item $SourceDatabase $TempDatabase -Force

# Получаем данные камер с hostname
$cameraQuery = @"
SELECT c.ID as CAMERA_ID, c.NAME as CAMERA_NAME, d.HOSTNAME 
FROM CAMERA c 
JOIN DEVICE d ON c.DEVICE_ID = d.ID 
WHERE d.HOSTNAME IS NOT NULL 
ORDER BY c.ID;
"@
$cameraData = Invoke-FirebirdQuery -Database $TempDatabase -Query $cameraQuery

$cameras = @()
$isHeader = $true
$lineCount = 0

foreach ($line in $cameraData) {
    $lineCount++
    $lineStr = if ($line -eq $null) { "" } else { $line.ToString() }
    
    if ($lineStr.Trim() -eq "" -or $lineStr -match "^[=\-]+$") { 
        continue 
    }
    
    if ($isHeader) {
        if ($lineStr -match "CAMERA_ID.*CAMERA_NAME.*HOSTNAME") { 
            $isHeader = $false
        }
        continue
    }
    
    # Дополнительная проверка на разделители после заголовка
    if ($lineStr -match "^[=\-\s]+$") {
        continue
    }
    
    $fields = $lineStr -split '\s+'
    $fields = $fields | Where-Object { $_ -ne "" }
    
    if ($fields.Count -ge 3) {
        $cameraId = $fields[0]
        $hostname = $fields[-1]  # Последнее поле - hostname
        $cameraName = ($fields[1..($fields.Count-2)] -join " ").Trim()  # Все поля между ID и hostname
        
        if ($cameraId -match "^\d+$" -and $hostname -and $hostname -notmatch "^[=\-]+$") {
            $cameras += @{
                CameraID = $cameraId
                CameraName = $cameraName
                Hostname = $hostname
            }
        }
    }
}



# Получаем доступные камеры с параллельным ping
    $availableCameras = Get-AvailableCameras -Cameras $cameras -MaxConcurrent $MaxConcurrentPing -PingCount 1 -TimeoutSeconds $PingTimeoutSeconds

# Получаем метрики с доступных камер
$allMetrics = @()

for ($i = 0; $i -lt $availableCameras.Count; $i += $MaxConcurrentMetrics) {
    $batch = $availableCameras[$i..([math]::Min($i + $MaxConcurrentMetrics - 1, $availableCameras.Count - 1))]
    

    
    $batchJobs = @()
    $batchJobResults = @{}
    
                foreach ($camera in $batch) {
        if (-not $camera.Hostname -or $camera.Hostname -eq "") {
            continue
        }
        # ДО передачи в Start-Job
        $Hostname = $camera.Hostname
        $CameraID = $camera.CameraID
        $CameraName = $camera.CameraName
        $TimeoutSeconds = $ApiTimeoutSeconds
        $Username = $CameraUsername
        $Password = $CameraPassword

        $job = Start-Job -ScriptBlock {
            param($Hostname, $CameraID, $CameraName, $TimeoutSeconds, $Username, $Password)
            try {
                # Универсальный HTTP-запрос
                function Invoke-WebRequestSafe {
                    param($uri, $method = "GET", $body = $null, $headers = $null, $credentials = $null, $timeout = 30000)
                    try {
                        if ($method -eq "POST") {
                            $request = [System.Net.HttpWebRequest]::Create($uri)
                            $request.Method = "POST"
                            $request.ContentType = $headers["Content-Type"]
                            $request.Credentials = $credentials
                            $request.Timeout = $timeout
                            $request.AllowAutoRedirect = $true
                            $request.ServerCertificateValidationCallback = {$true}
                            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                            $request.ContentLength = $bytes.Length
                            $requestStream = $request.GetRequestStream()
                            $requestStream.Write($bytes, 0, $bytes.Length)
                            $requestStream.Close()
                            $response = $request.GetResponse()
                            $stream = $response.GetResponseStream()
                            $reader = New-Object System.IO.StreamReader($stream)
                            $result = $reader.ReadToEnd()
                            $reader.Close(); $stream.Close(); $response.Close()
                            return $result
                        } else {
                            $wc = New-Object System.Net.WebClient
                            if ($credentials) { $wc.Credentials = $credentials }
                            if ($headers) { $headers.Keys | ForEach-Object { $wc.Headers[$_] = $headers[$_] } }
                            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
                            $result = $wc.DownloadString($uri)
                            return $result
                        }
                    } catch {
                        return $null
                    }
                }
                function Parse-XmlSafe {
                    param($xmlString)
                    if ($null -eq $xmlString -or $xmlString -eq "") { return $null }
                    try { $xml = [xml]$xmlString; return $xml } catch { return $null }
                }
                function Parse-JsonSafe {
                    param($jsonString)
                    if ($null -eq $jsonString -or $jsonString -eq "") { return $null }
                    try { $json = $jsonString | ConvertFrom-Json; return $json } catch { return $null }
                }
                # Метрика SSH
                function Get-SshStatus {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    $uri = ("https://{0}:443/axis-cgi/ssh.cgi" -f $Hostname)
                    $body = '{"apiVersion":"1.0","method":"getSshInfo","params":{}}'
                    $headers = @{ "Content-Type" = "application/json" }
                    $resp = Invoke-WebRequestSafe -uri $uri -method "POST" -body $body -headers $headers -credentials $credentials -timeout ($TimeoutSeconds*1000)
                    $json = Parse-JsonSafe $resp
                    if ($json -and $json.data -and $json.data.PSObject.Properties["enabled"]) { return [int]($json.data.enabled) } else { return $null }
                }
                # Метрика VMD
                function Get-VmdStatus {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    $uri = ("https://{0}:443/axis-cgi/applications/list.cgi" -f $Hostname)
                    $resp = Invoke-WebRequestSafe -uri $uri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                    if ($resp) {
                        $vmdMatch = [regex]::Match($resp, 'Name="vmd"[^>]*Status="([^"]*)"')
                        if ($vmdMatch.Success) { return [int]($vmdMatch.Groups[1].Value -eq "Running") }
                        $vmdAltMatch = [regex]::Match($resp, 'Name="[^"]*Motion[^"]*"[^>]*Status="([^"]*)"')
                        if ($vmdAltMatch.Success) { return [int]($vmdAltMatch.Groups[1].Value -eq "Running") }
                    }
                    return 0
                }
                # Метрика Event Rules
                function GetEventRulesCount {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    $uri = ("https://{0}:443/vapix/services" -f $Hostname)
                    $soapEnvelope = @"
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:aa="http://www.axis.com/vapix/ws/action1">
  <soap:Body>
    <aa:GetActionRules/>
  </soap:Body>
</soap:Envelope>
"@
                    $headers = @{ "Content-Type" = 'application/soap+xml; action="http://www.axis.com/vapix/ws/action1/GetActionRules"; charset=utf-8' }
                    $resp = Invoke-WebRequestSafe -uri $uri -method "POST" -body $soapEnvelope -headers $headers -credentials $credentials -timeout ($TimeoutSeconds*1000)
                    $xml = Parse-XmlSafe $resp
                    if ($xml) {
                        $actionRules1 = $xml.GetElementsByTagName("ActionRule")
                        $actionRules2 = $xml.GetElementsByTagName("aa:ActionRule")
                        $count = [Math]::Max($actionRules1.Count, $actionRules2.Count)
                        return $count
                    } else {
                        $matches = [regex]::Matches($resp, '<.*?ActionRule.*?>')
                        return $matches.Count
                    }
                }
                
                # Метрика Syslog статус
                function Get-SyslogStatus {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    try {
                        # Правильный VAPIX API для Remote Syslog
                        $uri = ("https://{0}:443/axis-cgi/remotesyslog.cgi" -f $Hostname)
                        $jsonBody = '{"apiVersion":"1.0","method":"status"}'
                        $headers = @{ "Content-Type" = "application/json" }
                        
                        $resp = Invoke-WebRequestSafe -uri $uri -method "POST" -body $jsonBody -headers $headers -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($resp) {
                            $json = Parse-JsonSafe $resp
                            if ($json -and $json.data -and $json.data.PSObject.Properties["enabled"]) {
                                return [int]($json.data.enabled)
                            }
                        }
                    }
                    catch {
                        # Игнорируем ошибки API
                    }
                    
                    return 0
                }

                # Новая метрика: Camera Info (Firmware и Model)
                function Get-CameraInfo {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    
                    $firmwareVersion = "unknown"
                    $cameraModel = "unknown"
                    
                    try {
                        # Получаем Properties
                        $uri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=Properties" -f $Hostname)
                        $resp = Invoke-WebRequestSafe -uri $uri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($resp) {
                            # Извлекаем firmware
                            if ($resp -match "root\.Properties\.Firmware\.Version=([^\r\n]+)") {
                                $firmwareVersion = $Matches[1]
                            }
                            
                            # Извлекаем модель
                            if ($resp -match "root\.Properties\.System\.ProductNumber=([^\r\n]+)") {
                                $cameraModel = $Matches[1]
                            }
                        }
                        
                        # Fallback - получаем Brand информацию
                        $uri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=Brand" -f $Hostname)
                        $resp = Invoke-WebRequestSafe -uri $uri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($resp) {
                            # Если модель не найдена в Properties, пробуем Brand
                            if ($cameraModel -eq "unknown" -and $resp -match "root\.Brand\.ProdNbr=([^\r\n]+)") {
                                $cameraModel = $Matches[1]
                            }
                        }
                    }
                    catch {
                        # Игнорируем ошибки
                    }
                    
                    return @{
                        FirmwareVersion = $firmwareVersion
                        CameraModel = $cameraModel
                    }
                }

                # Новая метрика: Power Line Frequency
                function Get-PowerLineFrequency {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    
                    $powerLineFreq = 0
                    
                    try {
                        # Получаем ImageSource параметры
                        $uri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=ImageSource" -f $Hostname)
                        $resp = Invoke-WebRequestSafe -uri $uri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($resp) {
                            # Ищем CaptureFrequency в I0 (первое изображение)
                            if ($resp -match "root\.ImageSource\.I0\.CaptureFrequency=([^\r\n]+)") {
                                $fullValue = $Matches[1]
                                # Извлекаем только цифры (50 или 60)
                                if ($fullValue -match "(\d+)Hz") {
                                    $powerLineFreq = [int]$Matches[1]
                                }
                            }
                        }
                    }
                    catch {
                        # Игнорируем ошибки
                    }
                    
                    return $powerLineFreq
                }

                # Новая метрика: SNMP enabled
                function Get-SnmpEnabled {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    $uri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=SNMP" -f $Hostname)
                    $resp = Invoke-WebRequestSafe -uri $uri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                    if ($resp -and ($resp -match "root\.SNMP\.Enabled=(yes|no)")) {
                        return [int]($Matches[1] -eq "yes")
                    }
                    return 0
                }
                # Метрики SD-карты
                function GetSdMetrics {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    $uri = ("https://{0}:443/axis-cgi/disks/list.cgi?diskid=SD_DISK" -f $Hostname)
                    $resp = Invoke-WebRequestSafe -uri $uri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                    $encryptionEnabled = [regex]::Match($resp, 'encryptionenabled="([^"]*)"')
                    $diskEncrypted = [regex]::Match($resp, 'diskencrypted="([^"]*)"')
                    $totalSize = [regex]::Match($resp, 'totalsize="([^"]*)"')
                    $freeSize = [regex]::Match($resp, 'freesize="([^"]*)"')
                    $cleanupLevel = [regex]::Match($resp, 'cleanuplevel="([^"]*)"')
                    $maxAge = [regex]::Match($resp, 'cleanupmaxage="([^"]*)"')
                    $diskStatus = [regex]::Match($resp, 'status="([^"]*)"')
                    $filesystem = [regex]::Match($resp, 'filesystem="([^"]*)"')
                    if ($encryptionEnabled.Success) {
                        return @{
                            EncryptionEnabled = [int]($encryptionEnabled.Groups[1].Value -eq "true")
                            DiskEncrypted = [int]($diskEncrypted.Groups[1].Value -eq "true")
                            TotalSize = if ($totalSize.Success) { $totalSize.Groups[1].Value } else { $null }
                            FreeSize = if ($freeSize.Success) { $freeSize.Groups[1].Value } else { $null }
                            CleanupLevel = if ($cleanupLevel.Success) { $cleanupLevel.Groups[1].Value } else { $null }
                            MaxAge = if ($maxAge.Success) { $maxAge.Groups[1].Value } else { $null }
                            DiskStatus = if ($diskStatus.Success) { $diskStatus.Groups[1].Value } else { "unknown" }
                            Filesystem = if ($filesystem.Success) { $filesystem.Groups[1].Value } else { "unknown" }
                        }
                    } else {
                        return $null
                    }
                }
                function GetSdRecordingsCount {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    $uri = ("https://{0}:443/axis-cgi/record/list.cgi?maxnumberofresults=1&recordingid=all&diskid=SD_DISK" -f $Hostname)
                    $resp = Invoke-WebRequestSafe -uri $uri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                    $xml = Parse-XmlSafe $resp
                    if ($xml) {
                        $recordingsNode = $xml.SelectSingleNode("//recordings")
                        if ($recordingsNode -and $recordingsNode.Attributes["totalnumberofrecordings"]) {
                            $val = [int]$recordingsNode.Attributes["totalnumberofrecordings"].Value
                            return $val
                        }
                    }
                    return 0
                }
                # --- Сбор метрик ---
                $creds = New-Object System.Net.NetworkCredential($Username, $Password)
                $sshStatus = Get-SshStatus -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                $vmdStatus = Get-VmdStatus -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                $eventRulesCount = GetEventRulesCount -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                $syslogStatus = Get-SyslogStatus -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                $cameraInfo = Get-CameraInfo -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                $powerLineFreq = Get-PowerLineFrequency -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                $snmpEnabled = Get-SnmpEnabled -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                $sdMetrics = GetSdMetrics -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                # Определяем успешность API аутентификации: если хотя бы ответ от param.cgi распарсился
                $apiAuthOK = 1
                if (-not $cameraInfo -or ($cameraInfo.FirmwareVersion -eq "unknown" -and $cameraInfo.CameraModel -eq "unknown")) {
                    $apiAuthOK = 0
                }
                $totalRecordingsValue = GetSdRecordingsCount -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                if ($sdMetrics) {
                    $metricsObject = @{
                        CameraID = $CameraID
                        CameraName = $CameraName
                        Hostname = $Hostname
                        EncryptionEnabled = $sdMetrics.EncryptionEnabled
                        DiskEncrypted = $sdMetrics.DiskEncrypted
                        TotalSize = $sdMetrics.TotalSize
                        FreeSize = $sdMetrics.FreeSize
                        CleanupLevel = $sdMetrics.CleanupLevel
                        MaxAge = $sdMetrics.MaxAge
                        DiskStatus = $sdMetrics.DiskStatus
                        Filesystem = $sdMetrics.Filesystem
                        TotalRecordings = $totalRecordingsValue
                        EventRulesCount = $eventRulesCount
                        SyslogEnabled = $syslogStatus
                        FirmwareVersion = $cameraInfo.FirmwareVersion
                        CameraModel = $cameraInfo.CameraModel
                        PowerLineFrequency = $powerLineFreq
                        SnmpEnabled = $snmpEnabled
                        Success = $true
                        PingAvailable = 1
                        ApiAuthOK = $apiAuthOK
                    }
                    if ($sshStatus -ne $null) { $metricsObject.SshEnabled = $sshStatus }
                    $metricsObject.VmdStatus = $vmdStatus
                    return @($null, $metricsObject)
                } else {
                    $metricsObject = @{
                        CameraID = $CameraID
                        CameraName = $CameraName
                        Hostname = $Hostname
                        TotalRecordings = 0
                        EventRulesCount = $eventRulesCount
                        SyslogEnabled = $syslogStatus
                        FirmwareVersion = $cameraInfo.FirmwareVersion
                        CameraModel = $cameraInfo.CameraModel
                        PowerLineFrequency = $powerLineFreq
                        SnmpEnabled = $snmpEnabled
                        Success = $false
                        Error = "No SD card attributes found"
                        PingAvailable = 1
                        ApiAuthOK = $apiAuthOK
                    }
                    if ($sshStatus -ne $null) { $metricsObject.SshEnabled = $sshStatus }
                    $metricsObject.VmdStatus = $vmdStatus
                    return @($null, $metricsObject)
                }
            } catch {
                return @($null, $null)
            }
        } -ArgumentList $Hostname, $CameraID, $CameraName, $TimeoutSeconds, $Username, $Password
        
        $batchJobs += $job
        $batchJobResults[$camera.Hostname] = $camera
    }
    
    # Ждем завершения текущего batch
    $batchJobs | Wait-Job | Out-Null
    
    # Собираем результаты
    foreach ($job in $batchJobs) {
        $jobResult = Receive-Job -Job $job
        Remove-Job -Job $job
        if ($jobResult.Count -eq 2) {
            $debugLogs, $result = $jobResult
            $allMetrics += $result
        } else {
            # Write-Host "WARNING: Job did not return expected array of [debugLogs, result]!" -ForegroundColor Red
            $allMetrics += $jobResult
        }
    }
}

# Добавляем записи для камер, которые не ответили на ping
$allCameraIds = $cameras | ForEach-Object { $_.CameraID }
foreach ($cam in $cameras) {
    if (-not ($allMetrics | Where-Object { $_.CameraID -eq $cam.CameraID })) {
        $allMetrics += @{ 
            CameraID = $cam.CameraID;
            CameraName = $cam.CameraName;
            Hostname = $cam.Hostname;
            PingAvailable = 0;
            Success = $false 
            ApiAuthOK = 0
            SnmpEnabled = 0
        }
    }
}

# Генерируем Prometheus файл после того, как список $allMetrics полностью сформирован
$promContent = Generate-PrometheusMetrics -Metrics $allMetrics

# Сохраняем файл в C:\windows_exporter
$outputPath = Join-Path "C:\windows_exporter" $OutputFile
Set-Content -Path $outputPath -Value $promContent -Encoding UTF8

# Статистика
$successCount = ($allMetrics | Where-Object { $_.Success }).Count
$errorCount = ($allMetrics | Where-Object { -not $_.Success }).Count

## Suppress runtime warning output
# if ($errorCount -gt 0) {
#     Write-Host "WARNING: $errorCount camera(s) failed to respond" -ForegroundColor Yellow
# }

# Очистка временных файлов
if (Test-Path $TempDatabase) {
    Remove-Item $TempDatabase -Force
} 

# --- Вывод общего времени выполнения ---
$script:scriptStopwatch.Stop()
Write-Host ("Script completed in {0} seconds" -f ([math]::Round($script:scriptStopwatch.Elapsed.TotalSeconds,2))) -ForegroundColor Green 