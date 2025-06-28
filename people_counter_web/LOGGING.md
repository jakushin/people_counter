# Управление логированием

## Обзор

Система логирования была оптимизирована для сокращения объема логов в продакшене. Теперь доступны три уровня детализации:

### Уровни логирования

1. **По умолчанию** - только важные события и ошибки
2. **VERBOSE_MODE** - расширенные логи для диагностики
3. **DEBUG_MODE** - полная отладочная информация

## Настройка через переменные окружения

### Docker Compose

```yaml
# docker-compose.yml
services:
  backend:
    environment:
      - DEBUG_MODE=false      # Включить полную отладку
      - VERBOSE_MODE=false    # Включить расширенные логи
      - LOG_LEVEL=INFO        # Уровень логирования (INFO, WARNING, ERROR)
```

### Командная строка

```bash
# Минимальное логирование (по умолчанию)
docker-compose up

# Расширенные логи
DEBUG_MODE=false VERBOSE_MODE=true docker-compose up

# Полная отладка
DEBUG_MODE=true VERBOSE_MODE=true docker-compose up

# Только ошибки
LOG_LEVEL=ERROR docker-compose up
```

### Прямой запуск

```bash
# Минимальное логирование
./start.sh

# Расширенные логи
VERBOSE_MODE=true ./start.sh

# Полная отладка
DEBUG_MODE=true ./start.sh

# С параметрами командной строки
./start.sh --verbose --debug --log-level DEBUG
```

## Категории логов

### Всегда логируются (все уровни)
- `[START]` - инициализация системы
- `ERROR` - ошибки
- `WARNING` - предупреждения

### VERBOSE_MODE=true
- `[API]` - API вызовы
- `[WS]` - WebSocket события
- `[VIDEO_STREAM]` - обработка видео (каждые 100 кадров)
- `[DETECT]` - детекция объектов
- `[MP_*]` - мультипроцессинг
- `[CROP]` - ROI обработка
- `[YOLO_*]` - YOLO логика
- `[MAIN]` - основной цикл (каждые 100 кадров)

### DEBUG_MODE=true
- Все логи из VERBOSE_MODE
- Детальная информация о системе
- Время обработки каждого кадра
- Состояние очередей мультипроцессинга
- Информация о потоках и процессах

## Ожидаемое сокращение объема логов

### До оптимизации
- ~50-100 строк логов в секунду
- Лог файл растет на ~1-2MB в минуту
- Много повторяющейся информации

### После оптимизации (по умолчанию)
- ~5-10 строк логов в минуту
- Лог файл растет на ~1-2MB в час
- Только важные события

### VERBOSE_MODE
- ~100-200 строк логов в минуту
- Лог файл растет на ~10-20MB в час
- Достаточно для диагностики

### DEBUG_MODE
- ~1000+ строк логов в минуту
- Лог файл растет на ~50-100MB в час
- Полная отладочная информация

## Рекомендации

### Продакшен
```yaml
environment:
  - DEBUG_MODE=false
  - VERBOSE_MODE=false
  - LOG_LEVEL=WARNING
```

### Тестирование/Диагностика
```yaml
environment:
  - DEBUG_MODE=false
  - VERBOSE_MODE=true
  - LOG_LEVEL=INFO
```

### Отладка
```yaml
environment:
  - DEBUG_MODE=true
  - VERBOSE_MODE=true
  - LOG_LEVEL=DEBUG
```

## Мониторинг размера лог файла

```bash
# Проверить размер лог файла
ls -lh app.log

# Просмотр последних записей
tail -f app.log

# Очистка лог файла (осторожно!)
> app.log

# Ротация логов (рекомендуется)
logrotate -f /etc/logrotate.d/people_counter
```

## Примеры логов

### Минимальный уровень
```
2024-01-15 10:30:00 - root - INFO - [START] CPU count: 8
2024-01-15 10:30:05 - root - INFO - [WS] WebSocket connection accepted
2024-01-15 10:35:00 - root - WARNING - [VIDEO_STREAM] Frame timing issue
```

### VERBOSE уровень
```
2024-01-15 10:30:00 - root - INFO - [START] CPU count: 8
2024-01-15 10:30:01 - root - INFO - [API] Video stream started successfully
2024-01-15 10:30:02 - root - INFO - [WS] WebSocket connection accepted
2024-01-15 10:30:03 - root - INFO - [VIDEO_STREAM] FPS: 9.14
2024-01-15 10:30:10 - root - INFO - [MAIN] Frame 100: Detect+prep: 0.142s
```

### DEBUG уровень
```
2024-01-15 10:30:00 - root - INFO - [START] CPU count: 8
2024-01-15 10:30:00 - root - INFO - [ENV] OMP_NUM_THREADS=8
2024-01-15 10:30:01 - root - INFO - [MP_INIT] Main PID: 1, num_workers: 4
2024-01-15 10:30:01 - root - INFO - [MP_INIT] Started worker 0, PID: 123
2024-01-15 10:30:02 - root - INFO - [DETECT] [MP_DETECTOR] sending frame idx: 1
2024-01-15 10:30:02 - root - INFO - [MP_QUEUE] Input queue: 0, Output queue: 0
2024-01-15 10:30:02 - root - INFO - [CROP] ROI crop: x_min=555, x_max=687
2024-01-15 10:30:02 - root - INFO - [YOLO] Using imgsz=256 for crop 132x250
2024-01-15 10:30:02 - root - INFO - [DETECTOR] Inference: 0.040s, Draw: 0.001s
``` 