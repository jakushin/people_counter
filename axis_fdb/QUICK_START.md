# Быстрый старт - Axis Camera Station Monitoring

## 🚀 Быстрая установка (3 минуты)

### 1. Подготовка файлов
Убедитесь, что у вас есть три файла в одной папке:
- `install_service.ps1` - скрипт автоматической установки
- `get_metrics.ps1` - скрипт мониторинга БД
- `get_cameras_metrics.ps1` - скрипт мониторинга API камер

### 2. Запуск установки
```powershell
# Запустите PowerShell от имени администратора
cd C:\axis_fdb
.\install_service.ps1
```

**Что произойдет автоматически:**
- ✅ Скачивание и установка Firebird 3.0.12 x64
- ✅ Проверка и запуск службы Firebird
- ✅ Настройка защищенных credentials для API камер
- ✅ Копирование скриптов в C:\windows_exporter\
- ✅ Создание задачи планировщика (каждые 10 минут)

## 📋 Что получится

После установки у вас будет:
- ✅ Firebird 3.0.12 с DevTools (isql.exe)
- ✅ Служба Firebird (автозапуск)
- ✅ Защищенные credentials для API камер
- ✅ Мониторинг каждые 10 минут
- ✅ Метрики БД в формате Prometheus
- ✅ Метрики API камер в формате Prometheus
- ✅ Интеграция с wmi_exporter
- ✅ Автоматическая очистка временных файлов

## 📊 Метрики

Система создает два файла метрик:

### 1. Метрики базы данных (`axis_camera_station_metrics.prom`)

```
# HELP axis_camera_oldest_recording_timestamp Timestamp of the oldest recording
# TYPE axis_camera_oldest_recording_timestamp gauge
axis_camera_oldest_recording_timestamp{camera_id="1",camera_name="Camera1"} 1334567890123456789

# HELP axis_camera_total_recordings Total number of recordings
# TYPE axis_camera_total_recordings gauge
axis_camera_total_recordings 46999

# HELP axis_camera_total_cameras Total number of cameras with recordings
# TYPE axis_camera_total_cameras gauge
axis_camera_total_cameras 11

# HELP axis_camera_storage_used_bytes Total storage used by all recordings
# TYPE axis_camera_storage_used_bytes gauge
axis_camera_storage_used_bytes 1073741824000
```

### 2. Метрики API камер (`axis_camera_vapix_metrics.prom`)

```
# HELP axis_camera_station_vapix_encryption_enabled Encryption enabled on SD card
# TYPE axis_camera_station_vapix_encryption_enabled gauge
axis_camera_station_vapix_encryption_enabled{camera_id="1",camera_name="Camera1",hostname="192.168.1.100"} 1

# HELP axis_camera_station_vapix_disk_encrypted SD card is encrypted
# TYPE axis_camera_station_vapix_disk_encrypted gauge
axis_camera_station_vapix_disk_encrypted{camera_id="1",camera_name="Camera1",hostname="192.168.1.100"} 0

# HELP axis_camera_station_vapix_sd_usage_percent SD card usage percentage
# TYPE axis_camera_station_vapix_sd_usage_percent gauge
axis_camera_station_vapix_sd_usage_percent{camera_id="1",camera_name="Camera1",hostname="192.168.1.100"} 45.67
```

## 🔧 Ручная настройка (если автоматическая не работает)

### 1. Установка Firebird вручную
- Скачайте Firebird 3.0.12 x64 с https://firebirdsql.org/
- Установите с DevTools (isql.exe)
- Убедитесь, что служба запущена

### 2. Создайте директории
```powershell
mkdir C:\temp\axis_monitoring -Force
mkdir C:\windows_exporter -Force
mkdir C:\ProgramData\AxisCameraStation -Force
```

### 3. Скопируйте скрипты
```powershell
Copy-Item get_metrics.ps1 C:\windows_exporter\
Copy-Item get_cameras_metrics.ps1 C:\windows_exporter\
```

### 4. Настройте политику PowerShell
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

### 5. Создайте задачу в планировщике
```powershell
$action1 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\windows_exporter\get_metrics.ps1"
$action2 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\windows_exporter\get_cameras_metrics.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "Axis Camera Monitoring" -Action $action1, $action2 -Trigger $trigger -Settings $settings -Principal $principal
```

## 🧪 Тестирование

### Запустите скрипты вручную
```powershell
# Тест метрик БД
powershell.exe -ExecutionPolicy Bypass -File "C:\windows_exporter\get_metrics.ps1"

# Тест метрик API камер
powershell.exe -ExecutionPolicy Bypass -File "C:\windows_exporter\get_cameras_metrics.ps1"
```

### Проверьте результат
```powershell
Get-Content C:\windows_exporter\axis_camera_station_metrics.prom
Get-Content C:\windows_exporter\axis_camera_vapix_metrics.prom
```

## 📁 Структура файлов

```
C:\axis_fdb\
├── install_service.ps1           # Автоматическая установка
├── get_metrics.ps1              # Скрипт мониторинга БД
└── get_cameras_metrics.ps1      # Скрипт мониторинга API камер

C:\windows_exporter\
├── get_metrics.ps1              # Копия скрипта БД (создается автоматически)
└── get_cameras_metrics.ps1      # Копия скрипта API (создается автоматически)

C:\ProgramData\AxisCameraStation\
└── camera_credentials.dat        # Защищенные credentials (создается автоматически)
```

## ⚠️ Требования

- Windows Server 2019/2022
- PowerShell 5.1+
- Права администратора
- Интернет для скачивания Firebird
- Axis Camera Station Server
- Доступ к API камер (username/password)

## 🆘 Устранение проблем

### Ошибка "Firebird process is already running"
- Остановите службу Firebird: `Stop-Service FirebirdServerDefaultInstance`
- Или перезагрузите сервер

### Ошибка "isql not found"
```powershell
# Проверьте путь к Firebird
Test-Path "C:\Program Files\Firebird\Firebird_3_0\isql.exe"
```

### Ошибка "Credential file not found"
```powershell
# Запустите install_service.ps1 для настройки credentials
.\install_service.ps1
```

### Ошибка "Access denied"
```powershell
# Запустите PowerShell от имени администратора
```

### Ошибка "Execution policy"
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

### Ошибка "expected float as value, got 'true'"
```
Error parsing "C:\\windows_exporter\\axis_camera_vapix_metrics.prom": text format parsing error
```
**Решение:** Обновите скрипт `get_cameras_metrics.ps1` до последней версии.

### База заблокирована
- Это нормально! Скрипт автоматически копирует базу для работы

### Задача планировщика не создается
```powershell
# Проверьте существующие задачи
Get-ScheduledTask -TaskName "Axis Camera Monitoring"
# Удалите старую задачу
Unregister-ScheduledTask -TaskName "Axis Camera Monitoring" -Confirm:$false
```

## 📞 Поддержка

Если что-то не работает:
1. Проверьте логи в консоли при запуске install_service.ps1
2. Убедитесь, что все пути правильные
3. Проверьте, что файлы get_metrics.ps1 и get_cameras_metrics.ps1 находятся рядом с install_service.ps1
4. Убедитесь, что у вас есть доступ к API камер

## 🎯 Результат

После успешной установки вы получите:
- **Автоматическую установку Firebird** с DevTools
- **Защищенные credentials** для API камер
- **Мониторинг каждые 10 минут** через планировщик задач
- **18 метрик БД** + **метрики API камер** в формате Prometheus
- **Интеграцию с wmi_exporter** для сбора метрик
- **Параллельную обработку** для высокой производительности 