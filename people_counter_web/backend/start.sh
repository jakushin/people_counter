#!/bin/bash
USER=""
PASSWORD=""
HOST=""
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --user) USER="$2"; shift ;;
    --password) PASSWORD="$2"; shift ;;
    --host) HOST="$2"; shift ;;
  esac
  shift
done
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 