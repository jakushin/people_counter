# Axis Camera Station Monitoring

Система мониторинга для Axis Camera Station на основе анализа баз данных Firebird.

## Описание

Автоматизированная система мониторинга Axis Camera Station, которая:
1. **Автоматически устанавливает** Firebird 3.0.12 с DevTools
2. **Настраивает службу** Firebird для автозапуска
3. **Копирует скрипт мониторинга** в рабочую директорию
4. **Создает задачу планировщика** для автоматического мониторинга каждую минуту
5. **Анализирует метрики** записей камер из баз данных Firebird
6. **Экспортирует метрики** в формате Prometheus для wmi_exporter
7. **Очищает временные файлы** после каждого запуска

## Быстрая установка

### Требования
- Windows Server 2019/2022
- PowerShell 5.1+
- Права администратора
- Интернет для скачивания Firebird
- Axis Camera Station Server

### Установка (2 минуты)

1. **Подготовьте файлы:**
   ```
   C:\axis_fdb\
   ├── install_service.ps1      # Автоматическая установка
   └── get_metrics.ps1         # Скрипт мониторинга
   ```

2. **Запустите установку:**
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

## Структура системы

### Файлы установки
- `install_service.ps1` - автоматическая установка и настройка
- `get_metrics.ps1` - скрипт мониторинга (копируется в C:\windows_exporter\)

### Рабочие директории
- `C:\windows_exporter\` - директория для метрик (создается автоматически)
- `C:\temp\axis_monitoring\` - временная директория (создается автоматически)
- `C:\Program Files\Firebird\Firebird_3_0\` - Firebird (устанавливается автоматически)

### Задача планировщика
- **Имя:** "Axis Camera Monitoring"
- **Запуск:** каждую минуту
- **Пользователь:** SYSTEM
- **Скрипт:** `C:\windows_exporter\get_metrics.ps1`

## Метрики

Скрипт создает файл `C:\windows_exporter\axis_camera_station_metrics.prom` с **18 метриками** в формате Prometheus:

### Базовые метрики
- `axis_camera_total_cameras` - Общее количество камер
- `axis_camera_enabled_total` - Количество включенных камер
- `axis_camera_disabled_total` - Количество отключенных камер
- `axis_camera_total_recordings` - Общее количество записей
- `axis_camera_storage_used_bytes` - Общий размер хранилища записей в байтах

### Метрики по камерам
- `axis_camera_recordings_total_per_camera{camera_id="X",camera_name="Y"}` - Количество записей на камеру
- `axis_camera_storage_used_bytes_per_camera{camera_id="X",camera_name="Y"}` - Размер хранилища на камеру
- `axis_camera_last_recording_start_timestamp_seconds{camera_id="X",camera_name="Y"}` - Последнее время начала записи
- `axis_camera_last_recording_stop_timestamp_seconds{camera_id="X",camera_name="Y"}` - Последнее время окончания записи
- `axis_camera_oldest_recording_timestamp{camera_id="X",camera_name="Y"}` - Время самой старой записи
- `axis_camera_retention_days_per_camera{camera_id="X",camera_name="Y"}` - Время хранения в днях

### Метрики по записям
- `axis_camera_incomplete_recordings_total` - Количество незавершенных записей
- `axis_camera_avg_recording_size_bytes` - Средний размер записи в байтах
- `axis_camera_avg_recording_duration_seconds` - Средняя длительность записи в секундах
- `axis_camera_newest_recording_timestamp` - Время самой новой записи

### Метрики по событиям
- `axis_camera_events_by_category{category="X"}` - Количество событий по категориям

### Метрики по хранилищу
- `axis_camera_recordings_total_by_storage{storage_id="X",storage_name="Y"}` - Количество записей по хранилищам
- `axis_camera_storage_used_bytes_by_storage{storage_id="X",storage_name="Y"}` - Размер по хранилищам

### Служебные метрики
- `axis_camera_monitoring_last_update` - Время последнего обновления мониторинга

**Подробное описание всех метрик:** см. [EXTENDED_METRICS_GUIDE.md](EXTENDED_METRICS_GUIDE.md)

## Интеграция с wmi_exporter

### 1. Настройка wmi_exporter

Добавьте в конфигурацию wmi_exporter:

```yaml
collectors:
  textfile:
    directory: "C:\\windows_exporter"
```

### 2. Перезапуск wmi_exporter

```powershell
Restart-Service wmi_exporter
```

## Логирование

**По умолчанию логирование отключено** для повышения производительности. 

Для включения логирования:
1. Откройте файл `get_metrics.ps1`
2. Раскомментируйте функции `Write-Log` и `Write-DebugLog`
3. Раскомментируйте вызовы этих функций по всему скрипту

**Подробная инструкция:** см. [DEBUG_GUIDE.md](DEBUG_GUIDE.md)

## Устранение неполадок

### 1. Ошибка "Firebird process is already running"
```
[FAIL] Firebird process is already running (PID: XXXX). Aborting install.
```
**Решение:** 
```powershell
# Остановите службу Firebird
Stop-Service FirebirdServerDefaultInstance
# Или перезагрузите сервер
```

### 2. Ошибка "isql not found"
```
[WARN] isql.exe not found at C:\Program Files\Firebird\Firebird_3_0\isql.exe!
```
**Решение:** 
```powershell
# Проверьте установку Firebird
Test-Path "C:\Program Files\Firebird\Firebird_3_0\isql.exe"
# Переустановите Firebird с DevTools
```

### 3. Ошибка доступа к базе данных
```
Ошибка выполнения SQL запроса: The process cannot access the file because it is being used by another process
```
**Решение:** База заблокирована Axis Camera Station. Скрипт автоматически копирует базу для работы.

### 4. Задача планировщика не создается
```
Register-ScheduledTask : The task XML contains a value which is incorrectly formatted
```
**Решение:**
```powershell
# Проверьте существующие задачи
Get-ScheduledTask -TaskName "Axis Camera Monitoring"
# Удалите старую задачу
Unregister-ScheduledTask -TaskName "Axis Camera Monitoring" -Confirm:$false
# Запустите install_service.ps1 снова
```

### 5. Файл метрик пустой или не создается
```
Файл axis_camera_station_metrics.prom пустой или не создается
```
**Решение:**
```powershell
# Проверьте наличие файла
Test-Path "C:\windows_exporter\axis_camera_station_metrics.prom"
# Проверьте содержимое
Get-Content "C:\windows_exporter\axis_camera_station_metrics.prom"
# Запустите скрипт вручную для диагностики
powershell.exe -ExecutionPolicy Bypass -File "C:\windows_exporter\get_metrics.ps1"
```

### 6. Ошибка "Execution policy"
```
Set-ExecutionPolicy : Access to the registry key 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell' is denied.
```
**Решение:**
```powershell
# Запустите PowerShell от имени администратора
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine
```

## Ручная настройка (если автоматическая не работает)

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

### 4. Создайте задачу в планировщике
```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\windows_exporter\get_metrics.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 365)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "Axis Camera Monitoring" -Action $action -Trigger $trigger -Settings $settings -Principal $principal
```

## Тестирование

### Запустите скрипт вручную
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\windows_exporter\get_metrics.ps1"
```

### Проверьте результат
```powershell
Get-Content C:\windows_exporter\axis_camera_station_metrics.prom
```

## Документация

- [QUICK_START.md](QUICK_START.md) - Быстрый старт (2 минуты)
- [EXTENDED_METRICS_GUIDE.md](EXTENDED_METRICS_GUIDE.md) - Подробное описание метрик
- [DEBUG_GUIDE.md](DEBUG_GUIDE.md) - Включение логирования
- [DATABASE_STRUCTURE.md](DATABASE_STRUCTURE.md) - Структура баз данных

## Результат

После успешной установки вы получите:
- **Автоматическую установку Firebird** с DevTools
- **Мониторинг каждую минуту** через планировщик задач
- **18 метрик** в формате Prometheus
- **Интеграцию с wmi_exporter** для сбора метрик
- **Автоматическое обновление** файла метрик 