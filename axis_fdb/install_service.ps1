# install_service.ps1 — Automated Firebird 3.0.12 x64 installation and monitoring setup for Axis Camera Station

# 0. Check for administrator rights
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[FAIL] Please run this script as Administrator!" -ForegroundColor Red
    Start-Process powershell.exe "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit 100
}

$firebirdExeUrl = "https://github.com/FirebirdSQL/firebird/releases/download/v3.0.12/Firebird-3.0.12.33787-0-x64.exe"
$firebirdExeName = "Firebird-3.0.12.33787-0-x64.exe"
$firebirdInstallDir = "C:\Program Files\Firebird\Firebird_3_0"

Write-Host "=== Firebird 3.0.12 x64 silent install ===" -ForegroundColor Cyan

# 1. Check if Firebird is already installed and working
Write-Host "Checking if Firebird is already installed..." -NoNewline
$isqlPath = Join-Path $firebirdInstallDir "isql.exe"
$firebirdAlreadyInstalled = $false

if (Test-Path $isqlPath) {
    Write-Host " [FOUND]" -ForegroundColor Green
    Write-Host "isql.exe found at $isqlPath" -ForegroundColor Green
    
    # Check if Firebird service is running
    $fbServices = Get-Service | Where-Object { $_.Name -like '*firebird*' -or $_.DisplayName -like '*Firebird*' }
    if ($fbServices -and $fbServices.Count -gt 0) {
        $serviceRunning = $false
        foreach ($svc in $fbServices) {
            if ($svc.Status -eq 'Running') {
                Write-Host "Firebird service '$($svc.Name)' is running." -ForegroundColor Green
                $serviceRunning = $true
                break
            }
        }
        
        if ($serviceRunning) {
            Write-Host "Firebird is already installed and working!" -ForegroundColor Cyan
            $firebirdAlreadyInstalled = $true
        } else {
            Write-Host "Firebird installed but service not running. Starting service..." -ForegroundColor Yellow
            foreach ($svc in $fbServices) {
                if ($svc.Status -ne 'Running') {
                    Write-Host "Starting service $($svc.Name)..." -NoNewline
                    try {
                        Start-Service -Name $svc.Name
                        Write-Host " [OK]" -ForegroundColor Green
                        $firebirdAlreadyInstalled = $true
                        break
                    } catch {
                        Write-Host " [ERROR]" -ForegroundColor Red
                        Write-Host $_.Exception.Message -ForegroundColor Red
                    }
                }
            }
        }
    } else {
        Write-Host "Firebird installed but no service found. Will reinstall." -ForegroundColor Yellow
    }
} else {
    Write-Host " [NOT FOUND]" -ForegroundColor Yellow
}

# 2. Install Firebird only if not already installed and working
if (-not $firebirdAlreadyInstalled) {
    Write-Host "=== Installing Firebird 3.0.12 x64 ===" -ForegroundColor Cyan
    
    # Check for running Firebird process
    $fbProc = Get-Process | Where-Object { $_.ProcessName -like "*firebird*" -or $_.ProcessName -like "*fbserver*" }
    if ($fbProc) {
        Write-Host "[FAIL] Firebird process is already running (PID: $($fbProc.Id)). Aborting install." -ForegroundColor Yellow
        Write-Host "Please stop Firebird and try again."
        exit 1
    }

    # Download installer
    $tempDir = $env:TEMP
    $exePath = Join-Path $tempDir $firebirdExeName
    if (Test-Path $exePath) { Remove-Item $exePath -Force }

    Write-Host "Downloading Firebird installer..." -NoNewline
    try {
        Invoke-WebRequest -Uri $firebirdExeUrl -OutFile $exePath -UseBasicParsing
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [ERROR]" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 2
    }

    # Silent install
    # NOTE: /COMPONENTS is omitted — all required components (server, tools, client) will be installed by default (recommended)
    $arguments = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="' + $firebirdInstallDir + '"'
    Write-Host "Running Firebird silent install..." -NoNewline
    $proc = Start-Process -FilePath $exePath -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -eq 0) {
        Write-Host " [OK]" -ForegroundColor Green
    } else {
        Write-Host " [ERROR]" -ForegroundColor Red
        Write-Host "Installer exit code: $($proc.ExitCode)"
        exit 3
    }

    # Remove installer
    Remove-Item $exePath -Force

    # Check for Firebird service (any name containing 'firebird')
    Start-Sleep -Seconds 3
    $fbServices = Get-Service | Where-Object { $_.Name -like '*firebird*' -or $_.DisplayName -like '*Firebird*' }

    if ($fbServices -and $fbServices.Count -gt 0) {
        $found = $false
        foreach ($svc in $fbServices) {
            Write-Host "Found Firebird service: $($svc.Name) ($($svc.DisplayName)), Status: $($svc.Status), StartType: $($svc.StartType)"
            if ($svc.Status -ne 'Running') {
                Write-Host "Starting service $($svc.Name)..." -NoNewline
                try {
                    Start-Service -Name $svc.Name
                    Write-Host " [OK]" -ForegroundColor Green
                } catch {
                    Write-Host " [ERROR]" -ForegroundColor Red
                    Write-Host $_.Exception.Message -ForegroundColor Red
                    exit 4
                }
            } else {
                Write-Host "Service $($svc.Name) is already running." -ForegroundColor Green
            }
            if ($svc.StartType -ne 'Automatic') {
                Write-Host "Setting $($svc.Name) to autostart..." -NoNewline
                Set-Service -Name $svc.Name -StartupType Automatic
                Write-Host " [OK]" -ForegroundColor Green
            } else {
                Write-Host "Service $($svc.Name) is already set to autostart." -ForegroundColor Green
            }
            $found = $true
        }
        if ($found) {
            Write-Host "Firebird service(s) installed and running!" -ForegroundColor Cyan
        }
    } else {
        Write-Host "[WARN] No Firebird service found after install!" -ForegroundColor Yellow
        Write-Host "Listing all services containing 'firebird':"
        Get-Service | Where-Object { $_.Name -like '*firebird*' -or $_.DisplayName -like '*Firebird*' } | Format-Table Name,DisplayName,Status,StartType
    }

    # Check for isql.exe
    $isqlPath = Join-Path $firebirdInstallDir "isql.exe"
    if (Test-Path $isqlPath) {
        Write-Host "isql.exe found at $isqlPath" -ForegroundColor Green
    } else {
        Write-Host "[WARN] isql.exe not found at $isqlPath!" -ForegroundColor Yellow
    }
}

# 3. Create C:\windows_exporter if not exists
$exportDir = "C:\windows_exporter"
if (!(Test-Path $exportDir)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    Write-Host "Created directory: $exportDir" -ForegroundColor Green
}

# 4. Copy get_metrics.ps1 to C:\windows_exporter
$metricsScript = Join-Path $exportDir "get_metrics.ps1"
$sourceMetricsScript = Join-Path (Split-Path -Parent $PSCommandPath) "get_metrics.ps1"

if (Test-Path $sourceMetricsScript) {
    Write-Host "Copying get_metrics.ps1 to $exportDir..." -NoNewline
    try {
        Copy-Item $sourceMetricsScript $metricsScript -Force
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [ERROR]" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 5
    }
} else {
    Write-Host "[ERROR] get_metrics.ps1 not found in the same directory as install_service.ps1!" -ForegroundColor Red
    Write-Host "Expected location: $sourceMetricsScript" -ForegroundColor Red
    exit 6
}
Write-Host "get_metrics.ps1 copied successfully!" -ForegroundColor Green

# 5. Create Task Scheduler job for monitoring (every minute)
Write-Host "=== Creating Task Scheduler job for monitoring ===" -ForegroundColor Cyan
$taskName = "Axis Camera Monitoring"

Write-Host "Checking for existing task: $taskName..." -NoNewline
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host " [FOUND]" -ForegroundColor Yellow
    try {
        Write-Host "Removing existing task..." -NoNewline
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [ERROR]" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 7
    }
} else {
    Write-Host " [NOT FOUND]" -ForegroundColor Green
}

Write-Host "Creating new scheduled task..." -NoNewline
try {
    Write-Host "Creating action..." -NoNewline
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$metricsScript`""
    Write-Host " [OK]" -ForegroundColor Green
    
    Write-Host "Creating trigger..." -NoNewline
    # Исправляем проблему с длительностью повторения
    $startTime = (Get-Date).AddMinutes(1)
    $trigger = New-ScheduledTaskTrigger -Once -At $startTime -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 365)
    Write-Host " [OK]" -ForegroundColor Green
    
    Write-Host "Creating settings..." -NoNewline
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable
    Write-Host " [OK]" -ForegroundColor Green
    
    Write-Host "Creating principal..." -NoNewline
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Write-Host " [OK]" -ForegroundColor Green
    
    Write-Host "Registering task..." -NoNewline
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Axis Camera Station Monitoring - every minute"
    Write-Host " [OK]" -ForegroundColor Green
    
    Write-Host "Task '$taskName' created successfully!" -ForegroundColor Green
    Write-Host "  - Action: powershell.exe -ExecutionPolicy Bypass -File `"$metricsScript`"" -ForegroundColor Cyan
    Write-Host "  - Trigger: Every minute starting from $startTime" -ForegroundColor Cyan
    Write-Host "  - User: SYSTEM" -ForegroundColor Cyan
} catch {
    Write-Host " [ERROR]" -ForegroundColor Red
    Write-Host "Failed to create scheduled task!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.Exception.StackTrace)" -ForegroundColor Red
    exit 8
}

Write-Host "=== Firebird installation and monitoring setup finished ===" -ForegroundColor Cyan 