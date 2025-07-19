#!/bin/bash

export DISPLAY=:0

# Функция для логирования с временными метками
log_with_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [start.sh] $1"
}

# Функция для детальной диагностики DISPLAY (упрощенная)
diagnose_display() {
    log_with_timestamp "=== ДЕТАЛЬНАЯ ДИАГНОСТИКА DISPLAY ==="
    log_with_timestamp "DISPLAY=$DISPLAY"
    
    # Проверяем переменные окружения X11
    log_with_timestamp "X11 environment variables:"
    env | grep -E "(DISPLAY|XAUTHORITY|XDG_)" | sort || log_with_timestamp "No X11 env vars found"
    
    # Проверяем X11 сокеты
    log_with_timestamp "X11 sockets in /tmp/.X11-unix/:"
    ls -la /tmp/.X11-unix/ 2>/dev/null || log_with_timestamp "No X11 sockets found"
    
    # Проверяем Xauthority
    log_with_timestamp "Xauthority info:"
    if [ -f "$XAUTHORITY" ]; then
        log_with_timestamp "XAUTHORITY file exists: $XAUTHORITY"
    else
        log_with_timestamp "No XAUTHORITY file found"
    fi
}

# Функция для мониторинга окон в реальном времени
monitor_windows() {
    log_with_timestamp "=== МОНИТОРИНГ ОКОН ==="
    
    # Создаем фоновый процесс для мониторинга окон
    (
        while true; do
            WINDOW_COUNT=$(xwininfo -root -tree -display $DISPLAY 2>/dev/null | wc -l)
            if [ $? -eq 0 ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [window-monitor] Total windows: $WINDOW_COUNT"
                
                # Ищем окна UxPlay
                UXPLAY_WINDOWS=$(xwininfo -root -tree -display $DISPLAY 2>/dev/null | grep -i "uxplay\|airplay" | wc -l)
                if [ $UXPLAY_WINDOWS -gt 0 ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [window-monitor] UxPlay windows found: $UXPLAY_WINDOWS"
                    xwininfo -root -tree -display $DISPLAY 2>/dev/null | grep -i "uxplay\|airplay"
                fi
            fi
            sleep 5
        done
    ) &
    MONITOR_PID=$!
    log_with_timestamp "Window monitor started with PID $MONITOR_PID"
}

# Диагностическая информация
log_with_timestamp "=== ДИАГНОСТИКА ЗАПУСКА ==="
log_with_timestamp "USER=$(whoami)"
log_with_timestamp "PWD=$(pwd)"
log_with_timestamp "DATE=$(date)"
log_with_timestamp "X11 processes:"
ps aux | grep -E "(Xvfb|X11)" || log_with_timestamp "No X11 processes found"

# Создать Xauthority, если его нет
if [ ! -f /root/.Xauthority ]; then
  touch /root/.Xauthority
  xauth generate :0 . trusted
  xauth add :0 . $(mcookie)
fi
export XAUTHORITY=/root/.Xauthority
export XDG_RUNTIME_DIR=/tmp/runtime-root
mkdir -p $XDG_RUNTIME_DIR

if [ -e /run/dbus/pid ]; then
  log_with_timestamp "Removing stale /run/dbus/pid"
  rm -f /run/dbus/pid
fi

XVFB_DISPLAY=":0"
XVFB_RES="1920x1080x24"

# Удаляем lock-файл Xvfb, если он остался
if [ -f /tmp/.X0-lock ]; then
  log_with_timestamp "Removing stale /tmp/.X0-lock before starting Xvfb..."
  rm -f /tmp/.X0-lock
fi

# Запускаем Xvfb и логируем результат
XVFB_LOG=/tmp/xvfb_start.log
Xvfb :0 -screen 0 1920x1080x24 > "$XVFB_LOG" 2>&1 &
XVFB_PID=$!
sleep 2
if ps -p $XVFB_PID > /dev/null; then
  log_with_timestamp "Xvfb started successfully with PID $XVFB_PID."
else
  log_with_timestamp "Xvfb failed to start! Log output:"
  cat "$XVFB_LOG"
  exit 1
fi

# Запуск dbus-daemon
if pgrep -x "dbus-daemon" > /dev/null; then
  log_with_timestamp "dbus-daemon already running"
else
  log_with_timestamp "Starting dbus-daemon..."
  dbus-daemon --system --fork
fi

# Запуск openbox (window manager)
if pgrep -x "openbox" > /dev/null; then
  log_with_timestamp "openbox already running"
else
  log_with_timestamp "Starting openbox..."
  openbox --sm-disable &
  sleep 1
fi

# Запуск unclutter (скрытие курсора)
if pgrep -x "unclutter" > /dev/null; then
  log_with_timestamp "unclutter already running"
else
  log_with_timestamp "Starting unclutter (hide cursor)..."
  unclutter -idle 3 &
  sleep 1
fi

# Проверка и запуск avahi-daemon
if pgrep -x "avahi-daemon" > /dev/null; then
  log_with_timestamp "avahi-daemon already running"
else
  log_with_timestamp "Checking avahi-daemon..."
  log_with_timestamp "Starting avahi-daemon..."
  avahi-daemon --no-drop-root --no-chroot &
  sleep 2
fi

# Выполняем упрощенную диагностику DISPLAY
diagnose_display

# Ждем готовности X11 дисплея
log_with_timestamp "Waiting for X11 display to be ready..."
for i in {1..10}; do
  if xdpyinfo -display :0 >/dev/null 2>&1; then
    log_with_timestamp "X11 display :0 is ready"
    break
  fi
  log_with_timestamp "X11 not ready, waiting... ($i/10)"
  sleep 2
done

# Проверяем что X11 действительно готов
if ! xdpyinfo -display :0 >/dev/null 2>&1; then
  log_with_timestamp "ERROR: X11 display :0 is not available!"
  exit 1
fi

# Проверяем текущие окна перед запуском UxPlay
log_with_timestamp "Current windows before UxPlay:"
xwininfo -root -tree -display $DISPLAY 2>/dev/null | head -20 || log_with_timestamp "Failed to get window info"

# Запуск UxPlay с детальными логами
if pgrep -x "uxplay" > /dev/null; then
  log_with_timestamp "UxPlay already running"
else
  log_with_timestamp "Starting UxPlay on DISPLAY=$DISPLAY..."
  
  # Создаем файл для логов UxPlay в shared volume
  UXPLAY_LOG=/var/log/appletv/uxplay.log
  log_with_timestamp "UxPlay logs will be saved to $UXPLAY_LOG"
  
  # Тестируем UxPlay с help для проверки
  log_with_timestamp "Testing UxPlay installation..."
  uxplay -h > /tmp/uxplay_help.log 2>&1
  
  # Проверяем GStreamer плагины
  log_with_timestamp "Checking GStreamer plugins..."
  
  # Настраиваем X11 окружение для headless режима
  log_with_timestamp "Setting up X11 environment for headless mode..."
  
  # Устанавливаем необходимые переменные окружения
  export DISPLAY=:0
  export XAUTHORITY=/root/.Xauthority
  export XDG_RUNTIME_DIR=/tmp/runtime-root
  
  # Проверяем что Xvfb работает на :0 (backend ожидает именно :0)
  if ! DISPLAY=:0 xdpyinfo >/dev/null 2>&1; then
    log_with_timestamp "ERROR: X server on :0 is not accessible!"
    log_with_timestamp "Xvfb status:"
    ps aux | grep -i xvfb || log_with_timestamp "No Xvfb process found"
    exit 1
  fi
  
  # В headless режиме используем более стабильный видео sink
  # ИСПРАВЛЕНИЕ: пробуем xvimagesink (более стабилен), затем ximagesink с параметрами
  if gst-inspect-1.0 xvimagesink > /dev/null 2>&1; then
    log_with_timestamp "Using xvimagesink for headless mode (Xvfb compatible) - more stable"
    VIDEO_SINK="xvimagesink force-aspect-ratio=false"
  elif gst-inspect-1.0 ximagesink > /dev/null 2>&1; then
    log_with_timestamp "Using ximagesink for headless mode (Xvfb compatible) with forced window creation"
    VIDEO_SINK="ximagesink force-aspect-ratio=false sync=false"
  else
    log_with_timestamp "ERROR: Neither xvimagesink nor ximagesink available!"
    exit 1
  fi
  
  # Проверяем видео декодеры для UxPlay
  if ! gst-inspect-1.0 avdec_h264 > /dev/null 2>&1; then
    log_with_timestamp "WARNING: GStreamer avdec_h264 plugin NOT available - using software decoding"
  else
    log_with_timestamp "SUCCESS: GStreamer avdec_h264 plugin available for hardware decoding"
  fi
  
  # Проверяем аудио плагины
  if ! gst-inspect-1.0 pulsesink > /dev/null 2>&1; then
    log_with_timestamp "WARNING: GStreamer pulsesink plugin NOT available - using default audio"
  else
    log_with_timestamp "SUCCESS: GStreamer pulsesink plugin available"
  fi
  
  log_with_timestamp "Selected video sink: $VIDEO_SINK"
  
  # Проверяем доступность UxPlay
  log_with_timestamp "UxPlay version check..."
  uxplay -v > /tmp/uxplay_version.log 2>&1 || log_with_timestamp "UxPlay version check failed"
  
  # Запускаем мониторинг окон
  monitor_windows
  
  # Запускаем UxPlay с детальными логами и правильными параметрами
  log_with_timestamp "Starting UxPlay with verbose logging and debug mode..."
  
  # Добавляем временную метку в начало логов UxPlay
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] UxPlay starting with DISPLAY=$DISPLAY and VIDEO_SINK=$VIDEO_SINK..." > "$UXPLAY_LOG"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] UxPlay parameters: -d (debug) -vs $VIDEO_SINK -s 1920x1080 -n AppleTV" >> "$UXPLAY_LOG"
  
  # Запускаем UxPlay с правильными переменными окружения для headless режима
  log_with_timestamp "UxPlay command: DISPLAY=:0 XAUTHORITY=/root/.Xauthority uxplay -d -vs $VIDEO_SINK -s 1920x1080 -n \"AppleTV (Backend)\""
  
  # === ПРИНУДИТЕЛЬНЫЙ СБРОС GSTREAMER PIPELINE ===
  log_with_timestamp "Clearing GStreamer cache and X11 state before UxPlay start..."
  
  # Очищаем GStreamer registry и кэш
  rm -rf /root/.cache/gstreamer-1.0/* 2>/dev/null || true
  rm -rf /tmp/gst-* 2>/dev/null || true
  
  # Принудительно убиваем старые GStreamer процессы
  pkill -f gst-launch 2>/dev/null || true
  pkill -f ximagesink 2>/dev/null || true
  pkill -f xvimagesink 2>/dev/null || true
  sleep 1
  
  # Сбрасываем X11 кэш окон
  xhost + 2>/dev/null || true
  xwininfo -root -tree -display :0 >/dev/null 2>&1 || true
  
  log_with_timestamp "GStreamer and X11 state cleared, starting UxPlay..."
  
  # Устанавливаем переменные окружения для текущего процесса
  # Полностью перенаправляем UxPlay логи только в файл, НЕ в stdout контейнера
  env DISPLAY=:0 XAUTHORITY=/root/.Xauthority XDG_RUNTIME_DIR=/tmp/runtime-root \
    GST_DEBUG=3 GST_REGISTRY_FORK=no \
    uxplay -d -vs $VIDEO_SINK -s 1920x1080 -n "AppleTV (Backend)" > "$UXPLAY_LOG" 2>&1 &
  UXPLAY_PID=$!
  
  # Ждем дольше для запуска UxPlay и мониторим окна
  log_with_timestamp "Waiting for UxPlay to start and create window..."
  
  # UxPlay логи полностью изолированы в файл, мониторинг отключен
  
  # === УЛУЧШЕННАЯ RETRY ЛОГИКА ДЛЯ СОЗДАНИЯ ОКОН ===
  RETRY_COUNT=30  # Увеличиваем до 30 попыток
  WINDOW_RETRY_DELAY=2  # Задержка между проверками
  
  for i in $(seq 1 $RETRY_COUNT); do
    if ps -p $UXPLAY_PID > /dev/null; then
      log_with_timestamp "UxPlay process is running (check $i/$RETRY_COUNT)"
      
      # Проверяем создались ли окна
      WINDOW_COUNT=$(xwininfo -root -tree -display :0 2>/dev/null | wc -l)
      UXPLAY_WINDOWS=$(xwininfo -root -tree -display :0 2>/dev/null | grep -i "uxplay\|airplay" | wc -l)
      
      log_with_timestamp "Windows total: $WINDOW_COUNT, UxPlay windows: $UXPLAY_WINDOWS"
      
      # UxPlay логи доступны только в файле $UXPLAY_LOG
      
      if [ $UXPLAY_WINDOWS -gt 0 ]; then
        log_with_timestamp "✅ UxPlay window(s) detected!"
        xwininfo -root -tree -display :0 2>/dev/null | grep -i "uxplay\|airplay"
        break
      fi
      
      # RETRY ЛОГИКА: Каждые 10 попыток пробуем рестарт GStreamer
      if [ $((i % 10)) -eq 0 ] && [ $i -lt $RETRY_COUNT ]; then
        log_with_timestamp "⚠️ Retry $i: No windows after 10 attempts, forcing GStreamer refresh..."
        
        # Посылаем SIGUSR1 UxPlay для сброса GStreamer (если поддерживается)
        kill -USR1 $UXPLAY_PID 2>/dev/null || true
        
        # Принудительно очищаем GStreamer кэш снова
        rm -rf /tmp/gst-* 2>/dev/null || true
        
        log_with_timestamp "GStreamer refresh completed, continuing checks..."
      fi
      
             sleep $WINDOW_RETRY_DELAY
    else
      log_with_timestamp "❌ UxPlay process has stopped at check $i/$RETRY_COUNT"
      break
    fi
  done
  
  # === ФИНАЛЬНАЯ ДИАГНОСТИКА И РЕШЕНИЕ ПРОБЛЕМ ===
  FINAL_UXPLAY_WINDOWS=$(xwininfo -root -tree -display :0 2>/dev/null | grep -i "uxplay\|airplay" | wc -l)
  
  if [ $FINAL_UXPLAY_WINDOWS -eq 0 ]; then
    log_with_timestamp "⚠️ WARNING: No UxPlay windows created after $RETRY_COUNT attempts!"
    log_with_timestamp "Attempting emergency UxPlay restart with fallback video sink..."
    
    # Убиваем текущий UxPlay
    kill $UXPLAY_PID 2>/dev/null || true
    sleep 2
    
    # Пробуем аварийный перезапуск с fallback sink
    FALLBACK_SINK="fakesink"
    if gst-inspect-1.0 autovideosink > /dev/null 2>&1; then
      FALLBACK_SINK="autovideosink"
    fi
    
    log_with_timestamp "Emergency restart with fallback sink: $FALLBACK_SINK"
    env DISPLAY=:0 XAUTHORITY=/root/.Xauthority XDG_RUNTIME_DIR=/tmp/runtime-root \
      GST_DEBUG=2 GST_REGISTRY_FORK=no \
      uxplay -d -vs $FALLBACK_SINK -s 1920x1080 -n "AppleTV (Backend)" >> "$UXPLAY_LOG" 2>&1 &
    UXPLAY_PID=$!
    
    sleep 5
    EMERGENCY_WINDOWS=$(xwininfo -root -tree -display :0 2>/dev/null | grep -i "uxplay\|airplay" | wc -l)
    log_with_timestamp "Emergency restart result: $EMERGENCY_WINDOWS UxPlay windows found"
  else
    log_with_timestamp "✅ SUCCESS: $FINAL_UXPLAY_WINDOWS UxPlay window(s) are ready!"
  fi
  
  # Финальная проверка процесса UxPlay
  if ps -p $UXPLAY_PID > /dev/null; then
    log_with_timestamp "🎯 UxPlay started successfully with PID $UXPLAY_PID"
    log_with_timestamp "📝 UxPlay logs are available in $UXPLAY_LOG"
  else
    log_with_timestamp "❌ CRITICAL: UxPlay process failed to start properly"
    log_with_timestamp "📝 Check UxPlay error logs in $UXPLAY_LOG"
    
    # Останавливаем мониторинг окон
    kill $MONITOR_PID 2>/dev/null
    exit 1
  fi
fi

# Пример запуска FFmpeg для захвата видео с Xvfb
# ffmpeg -f x11grab -video_size 1920x1080 -i :0 -c:v libx264 /var/airplay-records/airplay-$(date +%Y%m%d-%H%M%S).mp4 &

log_with_timestamp "Container is running for debug. Press Ctrl+C to exit."
log_with_timestamp "All services should be running now. Waiting indefinitely..."
log_with_timestamp "Window monitor is running in background (PID $MONITOR_PID)"
tail -f /dev/null 