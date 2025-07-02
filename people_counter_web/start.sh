#!/bin/bash
# start.sh

# Парсинг аргументов
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

host=${host:-"172.25.109.148"}
port=${port:-"554"}
profile=${profile:-"stream1"}

if [[ -z "$user" || -z "$password" ]]; then
    echo "Usage: $0 --user <username> --password <password> [--host <host>] [--port <port>] [--profile <profile>]"
    exit 1
fi

export RTSP_URL="rtsp://${user}:${password}@${host}:${port}/axis-media/media.amp?streamprofile=${profile}"

# Запуск через Python 3, uvicorn внутри main.py
exec python3 main.py
