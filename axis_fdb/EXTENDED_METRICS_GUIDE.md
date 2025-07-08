# Руководство по метрикам Axis Camera Station

## Метрики в get_metrics.ps1

### Базовые метрики
- `axis_camera_total_cameras` - Общее количество камер
- `axis_camera_enabled_total` - Количество включенных камер
- `axis_camera_disabled_total` - Количество отключенных камер
- `axis_camera_total_recordings` - Общее количество записей
- `axis_camera_storage_used_bytes` - Общий размер хранилища записей в байтах

### Метрики по камерам
- `axis_camera_recordings_total_per_camera{camera_name="X"}` - Количество записей на камеру
- `axis_camera_storage_used_bytes_per_camera{camera_name="X"}` - Размер хранилища на камеру в байтах
- `axis_camera_last_recording_start_timestamp_seconds{camera_name="X"}` - Последнее время начала записи на камеру (unix timestamp)
- `axis_camera_last_recording_stop_timestamp_seconds{camera_name="X"}` - Последнее время окончания записи на камеру (unix timestamp)
- `axis_camera_oldest_recording_timestamp{camera_name="X"}` - Время самой старой записи на камеру (unix timestamp)
- `axis_camera_retention_days_per_camera{camera_name="X"}` - Время хранения в днях на камеру

### Метрики по записям
- `axis_camera_incomplete_recordings_total` - Количество незавершенных записей
- `axis_camera_avg_recording_size_bytes` - Средний размер записи в байтах
- `axis_camera_avg_recording_duration_seconds` - Средняя длительность записи в секундах
- `axis_camera_newest_recording_timestamp` - Время самой новой записи (unix timestamp)

### Метрики по устройствам
- `axis_camera_devices_by_manufacturer{manufacturer="X"}` - Количество устройств по производителям
- `axis_camera_devices_by_model{model="X"}` - Количество устройств по моделям

### Метрики по хранилищу
- `axis_camera_recordings_total_by_storage{storage_id="X"}` - Количество записей по хранилищам
- `axis_camera_storage_used_bytes_by_storage{storage_id="X"}` - Размер по хранилищам в байтах

### Служебные метрики
- `axis_camera_monitoring_last_update` - Время последнего обновления мониторинга (unix timestamp)

## Запуск скрипта

```powershell
# Базовый запуск
.\get_metrics.ps1

# С указанием параметров
.\get_metrics.ps1 -SourceDir "C:\ProgramData\Axis Communications\AXIS Camera Station Server" -TempDir "C:\temp\axis_monitoring" -ExportDir "C:\windows_exporter" -FirebirdPath "C:\Program Files\Firebird\Firebird_3_0\isql.exe"
```

## Структура данных

### ACS.FDB (основная база)
- **CAMERA** - информация о камерах (ID, NAME, IS_ENABLED, MANUFACTURER, MODEL)
- **DEVICE** - информация об устройствах (камеры, внешние устройства)
- **STORAGE** - информация о хранилищах
- **STORAGE_LOCAL_DISK** - настройки локального хранилища
- **STORAGE_NAS** - настройки сетевого хранилища
- **CAMERA_STORAGE** - связь камер с хранилищами

### ACS_RECORDINGS.FDB (база записей)
- **RECORDING** - метаданные записей
- **RECORDING_FILE** - файлы записей с размерами и временем (START_TIME, STOP_TIME, STORAGE_SIZE, IS_COMPLETE)

## Примеры использования метрик

### Мониторинг использования хранилища
```promql
# Общее использование хранилища в ГБ
axis_camera_storage_used_bytes / 1024 / 1024 / 1024

# Использование по камерам в МБ
axis_camera_storage_used_bytes_per_camera / 1024 / 1024
```

### Мониторинг активности камер
```promql
# Камеры без записей за последние 24 часа
axis_camera_last_recording_stop_timestamp_seconds < (time() - 86400)

# Средняя активность записей
rate(axis_camera_total_recordings[1h])
```

### Мониторинг качества записей
```promql
# Процент незавершенных записей
axis_camera_incomplete_recordings_total / axis_camera_total_recordings * 100

# Средняя длительность записи в минутах
axis_camera_avg_recording_duration_seconds / 60
```

### Мониторинг устройств
```promql
# Топ производителей устройств
topk(5, axis_camera_devices_by_manufacturer)

# Топ моделей устройств
topk(5, axis_camera_devices_by_model)
```

## Настройка Prometheus

Добавьте в конфигурацию Prometheus:

```yaml
scrape_configs:
  - job_name: 'axis_camera_station'
    static_configs:
      - targets: ['localhost:8080']  # или ваш веб-сервер
    metrics_path: '/metrics'
    file_sd_configs:
      - files:
        - 'axis_camera_metrics.txt'
```

## Автоматизация

Для автоматического обновления метрик создайте задачу в Windows Task Scheduler:

1. **Триггер**: Каждые 5 минут
2. **Действие**: Запуск PowerShell скрипта
3. **Команда**: `powershell.exe -ExecutionPolicy Bypass -File "C:\axis_fdb\get_metrics.ps1"`

## Устранение неполадок

### Ошибки подключения к базе данных
- Проверьте, что файлы ACS.FDB и ACS_RECORDINGS.FDB скопированы в C:\temp\axis_monitoring\
- Убедитесь, что Firebird установлен в C:\Program Files\Firebird\Firebird_3_0\

### Ошибки парсинга результатов
- Включите логирование в скрипте (см. DEBUG_GUIDE.md)
- Проверьте лог-файл на наличие ошибок SQL-запросов

### Пустые метрики
- Убедитесь, что в базах данных есть данные
- Проверьте права доступа к файлам баз данных
- Проверьте содержимое файла метрик: `Get-Content C:\windows_exporter\axis_camera_metrics.txt`

### Проверка работы скрипта
```powershell
# Проверить наличие файла метрик
Test-Path "C:\windows_exporter\axis_camera_metrics.txt"

# Посмотреть содержимое файла метрик
Get-Content "C:\windows_exporter\axis_camera_metrics.txt"

# Проверить размер файла метрик
(Get-Item "C:\windows_exporter\axis_camera_metrics.txt").Length
``` 