# Быстрый старт - Axis Camera Station Monitoring

## 🚀 Быстрая установка (2 минуты)

### 1. Подготовка файлов
Убедитесь, что у вас есть два файла в одной папке:
- `install_service.ps1` - скрипт автоматической установки
- `get_metrics.ps1` - скрипт мониторинга

### 2. Запуск установки
```powershell
# Запустите PowerShell от имени администратора
cd C:\axis_fdb
.\install_service.ps1
```

**Что произойдет автоматически:**
- ✅ Скачивание и установка Firebird 3.0.12 x64
- ✅ Проверка и запуск службы Firebird
- ✅ Копирование get_metrics.ps1 в C:\windows_exporter\
- ✅ Создание задачи планировщика (каждую минуту)

## 📋 Что получится

После установки у вас будет:
- ✅ Firebird 3.0.12 с DevTools (isql.exe)
- ✅ Служба Firebird (автозапуск)
- ✅ Мониторинг каждую минуту
- ✅ Метрики в формате Prometheus
- ✅ Интеграция с wmi_exporter
- ✅ Автоматическая очистка временных файлов

## 📊 Метрики

Скрипт создает файл `C:\windows_exporter\axis_camera_station_metrics.prom` с метриками:

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

## 🔧 Ручная настройка (если автоматическая не работает)

### 1. Установка Firebird вручную
- Скачайте Firebird 3.0.12 x64 с https://firebirdsql.org/
- Установите с DevTools (isql.exe)
- Убедитесь, что служба запущена

### 2. Создайте директории
```powershell
mkdir C:\temp\axis_monitoring -Force
mkdir C:\windows_exporter -Force
```

### 3. Скопируйте скрипт
```powershell
Copy-Item get_metrics.ps1 C:\windows_exporter\
```

### 4. Настройте политику PowerShell
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

### 5. Создайте задачу в планировщике
```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\windows_exporter\get_metrics.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 365)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "Axis Camera Monitoring" -Action $action -Trigger $trigger -Settings $settings -Principal $principal
```

## 🧪 Тестирование

### Запустите скрипт вручную
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\windows_exporter\get_metrics.ps1"
```

### Проверьте результат
```powershell
Get-Content C:\windows_exporter\axis_camera_station_metrics.prom
```

## 📁 Структура файлов

```
C:\axis_fdb\
├── install_service.ps1      # Автоматическая установка
└── get_metrics.ps1         # Скрипт мониторинга

C:\windows_exporter\
└── get_metrics.ps1         # Копия скрипта (создается автоматически)
```

## ⚠️ Требования

- Windows Server 2019/2022
- PowerShell 5.1+
- Права администратора
- Интернет для скачивания Firebird
- Axis Camera Station Server

## 🆘 Устранение проблем

### Ошибка "Firebird process is already running"
- Остановите службу Firebird: `Stop-Service FirebirdServerDefaultInstance`
- Или перезагрузите сервер

### Ошибка "isql not found"
```powershell
# Проверьте путь к Firebird
Test-Path "C:\Program Files\Firebird\Firebird_3_0\isql.exe"
```

### Ошибка "Access denied"
```powershell
# Запустите PowerShell от имени администратора
```

### Ошибка "Execution policy"
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

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
3. Проверьте, что файл get_metrics.ps1 находится рядом с install_service.ps1

## 🎯 Результат

После успешной установки вы получите:
- **Автоматическую установку Firebird** с DevTools
- **Мониторинг каждую минуту** через планировщик задач
- **18 метрик** в формате Prometheus
- **Интеграцию с wmi_exporter** для сбора метрик
- **Автоматическое обновление** файла метрик 