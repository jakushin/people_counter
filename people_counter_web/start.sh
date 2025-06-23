#!/bin/bash

# Парсинг аргументов командной строки
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --user)     user="$2"; shift ;;
        --password) password="$2"; shift ;;
        --host)     host="$2"; shift ;;
        --port)     port="$2"; shift ;;
        --profile)  profile="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Значения по умолчанию
host=${host:-"172.25.109.148"}
port=${port:-"554"}
profile=${profile:-"stream1"}

# Проверка обязательных параметров
if [[ -z "$user" || -z "$password" ]]; then
    echo "Usage: $0 --user <username> --password <password> [--host <host>] [--port <port>] [--profile <profile>]"
    exit 1
fi

# Формируем RTSP_URL
export RTSP_URL="rtsp://${user}:${password}@${host}:${port}/axis-media/media.amp?streamprofile=${profile}"

# Запускаем приложение через Python 3
exec python3 main.py
