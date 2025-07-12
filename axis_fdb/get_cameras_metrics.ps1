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
                        Success = $true
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
                        Success = $false
                        Error = "No SD card attributes found"
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
            Write-Host "WARNING: Job did not return expected array of [debugLogs, result]!" -ForegroundColor Red
            $allMetrics += $jobResult
        }
    }
}

# Генерируем Prometheus файл
$promContent = Generate-PrometheusMetrics -Metrics $allMetrics

# Сохраняем файл в C:\windows_exporter
$outputPath = Join-Path "C:\windows_exporter" $OutputFile
Set-Content -Path $outputPath -Value $promContent -Encoding UTF8

# Статистика
$successCount = ($allMetrics | Where-Object { $_.Success }).Count
$errorCount = ($allMetrics | Where-Object { -not $_.Success }).Count



if ($errorCount -gt 0) {
    Write-Host "WARNING: $errorCount camera(s) failed to respond" -ForegroundColor Yellow
}

# Очистка временных файлов
if (Test-Path $TempDatabase) {
    Remove-Item $TempDatabase -Force
} 