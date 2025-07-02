#!/bin/bash

# Параметры для подключения к камере
USER=""
PASSWORD=""
HOST=""

# Параметры логирования (по умолчанию - минимальное логирование)
DEBUG_MODE="${DEBUG_MODE:-false}"
VERBOSE_MODE="${VERBOSE_MODE:-false}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Парсинг аргументов командной строки
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --user) USER="$2"; shift ;;
    --password) PASSWORD="$2"; shift ;;
    --host) HOST="$2"; shift ;;
    --debug) DEBUG_MODE="true"; shift ;;
    --verbose) VERBOSE_MODE="true"; shift ;;
    --log-level) LOG_LEVEL="$2"; shift ;;
  esac
  shift
done

# Экспортируем переменные окружения
export DEBUG_MODE
export VERBOSE_MODE
export LOG_LEVEL

echo "Starting people counter with logging settings:"
echo "  DEBUG_MODE: $DEBUG_MODE"
echo "  VERBOSE_MODE: $VERBOSE_MODE"
echo "  LOG_LEVEL: $LOG_LEVEL"

# Запускаем приложение с настройками логирования
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --log-level warning 