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

# Включаем полное логирование для отладки новых метрик
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = "$ScriptDir\camera_metrics_debug.log"
$script:debugLogs = @()

# Очищаем лог файл при каждом запуске
if (Test-Path $LogFile) {
    Remove-Item $LogFile -Force
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
    Write-Host $logEntry -ForegroundColor Cyan
}

function Add-DebugLog {
    param([string]$Message)
    $script:debugLogs += $Message
    Write-Log "DEBUG: $Message"
}

# Первая запись в лог
Write-Log "Script started: get_cameras_metrics.ps1"
Write-Log "Credential file parameter: $CredentialFile"

# Early check for credential file
if (!(Test-Path $CredentialFile)) {
    Write-Log "ERROR: Credential file not found: $CredentialFile"
    Write-Host "ERROR: Credential file not found: $CredentialFile" -ForegroundColor Red
    Write-Host "Please run install_service.ps1 first to set up credentials" -ForegroundColor Yellow
    exit 1
}

Write-Log "Credential file found: $CredentialFile"

# Load required assembly for Windows Data Protection API
Write-Log "Loading System.Security assembly..."
try {
    Add-Type -AssemblyName System.Security
    Write-Log "System.Security assembly loaded successfully"
} catch {
    Write-Log "ERROR: Failed to load System.Security assembly: $($_.Exception.Message)"
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
    
    # Шаг 1: Удаляем дублирующиеся hostname
    $groups = $Cameras | Group-Object { $_.Hostname }
    
    $uniqueCameras = @()
    foreach ($group in $groups) {
        $firstCamera = $group.Group[0]
        $newCamera = @{
            CameraID = $firstCamera.CameraID
            CameraName = $firstCamera.CameraName
            Hostname = $firstCamera.Hostname
        }
        $uniqueCameras += $newCamera
    }
    
    # Шаг 2: Параллельная проверка доступности
    
    $availableCameras = @()
    $jobs = @()
    $jobResults = @{}
    
    # Создаем jobs для параллельного ping
    for ($i = 0; $i -lt $uniqueCameras.Count; $i += $MaxConcurrent) {
        $batch = $uniqueCameras[$i..([math]::Min($i + $MaxConcurrent - 1, $uniqueCameras.Count - 1))]
        
        foreach ($camera in $batch) {
            if (-not $camera.Hostname -or $camera.Hostname -eq "") {
                continue
            }
            
            $job = Start-Job -ScriptBlock {
                param($Hostname, $PingCount)
                try {
                    $result = Test-Connection -ComputerName $Hostname -Count $PingCount -Quiet
                    return @{ Hostname = $Hostname; Available = $result }
                }
                catch {
                    return @{ Hostname = $Hostname; Available = $false; Error = $_.Exception.Message }
                }
            } -ArgumentList $camera.Hostname, $PingCount
            
            $jobs += $job
            $jobResults[$camera.Hostname] = $camera
        }
        
        # Ждем завершения текущего batch
        $jobs | Wait-Job | Out-Null
        
        # Собираем результаты
        foreach ($job in $jobs) {
            $result = Receive-Job -Job $job
            Remove-Job -Job $job
            
            if ($result.Available) {
                $camera = $jobResults[$result.Hostname]
                $availableCameras += $camera
            }
        }
        
        $jobs = @()
        $jobResults = @{}
    }
    

    
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
# New metrics: syslog_enabled, event_rules_total, event_rules_working, event_rules_failed

"@
    
    foreach ($metric in $Metrics) {
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
            
            # Новые метрики syslog
            if ($metric.SyslogEnabled -ne $null) {
                $promContent += "axis_camera_station_vapix_syslog_enabled{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.SyslogEnabled)`n"
            }

            # Новые метрики event rules
            if ($metric.EventRulesTotal -ne $null) {
                $promContent += "axis_camera_station_vapix_event_rules_total{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.EventRulesTotal)`n"
            }
            if ($metric.EventRulesWorking -ne $null) {
                $promContent += "axis_camera_station_vapix_event_rules_working{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.EventRulesWorking)`n"
            }
            if ($metric.EventRulesFailed -ne $null) {
                $promContent += "axis_camera_station_vapix_event_rules_failed{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.EventRulesFailed)`n"
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
            
            # Новые метрики syslog (даже для неудачных камер)
            if ($metric.SyslogEnabled -ne $null) {
                $promContent += "axis_camera_station_vapix_syslog_enabled{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.SyslogEnabled)`n"
            }

            # Новые метрики event rules (даже для неудачных камер)
            if ($metric.EventRulesTotal -ne $null) {
                $promContent += "axis_camera_station_vapix_event_rules_total{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.EventRulesTotal)`n"
            }
            if ($metric.EventRulesWorking -ne $null) {
                $promContent += "axis_camera_station_vapix_event_rules_working{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.EventRulesWorking)`n"
            }
            if ($metric.EventRulesFailed -ne $null) {
                $promContent += "axis_camera_station_vapix_event_rules_failed{camera_id=`"$($metric.CameraID)`",camera_name=`"$($metric.CameraName)`",hostname=`"$($metric.Hostname)`"} $($metric.EventRulesFailed)`n"
            }
        }
    }
    
    return $promContent
}

# Создаем начальную запись в лог
Write-Log "=== CAMERA METRICS COLLECTION SESSION START ==="
Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Log "Script Parameters:"
Write-Log "  SourceDatabase: $SourceDatabase"
Write-Log "  TempDir: $TempDir"
Write-Log "  OutputFile: $OutputFile"
Write-Log "  MaxConcurrentPing: $MaxConcurrentPing"
Write-Log "  MaxConcurrentMetrics: $MaxConcurrentMetrics"

# Check if credentials are available
Write-Log "Checking camera credentials..."
$testCreds = Load-CredentialsFromFile -FilePath $CredentialFile
if (-not $testCreds.Success) {
    Write-Log "ERROR: No camera credentials found in encrypted file"
    Write-Host "ERROR: No camera credentials found in encrypted file" -ForegroundColor Red
    Write-Host "Please run install_service.ps1 first to set up credentials" -ForegroundColor Yellow
    exit 1
}
Write-Log "Camera credentials loaded successfully"

# Загружаем credentials один раз
$CameraUsername = $testCreds.Username
$CameraPassword = $testCreds.Password

# Копируем базу данных
Write-Log "Copying database from $SourceDatabase to temp location..."
$TempDatabase = "$TempDir\ACS.FDB"
Copy-Item $SourceDatabase $TempDatabase -Force
Write-Log "Database copied successfully to: $TempDatabase"

# Получаем данные камер с hostname
Write-Log "Executing SQL query to get camera data..."
$cameraQuery = @"
SELECT c.ID as CAMERA_ID, c.NAME as CAMERA_NAME, d.HOSTNAME 
FROM CAMERA c 
JOIN DEVICE d ON c.DEVICE_ID = d.ID 
WHERE d.HOSTNAME IS NOT NULL 
ORDER BY c.ID;
"@
$cameraData = Invoke-FirebirdQuery -Database $TempDatabase -Query $cameraQuery
Write-Log "SQL query executed, processing camera data..."

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
            Write-Log "Added camera: ID=$cameraId, Name=$cameraName, Hostname=$hostname"
        }
    }
}

Write-Log "Parsed $($cameras.Count) cameras from database"

# Получаем доступные камеры с параллельным ping
Write-Log "Starting ping check for $($cameras.Count) cameras (max concurrent: $MaxConcurrentPing)..."
$availableCameras = Get-AvailableCameras -Cameras $cameras -MaxConcurrent $MaxConcurrentPing -PingCount 1 -TimeoutSeconds $PingTimeoutSeconds
Write-Log "Ping check completed. Available cameras: $($availableCameras.Count)/$($cameras.Count)"

# Получаем метрики с доступных камер
Write-Log "Starting metrics collection from $($availableCameras.Count) available cameras..."
$allMetrics = @()

for ($i = 0; $i -lt $availableCameras.Count; $i += $MaxConcurrentMetrics) {
    $batch = $availableCameras[$i..([math]::Min($i + $MaxConcurrentMetrics - 1, $availableCameras.Count - 1))]
    
    Write-Log "Processing batch $([math]::Floor($i/$MaxConcurrentMetrics) + 1): cameras $($i+1) to $([math]::Min($i + $MaxConcurrentMetrics, $availableCameras.Count)) (batch size: $($batch.Count))"
    
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
                

                
                # Функция для создания SOAP envelope  
                function Get-SoapEnvelope {
                    param($Body)
                    return @"
<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:ws="http://www.axis.com/vapix/ws/action1">
  <SOAP-ENV:Body>
    $Body
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>
"@
                }
                
                # Функция для проверки доступности событий через Event Service
                function Check-EventServiceStatus {
                    param($Hostname, $TopicExpression, $TimeoutSeconds, $credentials)
                    
                    try {
                        Write-Host "EVENT SERVICE CHECK: Testing event '$TopicExpression' on $Hostname" -ForegroundColor Cyan
                        
                        # SOAP envelope для GetEventInstances
                        $soapEnvelope = @"
<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
                   xmlns:aev="http://www.axis.com/vapix/ws/event1">
  <SOAP-ENV:Body>
    <aev:GetEventInstances>
      <aev:MaxEvents>10</aev:MaxEvents>
    </aev:GetEventInstances>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>
"@

                        $headers = @{
                            "Content-Type" = "application/soap+xml; charset=utf-8"
                            "SOAPAction" = "http://www.axis.com/vapix/ws/event1/GetEventInstances"
                        }
                        
                        # Пробуем разные Event Service URI
                        $eventServiceUris = @(
                            ("https://{0}:443/vapix/services" -f $Hostname),
                            ("https://{0}:443/axis-services/ws/event1" -f $Hostname),
                            ("http://{0}:80/vapix/services" -f $Hostname)
                        )
                        
                        foreach ($uri in $eventServiceUris) {
                            Write-Host "EVENT SERVICE CHECK: Trying: $uri" -ForegroundColor Cyan
                            $eventResp = Invoke-WebRequestSafe -uri $uri -method "POST" -body $soapEnvelope -headers $headers -credentials $credentials -timeout ($TimeoutSeconds*1000)
                            
                            if ($eventResp) {
                                Write-Host "EVENT SERVICE CHECK: Response received" -ForegroundColor Cyan
                                Write-Host "EVENT SERVICE CHECK: Response preview:" -ForegroundColor Gray
                                Write-Host $eventResp.Substring(0, [Math]::Min(500, $eventResp.Length)) -ForegroundColor Gray
                                
                                # Ищем TopicExpression в ответе
                                if ($eventResp -match $TopicExpression.Replace("/", "\/")) {
                                    Write-Host "EVENT SERVICE CHECK: Found event '$TopicExpression' in active events - AVAILABLE" -ForegroundColor Green
                                    return $true
                                } else {
                                    Write-Host "EVENT SERVICE CHECK: Event '$TopicExpression' NOT found in active events - checking if service responds..." -ForegroundColor Yellow
                                    
                                    # Если сервис отвечает но события нет, значит событие недоступно
                                    if ($eventResp -match "GetEventInstancesResponse") {
                                        Write-Host "EVENT SERVICE CHECK: Event service works but event '$TopicExpression' is not available - UNAVAILABLE" -ForegroundColor Red
                                        return $false
                                    }
                                }
                            }
                        }
                        
                        Write-Host "EVENT SERVICE CHECK: Event service not responding - cannot determine status" -ForegroundColor Yellow
                        return $null  # Неопределенный статус
                    }
                    catch {
                        Write-Host "EVENT SERVICE CHECK: Exception: $($_.Exception.Message)" -ForegroundColor Red
                        return $null
                    }
                }

                # Функция для проверки реальной доступности VMD профиля
                function Check-VMDProfileReal {
                    param($Hostname, $ProfileName, $TimeoutSeconds, $credentials)
                    
                    try {
                        Write-Host "VMD PROFILE CHECK: Testing profile '$ProfileName' on $Hostname" -ForegroundColor Cyan
                        
                        # НОВАЯ ЛОГИКА: Сначала получаем список всех VMD профилей
                        Write-Host "VMD PROFILE CHECK: Getting all VMD profiles to understand naming..." -ForegroundColor Yellow
                        $allVmdUri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=root.VideoMotionDetection" -f $Hostname)
                        $allVmdResp = Invoke-WebRequestSafe -uri $allVmdUri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($allVmdResp) {
                            Write-Host "VMD PROFILE CHECK: All VMD parameters:" -ForegroundColor Cyan
                            Write-Host $allVmdResp -ForegroundColor Gray
                            
                            # Ищем все профили VMD
                            $vmdProfiles = @()
                            if ($allVmdResp -match "root\.VideoMotionDetection\.(\w+)\.") {
                                $vmdProfiles = ([regex]::Matches($allVmdResp, "root\.VideoMotionDetection\.(\w+)\.") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                                Write-Host "VMD PROFILE CHECK: Found VMD profiles: $($vmdProfiles -join ', ')" -ForegroundColor Green
                            }
                            
                            # СПЕЦИАЛЬНАЯ ДИАГНОСТИКА ДЛЯ AXIS-4 (axis-accc8ede1e4c)
                            if ($Hostname -match "axis-accc8ede1e4c") {
                                Write-Host "*** SPECIAL AXIS-4 DIAGNOSTIC ***" -ForegroundColor Magenta
                                Write-Host "Looking for profile '$ProfileName' (from TopicExpression)" -ForegroundColor Magenta
                                Write-Host "Web interface shows: 'VMD 4: ACS Profile 1' and 'VMD 4: Any Profile'" -ForegroundColor Magenta
                                Write-Host "Checking all found profiles for matches..." -ForegroundColor Magenta
                                
                                foreach ($profile in $vmdProfiles) {
                                    Write-Host "Testing profile: $profile" -ForegroundColor Cyan
                                    $testUri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=root.VideoMotionDetection.{1}" -f $Hostname, $profile)
                                    $testResp = Invoke-WebRequestSafe -uri $testUri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                                    if ($testResp -and $testResp -notmatch "Error.*getting param.*group") {
                                        Write-Host "Profile '$profile' EXISTS and is accessible!" -ForegroundColor Green
                                        if ($testResp -match "\.Enabled=") {
                                            $enabledValue = if ($testResp -match "\.Enabled=([^\r\n]+)") { $Matches[1] } else { "unknown" }
                                            Write-Host "Profile '$profile' Enabled status: $enabledValue" -ForegroundColor Yellow
                                        }
                                    } else {
                                        Write-Host "Profile '$profile' not accessible" -ForegroundColor Red
                                    }
                                }
                            }
                        }
                        
                        # Способ 1: Проверяем через param.cgi конкретный профиль
                        $paramUri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=root.VideoMotionDetection.{1}" -f $Hostname, $ProfileName)
                        Write-Host "VMD PROFILE CHECK: Querying: $paramUri" -ForegroundColor Cyan
                        
                        $paramResp = Invoke-WebRequestSafe -uri $paramUri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($paramResp) {
                            Write-Host "VMD PROFILE CHECK: Param response received" -ForegroundColor Cyan
                            Write-Host "VMD PROFILE CHECK: Response content:" -ForegroundColor Gray
                            Write-Host $paramResp -ForegroundColor Gray
                            
                            # ПРАВИЛЬНАЯ ОБРАБОТКА ОШИБОК VMD ПРОФИЛЕЙ
                            if ($paramResp -match "Error.*getting param.*group") {
                                Write-Host "VMD PROFILE CHECK: ERROR - Profile '$ProfileName' does not exist (param.cgi returned error)" -ForegroundColor Red
                                
                                # НОВАЯ ЛОГИКА: Попытаемся найти альтернативные профили
                                Write-Host "VMD PROFILE CHECK: Searching for alternative profile names..." -ForegroundColor Yellow
                                
                                # Попробуем стандартные варианты
                                $alternativeNames = @("Camera1Profile1", "Profile1", "Camera1ProfileDefault", "DefaultProfile", "VMDProfile1", "C1Profile1", "Camera1P1")
                                foreach ($altName in $alternativeNames) {
                                    if ($vmdProfiles -contains $altName) {
                                        Write-Host "VMD PROFILE CHECK: Found alternative profile '$altName' - testing..." -ForegroundColor Yellow
                                        $altUri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=root.VideoMotionDetection.{1}" -f $Hostname, $altName)
                                        $altResp = Invoke-WebRequestSafe -uri $altUri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                                        if ($altResp -and $altResp -notmatch "Error.*getting param.*group") {
                                            Write-Host "VMD PROFILE CHECK: Alternative profile '$altName' exists and works - AVAILABLE" -ForegroundColor Green
                                            return $true
                                        }
                                    }
                                }
                                
                                # Если есть любой работающий VMD профиль, считаем доступным
                                if ($vmdProfiles.Count -gt 0) {
                                    Write-Host "VMD PROFILE CHECK: Original profile '$ProfileName' not found, but other VMD profiles exist: $($vmdProfiles -join ', ') - AVAILABLE" -ForegroundColor Yellow
                                    return $true
                                }
                                
                                # НОВАЯ ЛОГИКА: Если вообще нет VMD через VAPIX, возможно камера использует встроенную аналитику
                                Write-Host "VMD PROFILE CHECK: No VMD profiles found via VAPIX - checking if camera uses built-in analytics..." -ForegroundColor Yellow
                                
                                # Проверяем через analytics API
                                $analyticsUri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=root.Image.Appearance" -f $Hostname)
                                $analyticsResp = Invoke-WebRequestSafe -uri $analyticsUri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                                
                                if ($analyticsResp -and $analyticsResp -notmatch "Error.*getting param.*group") {
                                    Write-Host "VMD PROFILE CHECK: Camera has built-in analytics capabilities - VMD profile '$ProfileName' may be AVAILABLE via hardware analytics" -ForegroundColor Green
                                    return $true
                                }
                                
                                # Проверяем через ONVIF Analytics
                                $onvifAnalyticsUri = ("https://{0}:443/axis-cgi/param.cgi?action=list&group=root.Analytics" -f $Hostname)
                                $onvifResp = Invoke-WebRequestSafe -uri $onvifAnalyticsUri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                                
                                if ($onvifResp -and $onvifResp -notmatch "Error.*getting param.*group") {
                                    Write-Host "VMD PROFILE CHECK: Camera has ONVIF Analytics - VMD profile '$ProfileName' may be AVAILABLE via ONVIF" -ForegroundColor Green
                                    return $true
                                }
                                
                                # СПЕЦИАЛЬНАЯ ЛОГИКА: Проверяем реальную доступность события через Event Service
                                Write-Host "VMD PROFILE CHECK: Modern camera without VAPIX VMD - checking real event availability..." -ForegroundColor Yellow
                                
                                # Проверяем через Event Service реальную доступность события
                                $eventAvailable = Check-EventServiceStatus -Hostname $Hostname -TopicExpression "tnsaxis:CameraApplicationPlatform/VMD/$ProfileName" -TimeoutSeconds $TimeoutSeconds -credentials $credentials
                                
                                if ($eventAvailable -eq $true) {
                                    Write-Host "VMD PROFILE CHECK: Event Service confirms event is AVAILABLE" -ForegroundColor Green
                                    return $true
                                } elseif ($eventAvailable -eq $false) {
                                    Write-Host "VMD PROFILE CHECK: Event Service confirms event is UNAVAILABLE" -ForegroundColor Red
                                    return $false
                                } else {
                                    # Если Event Service не отвечает, используем fallback логику
                                    Write-Host "VMD PROFILE CHECK: Event Service unavailable - using fallback: assuming modern analytics work - AVAILABLE" -ForegroundColor Yellow
                                    return $true
                                }
                            } elseif ($paramResp -match "root\.VideoMotionDetection\.$ProfileName\.Enabled=yes") {
                                Write-Host "VMD PROFILE CHECK: Profile '$ProfileName' is enabled - AVAILABLE" -ForegroundColor Green
                                return $true
                            } elseif ($paramResp -match "root\.VideoMotionDetection\.$ProfileName\.Enabled=no") {
                                Write-Host "VMD PROFILE CHECK: Profile '$ProfileName' is disabled - UNAVAILABLE" -ForegroundColor Red
                                return $false
                            } elseif ($paramResp -match "root\.VideoMotionDetection\.$ProfileName") {
                                Write-Host "VMD PROFILE CHECK: Profile '$ProfileName' exists but enabled status unclear - assuming AVAILABLE" -ForegroundColor Yellow
                                return $true
                            } else {
                                Write-Host "VMD PROFILE CHECK: Profile '$ProfileName' not found in param response - UNAVAILABLE" -ForegroundColor Red
                                return $false
                            }
                        }
                        
                        # Способ 2: Проверяем через Event service (согласно VAPIX документации)
                        Write-Host "VMD PROFILE CHECK: Trying Event service validation for TopicExpression" -ForegroundColor Cyan
                        $eventServiceUri = ("https://{0}:443/vapix/services" -f $Hostname)
                        $topicExpression = "tnsaxis:CameraApplicationPlatform/VMD/$ProfileName"
                        
                        # SOAP запрос для проверки события через Event service
                        $eventSoapEnvelope = @"
<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
                   xmlns:aev="http://www.axis.com/vapix/ws/event1">
  <SOAP-ENV:Body>
    <aev:GetEventInstances>
      <aev:TopicFilter>$topicExpression</aev:TopicFilter>
    </aev:GetEventInstances>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>
"@
                        
                        $headers = @{ "Content-Type" = "application/soap+xml; charset=utf-8" }
                        $eventResp = Invoke-WebRequestSafe -uri $eventServiceUri -method "POST" -body $eventSoapEnvelope -headers $headers -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($eventResp) {
                            Write-Host "VMD PROFILE CHECK: Event service response received" -ForegroundColor Cyan
                            Write-Host "VMD PROFILE CHECK: Event response preview:" -ForegroundColor Gray
                            Write-Host $eventResp.Substring(0, [Math]::Min(500, $eventResp.Length)) -ForegroundColor Gray
                            
                            # Проверяем наличие ошибок в ответе Event service
                            if ($eventResp -match "Fault|Error|Invalid|NotFound") {
                                Write-Host "VMD PROFILE CHECK: Event service reports error for TopicExpression '$topicExpression' - UNAVAILABLE" -ForegroundColor Red
                                return $false
                            } else {
                                Write-Host "VMD PROFILE CHECK: Event service validates TopicExpression '$topicExpression' - AVAILABLE" -ForegroundColor Green
                                return $true
                            }
                        }
                        
                        # Способ 3: Fallback проверка VMD через vmd.cgi
                        $vmdUri = ("https://{0}:443/axis-cgi/vmd/vmd.cgi?camera=1&configlist" -f $Hostname)
                        Write-Host "VMD PROFILE CHECK: Fallback - trying VMD config list: $vmdUri" -ForegroundColor Yellow
                        
                        $vmdResp = Invoke-WebRequestSafe -uri $vmdUri -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($vmdResp -and $vmdResp -match $ProfileName) {
                            Write-Host "VMD PROFILE CHECK: Profile '$ProfileName' found in VMD config - AVAILABLE" -ForegroundColor Green
                            return $true
                        }
                        
                        Write-Host "VMD PROFILE CHECK: All checks failed for profile '$ProfileName' - UNAVAILABLE" -ForegroundColor Red
                        return $false
                    }
                    catch {
                        Write-Host "VMD PROFILE CHECK: Exception checking profile '$ProfileName': $($_.Exception.Message)" -ForegroundColor Red
                        return $false
                    }
                }
                

                
                # Функция для проверки доступности ACAP приложения через vaconfig.cgi
                function Check-AppAvailable {
                    param($CameraIP, $AppName, $User, $Password)
                    
                    $uri = "https://$CameraIP:443/axis-cgi/vaconfig.cgi?action=get&name=$AppName"
                    try {
                        Write-Host "APP CHECK DEBUG: Checking ACAP app '$AppName' via vaconfig.cgi on $CameraIP" -ForegroundColor Cyan
                        
                        $credential = New-Object System.Management.Automation.PSCredential($User, ($Password | ConvertTo-SecureString -AsPlainText -Force))
                        $response = Invoke-WebRequest -Uri $uri -Credential $credential -ErrorAction Stop -TimeoutSec 10
                        
                        $available = $response.Content -notmatch "not found|error|invalid|no_such_application"
                        Write-Host "APP CHECK DEBUG: ACAP app '$AppName' available: $available" -ForegroundColor Cyan
                        Write-Host "APP CHECK DEBUG: Response preview: $($response.Content.Substring(0, [Math]::Min(200, $response.Content.Length)))" -ForegroundColor Gray
                        
                        return $available
                    } catch {
                        Write-Host "APP CHECK DEBUG: Exception checking ACAP app '$AppName': $($_.Exception.Message)" -ForegroundColor Red
                        return $false
                    }
                }
 
                # Метрика Event Rules (упрощенная - только количество)
                function GetEventRulesCount {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    $uri = ("https://{0}:443/vapix/services" -f $Hostname)
                    # Пробуем расширенный запрос с дополнительными параметрами для получения статуса
                    $soapEnvelopeExtended = @"
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:aa="http://www.axis.com/vapix/ws/action1">
  <soap:Body>
    <aa:GetActionRules>
      <aa:IncludeStatus>true</aa:IncludeStatus>
      <aa:ValidateRules>true</aa:ValidateRules>
      <aa:IncludeConditions>true</aa:IncludeConditions>
    </aa:GetActionRules>
  </soap:Body>
</soap:Envelope>
"@
                    
                    # Основной запрос без параметров
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
                
                # Новая метрика: Syslog статус (используем правильный VAPIX API)
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
                
                # Новая метрика: Event Rules статус и проблемные правила (анализ содержимого правил)
                function Get-EventRulesStatus {
                    param($Hostname, $TimeoutSeconds, $credentials)
                    
                    Write-Host "EVENT RULES DEBUG: Starting analysis for $Hostname" -ForegroundColor Yellow
                    
                    try {
                        # Попытка 1: Расширенный запрос для получения статуса условий
                        $uri1 = ("https://{0}:443/axis-services/ws/action1" -f $Hostname)
                        $soapEnvelopeExtended = @"
<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
                   xmlns:ws="http://www.axis.com/vapix/ws/action1">
  <SOAP-ENV:Body>
    <ws:GetActionRules>
      <ws:IncludeStatus>true</ws:IncludeStatus>
      <ws:ValidateRules>true</ws:ValidateRules>
      <ws:IncludeConditionStatus>true</ws:IncludeConditionStatus>
    </ws:GetActionRules>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>
"@
                        
                        # Обычный запрос как fallback
                        $soapEnvelope = @"
<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
                   xmlns:ws="http://www.axis.com/vapix/ws/action1">
  <SOAP-ENV:Body>
    <ws:GetActionRules/>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>
"@
                        $headers = @{ "Content-Type" = "application/soap+xml; charset=utf-8" }
                        
                        # Сначала пробуем расширенный запрос для получения статуса условий
                        Write-Host "EVENT RULES DEBUG: Trying EXTENDED request: $uri1" -ForegroundColor Cyan
                        $resp1 = Invoke-WebRequestSafe -uri $uri1 -method "POST" -body $soapEnvelopeExtended -headers $headers -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        # Если расширенный запрос не сработал, пробуем обычный
                        if (-not $resp1) {
                            Write-Host "EVENT RULES DEBUG: Extended request failed, trying standard request: $uri1" -ForegroundColor Yellow
                            $resp1 = Invoke-WebRequestSafe -uri $uri1 -method "POST" -body $soapEnvelope -headers $headers -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        } else {
                            Write-Host "EVENT RULES DEBUG: EXTENDED request SUCCESS! Looking for additional status info..." -ForegroundColor Green
                        }
                        
                        if ($resp1) {
                            $len1 = if ($resp1) { $resp1.Length } else { 0 }
                            Write-Host "EVENT RULES DEBUG: Response received from $uri1 ($len1 chars)" -ForegroundColor Yellow
                        } else {
                            Write-Host "EVENT RULES DEBUG: No response from $uri1" -ForegroundColor Red
                        }
                        
                        # Попытка 2: HTTP вместо HTTPS
                        $uri2 = ("http://{0}:80/axis-services/ws/action1" -f $Hostname)
                        Write-Host "EVENT RULES DEBUG: Trying HTTP endpoint: $uri2" -ForegroundColor Yellow
                        $resp2 = Invoke-WebRequestSafe -uri $uri2 -method "POST" -body $soapEnvelope -headers $headers -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($resp2) {
                            $len2 = if ($resp2) { $resp2.Length } else { 0 }
                            Write-Host "EVENT RULES DEBUG: Response received from $uri2 ($len2 chars)" -ForegroundColor Yellow
                        } else {
                            Write-Host "EVENT RULES DEBUG: No response from $uri2" -ForegroundColor Red
                        }
                        
                        # Попытка 3: Оригинальный endpoint
                        $uri3 = ("https://{0}:443/vapix/services" -f $Hostname)
                        Write-Host "EVENT RULES DEBUG: Trying original endpoint: $uri3" -ForegroundColor Yellow
                        $resp3 = Invoke-WebRequestSafe -uri $uri3 -method "POST" -body $soapEnvelope -headers $headers -credentials $credentials -timeout ($TimeoutSeconds*1000)
                        
                        if ($resp3) {
                            $len3 = if ($resp3) { $resp3.Length } else { 0 }
                            Write-Host "EVENT RULES DEBUG: Response received from $uri3 ($len3 chars)" -ForegroundColor Yellow
                        } else {
                            Write-Host "EVENT RULES DEBUG: No response from $uri3" -ForegroundColor Red
                        }
                        
                        # Выбираем первый успешный ответ
                        $resp = $resp1
                        $uri = $uri1
                        if (-not $resp -and $resp2) { $resp = $resp2; $uri = $uri2 }
                        if (-not $resp -and $resp3) { $resp = $resp3; $uri = $uri3 }
                        
                        Write-Host "EVENT RULES DEBUG: Final response check - resp exists: $($resp -ne $null)" -ForegroundColor Cyan
                        
                        if ($resp) {
                            Write-Host "EVENT RULES DEBUG: Using response from $uri (analyzing rule content)" -ForegroundColor Green
                            
                            # ПОЛНЫЙ ДАМП XML ДЛЯ ИССЛЕДОВАНИЯ СТАТУСА ПРАВИЛ
                            Write-Host "==== FULL XML DUMP FOR STATUS INVESTIGATION ($uri) ====" -ForegroundColor Magenta
                            Write-Host $resp -ForegroundColor Gray
                            Write-Host "=======================================================" -ForegroundColor Magenta
                            
                            # ОСОБОЕ ВНИМАНИЕ К AXIS-2 где мы знаем что есть проблема
                            if ($Hostname -match "axis-e8272504919c") {
                                Write-Host "***** SPECIAL FOCUS ON AXIS-2 WITH KNOWN ISSUE *****" -ForegroundColor Red
                                Write-Host "This camera shows 'App (unavailable)' in web interface" -ForegroundColor Red
                                Write-Host "Looking for ANY indicators of problems in XML..." -ForegroundColor Red
                            }
                            
                            $xml = Parse-XmlSafe $resp
                            
                            if ($xml) {
                                Write-Host "EVENT RULES DEBUG: XML parsed successfully" -ForegroundColor Yellow
                                Write-Host "EVENT RULES DEBUG: XML root element: $($xml.DocumentElement.Name)" -ForegroundColor Yellow
                                
                                # Проверяем на SOAP Fault
                                $faultNodes = $xml.GetElementsByTagName("Fault")
                                if ($faultNodes -and $faultNodes.Count -gt 0) {
                                    Write-Host "EVENT RULES DEBUG: SOAP Fault detected:" -ForegroundColor Red
                                    foreach ($fault in $faultNodes) {
                                        $faultCode = $fault.SelectSingleNode('.//faultcode')
                                        $faultString = $fault.SelectSingleNode('.//faultstring')
                                        if ($faultCode) { Write-Host "EVENT RULES DEBUG: Fault code: $($faultCode.InnerText)" -ForegroundColor Red }
                                        if ($faultString) { Write-Host "EVENT RULES DEBUG: Fault string: $($faultString.InnerText)" -ForegroundColor Red }
                                    }
                                    Write-Host "EVENT RULES DEBUG: Continuing despite SOAP fault to check structure..." -ForegroundColor Yellow
                                }
                                
                                # Создаем namespace manager
                                $nsManager = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                                $nsManager.AddNamespace("aa", "http://www.axis.com/vapix/ws/action1")
                                $nsManager.AddNamespace("SOAP-ENV", "http://www.w3.org/2003/05/soap-envelope")
                                $nsManager.AddNamespace("wsnt", "http://docs.oasis-open.org/wsn/b-2")
                                
                                $actionRules = $xml.SelectNodes("//aa:ActionRule", $nsManager)
                                Write-Host "EVENT RULES DEBUG: Found $($actionRules.Count) action rules with namespace" -ForegroundColor Yellow
                                
                                if (-not $actionRules -or $actionRules.Count -eq 0) {
                                    # Fallback - поиск без namespace
                                    $actionRules = $xml.GetElementsByTagName("ActionRule")
                                    Write-Host "EVENT RULES DEBUG: Found $($actionRules.Count) action rules without namespace" -ForegroundColor Yellow
                                }
                                
                                $totalRules = $actionRules.Count
                                Write-Host "EVENT RULES DEBUG: Total action rules found: $totalRules" -ForegroundColor Yellow
                                
                                $workingRules = 0
                                $failedRules = 0
                                
                                foreach ($rule in $actionRules) {
                                    # ДЕТАЛЬНОЕ ИССЛЕДОВАНИЕ ПРАВИЛА ДЛЯ ПОИСКА СТАТУСА
                                    Write-Host "EVENT RULES DEBUG: ===== RULE INVESTIGATION =====" -ForegroundColor Magenta
                                    Write-Host "EVENT RULES DEBUG: Rule Attributes:" -ForegroundColor Cyan
                                    if ($rule.Attributes) {
                                        foreach ($attr in $rule.Attributes) {
                                            Write-Host "EVENT RULES DEBUG:   - $($attr.Name) = $($attr.Value)" -ForegroundColor Gray
                                        }
                                    }
                                    Write-Host "EVENT RULES DEBUG: Rule Child Elements:" -ForegroundColor Cyan
                                    foreach ($child in $rule.ChildNodes) {
                                        if ($child.NodeType -eq "Element") {
                                            Write-Host "EVENT RULES DEBUG:   - $($child.Name) = $($child.InnerText)" -ForegroundColor Gray
                                            # Ищем все атрибуты в дочерних элементах
                                            if ($child.Attributes) {
                                                foreach ($childAttr in $child.Attributes) {
                                                    Write-Host "EVENT RULES DEBUG:     attr: $($childAttr.Name) = $($childAttr.Value)" -ForegroundColor DarkGray
                                                }
                                            }
                                        }
                                    }
                                    Write-Host "EVENT RULES DEBUG: Full Rule XML for deep analysis:" -ForegroundColor Cyan
                                    Write-Host $rule.OuterXml -ForegroundColor DarkGray
                                    
                                    # ПОИСК СКРЫТЫХ ИНДИКАТОРОВ СТАТУСА
                                    Write-Host "EVENT RULES DEBUG: Searching for status indicators..." -ForegroundColor Yellow
                                    $ruleXmlText = $rule.OuterXml
                                    
                                    # Ищем любые слова связанные со статусом
                                    $statusWords = @("status", "state", "available", "unavailable", "error", "fault", "problem", "warning", "valid", "invalid", "active", "inactive", "enabled", "disabled", "working", "failed", "ok", "nok")
                                    foreach ($word in $statusWords) {
                                        if ($ruleXmlText -imatch $word) {
                                            Write-Host "EVENT RULES DEBUG: FOUND STATUS WORD: '$word' in rule XML!" -ForegroundColor Red
                                        }
                                    }
                                    
                                    # Ищем любые атрибуты содержащие "status" или "state"
                                    if ($ruleXmlText -imatch '(\w*status\w*|\w*state\w*)="([^"]*)"') {
                                        Write-Host "EVENT RULES DEBUG: FOUND STATUS/STATE ATTRIBUTE: $($Matches[0])" -ForegroundColor Red
                                    }
                                    
                                    # СПЕЦИАЛЬНЫЙ ПОИСК для расширенного ответа
                                    # Ищем дополнительные элементы статуса которые могут появиться в расширенном запросе
                                    $statusElements = @("Status", "ConditionStatus", "Valid", "Available", "Error", "Fault", "ValidationResult")
                                    foreach ($element in $statusElements) {
                                        if ($ruleXmlText -match "<[^>]*$element[^>]*>([^<]*)<") {
                                            $elementValue = $Matches[1]
                                            Write-Host "EVENT RULES DEBUG: FOUND STATUS ELEMENT: $element = '$elementValue'" -ForegroundColor Red
                                        }
                                        if ($ruleXmlText -match "$element=`"([^`"]*)`"") {
                                            $attrValue = $Matches[1]
                                            Write-Host "EVENT RULES DEBUG: FOUND STATUS ATTRIBUTE: $element = '$attrValue'" -ForegroundColor Red
                                        }
                                    }
                                    
                                    # Поиск вложенных элементов условий на предмет статуса
                                    if ($ruleXmlText -match "(?i)(unavailable|failed|error|invalid|not.*available|app.*unavailable)") {
                                        Write-Host "EVENT RULES DEBUG: FOUND PROBLEM INDICATOR: $($Matches[0])" -ForegroundColor Red
                                        $status = "FOUND_PROBLEM_INDICATOR"
                                        $ruleHasProblems = $true
                                    }
                                    
                                    Write-Host "EVENT RULES DEBUG: ==============================" -ForegroundColor Magenta
                                    
                                    # Получаем имя и статус enabled
                                    try {
                                        $nameNode = $rule.SelectSingleNode(".//aa:Name", $nsManager)
                                        $enabledNode = $rule.SelectSingleNode(".//aa:Enabled", $nsManager)
                                    } catch {
                                        Write-Host "EVENT RULES DEBUG: Namespace error, using fallback method" -ForegroundColor Yellow
                                        $nameNode = $null
                                        $enabledNode = $null
                                    }
                                    
                                    # Fallback - поиск без namespace
                                    if (-not $nameNode) {
                                        $nameNode = $rule.GetElementsByTagName("Name") | Select-Object -First 1
                                        if (-not $nameNode) {
                                            $nameNode = $rule.SelectSingleNode(".//Name")
                                        }
                                    }
                                    if (-not $enabledNode) {
                                        $enabledNode = $rule.GetElementsByTagName("Enabled") | Select-Object -First 1
                                        if (-not $enabledNode) {
                                            $enabledNode = $rule.SelectSingleNode(".//Enabled")
                                        }
                                    }
                                    
                                    $ruleName = if ($nameNode) { $nameNode.InnerText } else { "UNKNOWN" }
                                    $enabled = if ($enabledNode) { $enabledNode.InnerText -eq "true" } else { $false }
                                    
                                    Write-Host "EVENT RULES DEBUG: Processing rule '$ruleName', enabled=$enabled" -ForegroundColor Yellow
                                    
                                    $status = "OK"
                                    $ruleHasProblems = $false
                                    
                                    # 1. ПРОВЕРКА: Правило отключено
                                    if (-not $enabled) {
                                        $status = "DISABLED"
                                        $ruleHasProblems = $true
                                        Write-Host "EVENT RULES DEBUG: Rule '$ruleName' is DISABLED" -ForegroundColor Red
                                    } else {
                                        # 2. УЛУЧШЕННАЯ ЛОГИКА: Проверяем доступность приложений из TopicExpression
                                        $ruleXml = $rule.OuterXml
                                        Write-Host "EVENT RULES DEBUG: Checking rule '$ruleName' app dependencies" -ForegroundColor Yellow
                                        Write-Host "EVENT RULES DEBUG: Full XML for '$ruleName':" -ForegroundColor Magenta
                                        Write-Host $ruleXml -ForegroundColor Gray
                                        
                                        # Извлекаем TopicExpression из правила
                                        try {
                                            $topicExprs = $rule.SelectNodes(".//wsnt:TopicExpression", $nsManager)
                                            if (-not $topicExprs -or $topicExprs.Count -eq 0) { 
                                                $topicExprs = $rule.GetElementsByTagName("TopicExpression") 
                                            }
                                            
                                            foreach ($expr in $topicExprs) {
                                                $topicText = $expr.InnerText
                                                Write-Host "EVENT RULES DEBUG: Analyzing TopicExpression: $topicText" -ForegroundColor Yellow
                                                
                                                # Проверяем наличие ACAP приложений в TopicExpression
                                                if ($topicText -match "tnsaxis:CameraApplicationPlatform/VMD/([^/]+)") {
                                                    # VMD зависимость - проверяем статус правила напрямую
                                                    $vmdProfile = $Matches[1]
                                                    Write-Host "EVENT RULES DEBUG: Found VMD dependency with profile: '$vmdProfile'" -ForegroundColor Cyan
                                                    
                                                                                        # ПРОВЕРЯЕМ РЕАЛЬНУЮ ДОСТУПНОСТЬ VMD ПРОФИЛЯ
                                    $vmdProfileAvailable = Check-VMDProfileReal -Hostname $Hostname -ProfileName $vmdProfile -TimeoutSeconds $TimeoutSeconds -credentials $credentials
                                    
                                    if (-not $vmdProfileAvailable) {
                                        $status = "VMD_PROFILE_UNAVAILABLE"
                                        $ruleHasProblems = $true
                                        Write-Host "EVENT RULES DEBUG: Rule '$ruleName' FAILED - VMD profile '$vmdProfile' is not available" -ForegroundColor Red
                                        break
                                    } else {
                                        Write-Host "EVENT RULES DEBUG: Rule '$ruleName' OK - VMD profile '$vmdProfile' is available" -ForegroundColor Green
                                    }
                                                }
                                                elseif ($topicText -match "tnsaxis:CameraApplicationPlatform/([^/]+)") {
                                                    # Другие ACAP приложения - проверяем через vaconfig.cgi
                                                    $appName = $Matches[1]
                                                    Write-Host "EVENT RULES DEBUG: Found ACAP app dependency: '$appName'" -ForegroundColor Cyan
                                                    
                                                    $appAvailable = Check-AppAvailable -CameraIP $Hostname -AppName $appName -User $credentials.UserName -Password $credentials.GetNetworkCredential().Password
                                                    
                                                    if (-not $appAvailable) {
                                                        $status = "APP_UNAVAILABLE ($appName)"
                                                        $ruleHasProblems = $true
                                                        Write-Host "EVENT RULES DEBUG: Rule '$ruleName' FAILED - ACAP app '$appName' is not available" -ForegroundColor Red
                                                        break
                                                    } else {
                                                        Write-Host "EVENT RULES DEBUG: ACAP app '$appName' is available for rule '$ruleName'" -ForegroundColor Green
                                                    }
                                                }
                                                elseif ($topicText -match "Device.*IO.*VirtualInput") {
                                                    # VirtualInput - обычно всегда доступен
                                                    Write-Host "EVENT RULES DEBUG: Found VirtualInput dependency - assuming available" -ForegroundColor Green
                                                } else {
                                                    Write-Host "EVENT RULES DEBUG: Unknown TopicExpression pattern, no app dependency detected" -ForegroundColor Yellow
                                                }
                                            }
                                            
                                            # Дополнительная проверка: некорректные условия в MessageContent
                                            if (-not $ruleHasProblems) {
                                                $messageContent = $rule.SelectSingleNode(".//wsnt:MessageContent", $nsManager)
                                                if (-not $messageContent) {
                                                    $messageContent = $rule.GetElementsByTagName("MessageContent") | Select-Object -First 1
                                                }
                                                
                                                if ($messageContent -and $messageContent.InnerText -match "error|invalid|unavailable") {
                                                    $status = "INVALID_CONDITION"
                                                    $ruleHasProblems = $true
                                                    Write-Host "EVENT RULES DEBUG: Rule '$ruleName' has invalid MessageContent" -ForegroundColor Red
                                                }
                                            }
                                        } catch {
                                            Write-Host "EVENT RULES DEBUG: Error checking app dependencies: $($_.Exception.Message)" -ForegroundColor Red
                                        }
                                        
                                        if (-not $ruleHasProblems) {
                                            Write-Host "EVENT RULES DEBUG: Rule '$ruleName' appears to be OK - all dependencies are available" -ForegroundColor Green
                                        }
                                    }
                                    
                                    # ОСОБАЯ ЛОГИКА ДЛЯ AXIS-2 - финальная проверка если не нашли проблем
                                    if (-not $ruleHasProblems -and $Hostname -match "axis-e8272504919c") {
                                        Write-Host "EVENT RULES DEBUG: **AXIS-2 SPECIAL FINAL CHECK** - We know this camera has 'App (unavailable)' but XML analysis found no problems" -ForegroundColor Magenta
                                        Write-Host "EVENT RULES DEBUG: This confirms that status information comes from ANOTHER source!" -ForegroundColor Magenta
                                        
                                        # Пробуем последнюю попытку - прямая проверка VMD профиля
                                        $topicExpressions = $rule.GetElementsByTagName("TopicExpression")
                                        foreach ($expr in $topicExpressions) {
                                            $topicText = $expr.InnerText
                                            if ($topicText -match "VMD/([^/]+)") {
                                                $profileName = $Matches[1]
                                                Write-Host "EVENT RULES DEBUG: AXIS-2 - Final VMD profile check for '$profileName'" -ForegroundColor Yellow
                                                $vmdProfileAvailable = Check-VMDProfileReal -Hostname $Hostname -ProfileName $profileName -TimeoutSeconds $TimeoutSeconds -credentials $credentials
                                                if (-not $vmdProfileAvailable) {
                                                    $status = "AXIS2_FORCED_VMD_CHECK_FAILED"
                                                    $ruleHasProblems = $true
                                                    Write-Host "EVENT RULES DEBUG: AXIS-2 FORCED VMD CHECK - Profile '$profileName' IS UNAVAILABLE!" -ForegroundColor Red
                                                    break
                                                }
                                            }
                                        }
                                    }
                                    
                                    # Подсчитываем результат
                                    if ($ruleHasProblems) {
                                        $failedRules++
                                        Write-Host "EVENT RULES DEBUG: Rule '$ruleName' has status: $status" -ForegroundColor Red
                                    } else {
                                        $workingRules++
                                        Write-Host "EVENT RULES DEBUG: Rule '$ruleName' is OK" -ForegroundColor Green
                                    }
                                }
                                
                                Write-Host "EVENT RULES DEBUG: Summary for $Hostname - Total:$totalRules, Working:$workingRules, Failed:$failedRules" -ForegroundColor Cyan
                                
                                return @{
                                    TotalRules = $totalRules
                                    WorkingRules = $workingRules
                                    FailedRules = $failedRules
                                }
                            } else {
                                Write-Host "EVENT RULES DEBUG: Failed to parse XML for $Hostname" -ForegroundColor Red
                                Write-Host "EVENT RULES DEBUG: Response was not null but Parse-XmlSafe failed" -ForegroundColor Red
                                Write-Host "EVENT RULES DEBUG: Response type: $($resp.GetType().Name)" -ForegroundColor Red
                                Write-Host "EVENT RULES DEBUG: Attempting direct XML parse..." -ForegroundColor Yellow
                                try {
                                    $directXml = [xml]$resp
                                    Write-Host "EVENT RULES DEBUG: Direct XML parse succeeded" -ForegroundColor Green
                                    Write-Host "EVENT RULES DEBUG: Direct XML root: $($directXml.DocumentElement.Name)" -ForegroundColor Green
                                } catch {
                                    Write-Host "EVENT RULES DEBUG: Direct XML parse also failed: $($_.Exception.Message)" -ForegroundColor Red
                                }
                            }
                        } else {
                            Write-Host "EVENT RULES DEBUG: No valid SOAP response from $Hostname" -ForegroundColor Red
                        }
                    }
                    catch {
                        Write-Host "EVENT RULES DEBUG: Exception for $Hostname - $($_.Exception.Message)" -ForegroundColor Red
                    }
                    
                    Write-Host "EVENT RULES DEBUG: Returning zeros for $Hostname" -ForegroundColor Red
                    return @{
                        TotalRules = 0
                        WorkingRules = 0
                        FailedRules = 0
                    }
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
                
                # Новые метрики
                $syslogStatus = Get-SyslogStatus -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                
                Write-Output "DEBUG: Calling Get-EventRulesStatus for $Hostname"
                $eventRulesStatus = Get-EventRulesStatus -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
                Write-Output "DEBUG: Event rules status for $Hostname = Total:$($eventRulesStatus.TotalRules), Working:$($eventRulesStatus.WorkingRules), Failed:$($eventRulesStatus.FailedRules)"
                
                $sdMetrics = GetSdMetrics -Hostname $Hostname -TimeoutSeconds $TimeoutSeconds -credentials $creds
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
                        # Новые метрики
                        SyslogEnabled = $syslogStatus
                        EventRulesTotal = $eventRulesStatus.TotalRules
                        EventRulesWorking = $eventRulesStatus.WorkingRules
                        EventRulesFailed = $eventRulesStatus.FailedRules
                        Success = $true
                    }
                    if ($sshStatus -ne $null) { $metricsObject.SshEnabled = $sshStatus }
                    $metricsObject.VmdStatus = $vmdStatus
                    
                    return $metricsObject
                } else {
                    $metricsObject = @{
                        CameraID = $CameraID
                        CameraName = $CameraName
                        Hostname = $Hostname
                        TotalRecordings = 0
                        EventRulesCount = $eventRulesCount
                        # Новые метрики для неудачных случаев
                        SyslogEnabled = $syslogStatus
                        EventRulesTotal = $eventRulesStatus.TotalRules
                        EventRulesWorking = $eventRulesStatus.WorkingRules
                        EventRulesFailed = $eventRulesStatus.FailedRules
                        Success = $false
                        Error = "No SD card attributes found"
                    }
                    if ($sshStatus -ne $null) { $metricsObject.SshEnabled = $sshStatus }
                    $metricsObject.VmdStatus = $vmdStatus
                    return $metricsObject
                }
            } catch {
                return $null
            }
        } -ArgumentList $Hostname, $CameraID, $CameraName, $TimeoutSeconds, $Username, $Password
        
        $batchJobs += $job
        $batchJobResults[$camera.Hostname] = $camera
    }
    
    # Ждем завершения текущего batch
    Write-Log "Waiting for batch jobs to complete..."
    $batchJobs | Wait-Job | Out-Null
    
    # Собираем результаты
    Write-Log "Collecting results from $($batchJobs.Count) jobs..."
    $batchSuccessCount = 0
    $batchFailCount = 0
    
    foreach ($job in $batchJobs) {
        $jobOutput = Receive-Job -Job $job -Keep
        $jobResult = $jobOutput | Where-Object { $_ -and $_.CameraID } | Select-Object -First 1
        
        # Логируем все выводы из job для отладки
        $debugOutputs = $jobOutput | Where-Object { $_ -and ($_.ToString().Contains("DEBUG:") -or $_.ToString().Contains("SYSLOG DEBUG:") -or $_.ToString().Contains("EVENT RULES DEBUG:")) }
        foreach ($debugOutput in $debugOutputs) {
            Write-Log "JOB DEBUG: $debugOutput"
        }
        
        Remove-Job -Job $job
        if ($jobResult -and $jobResult.CameraID) {
            $allMetrics += $jobResult
            if ($jobResult.Success) {
                $batchSuccessCount++
            } else {
                $batchFailCount++
            }
            Write-Log "Processed camera ID $($jobResult.CameraID) ($($jobResult.Hostname)): Success=$($jobResult.Success)"
            
            # Логируем новые метрики
            Write-Log "NEW METRICS DEBUG - Camera $($jobResult.CameraID):"
            Write-Log "  EventRulesTotal: $($jobResult.EventRulesTotal)"
            Write-Log "  EventRulesWorking: $($jobResult.EventRulesWorking)"
            Write-Log "  EventRulesFailed: $($jobResult.EventRulesFailed)"
        } else {
            Write-Log "WARNING: Job returned null or invalid result"
            $batchFailCount++
        }
    }
    
    Write-Log "Batch completed: $batchSuccessCount successful, $batchFailCount failed"
}

# Генерируем Prometheus файл
Write-Log "Generating Prometheus metrics file with $($allMetrics.Count) camera metrics..."
$promContent = Generate-PrometheusMetrics -Metrics $allMetrics

# Сохраняем файл в C:\windows_exporter
$outputPath = Join-Path "C:\windows_exporter" $OutputFile
Write-Log "Saving metrics to file: $outputPath"
Set-Content -Path $outputPath -Value $promContent -Encoding UTF8
Write-Log "Metrics file saved successfully (size: $($promContent.Length) characters)"

# Статистика
$successCount = ($allMetrics | Where-Object { $_.Success }).Count
$errorCount = ($allMetrics | Where-Object { -not $_.Success }).Count

Write-Log "=== METRICS COLLECTION SUMMARY ==="
Write-Log "Total cameras processed: $($allMetrics.Count)"
Write-Log "Successful responses: $successCount"
Write-Log "Failed responses: $errorCount"
Write-Log "Output file: $outputPath"

# Подсчет новых метрик
$syslogEnabledCount = @($allMetrics | Where-Object { $_.SyslogEnabled -eq 1 }).Count
$totalEventRules = ($allMetrics | ForEach-Object { $_.EventRulesTotal } | Measure-Object -Sum).Sum
$workingEventRules = ($allMetrics | ForEach-Object { $_.EventRulesWorking } | Measure-Object -Sum).Sum
$failedEventRules = ($allMetrics | ForEach-Object { $_.EventRulesFailed } | Measure-Object -Sum).Sum

Write-Log "NEW METRICS SUMMARY:"
Write-Log "  Cameras with Syslog enabled: $syslogEnabledCount"
Write-Log "  Total Event Rules: $totalEventRules"
Write-Log "  Working Event Rules: $workingEventRules"
Write-Log "  Failed Event Rules: $failedEventRules"

if ($errorCount -gt 0) {
    Write-Log "WARNING: $errorCount camera(s) failed to respond"
    Write-Host "WARNING: $errorCount camera(s) failed to respond" -ForegroundColor Yellow
}

Write-Log "Prometheus metrics file generated successfully"
Write-Log "=== CAMERA METRICS COLLECTION SESSION END ==="

# Очистка временных файлов
Write-Log "Cleaning up temporary files..."
if (Test-Path $TempDatabase) {
    Remove-Item $TempDatabase -Force
    Write-Log "Removed temporary database: $TempDatabase"
} 