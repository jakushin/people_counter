используй всегда готовые библиотеки по максимуму, не надо писать своих

используем проект uxplay и собираем его из исходного кода
делаем всё в одном docker контейнере, чтобы не было X11 проблем с доступом
для отобраржения видео используем webtrc + нужно реализовать сигналы: что пользователь нажал, подключился или отключился от uxplay
нужно использовать context7 mcp, Editor MCP и memory mcp
debug console браузера очень помогала
при решении проблем, надо писать не потеряй контекст
время + timezone
желательно, чтобы каждый компонент писал в свой log файл с временными метками

если javastript, то нужно обновлять версию, чтобы браузер не использовал кэш



# AppleTV AirPlay Receiver Project

This project implements an AirPlay receiver, media transcoder, REST API backend, and React frontend, all orchestrated via Docker Compose. See airplay_project_plan.md for full requirements.

> **Note:** `avahi-daemon` must run only inside the `airplay` container. Do not run avahi-daemon on the host system simultaneously, as this may cause mDNS/Bonjour conflicts.

## Features
- Live AirPlay stream in browser (MJPEG)
- Start/stop recording to .mp4 files
- Browse, play, download, and delete recordings
- All services run in Docker containers
- No authentication, open for LAN use

## Quick Start

```bash
cd appletv
./deploy.sh
```

- Web UI: http://localhost (default)
- API: http://localhost:8080

## Live Stream
- Main page shows live AirPlay stream (MJPEG, low latency)
- Start/stop recording with one button
- Recording status auto-updates

## Gallery
- List of all recorded .mp4 files
- Play inline, download, or delete any file
- List auto-updates after recording or deletion

## API Endpoints

### Health
- `GET /api/health` — health check

### Recording
- `POST /api/record/start` — start recording
- `POST /api/record/stop` — stop recording
- `GET /api/record/status` — get current recording status

### Files
- `GET /api/records` — list all recordings
- `GET /api/records/:filename` — download file
- `DELETE /api/records/:filename` — delete file
- `GET /api/stream` — MJPEG live stream

## Deployment
- All services run in Docker Compose
- See `deploy.sh` for full deployment steps

## Requirements
- Ubuntu 24.04, Docker, ffmpeg, avahi-daemon
- x86_64 only

## Notes
- No authentication, no cloud integration
- All logs in English, output to stdout/stderr
- See airplay_project_plan.md for full architecture 