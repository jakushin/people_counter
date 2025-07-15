# Airplay Project Plan

## 🎯 Project Overview

This project implements an AirPlay receiver application that emulates an Apple TV device. The system is designed to run on **Ubuntu Server 24.04**, deployed in a **VM within Proxmox 8.4**. The application allows an **iPhone 16 Pro (iOS 16)** to discover it over AirPlay, stream video/audio content to it, and exposes a **web interface** for:

✅ Real-time display of the AirPlay stream in a browser. ✅ Starting/stopping recording of the incoming stream into `.mp4` files. ✅ Browsing, playing, and downloading recorded videos.

All components will run as **separate Docker containers** orchestrated by Docker Compose.

---

## 🖥 System Architecture

The application is composed of four major parts:

1. **AirPlay Receiver (UxPlay):**

   - Acts as a virtual Apple TV.
   - Discovers iPhones over mDNS (Bonjour) using **Avahi**.
   - Decodes video/audio streams received from iOS devices.
   - Based on [UxPlay](https://github.com/FDH2/UxPlay), a mature open-source AirPlay implementation for Unix systems.

2. **Media Transcoder (FFmpeg):**

   - Captures the framebuffer video and loopback audio output from UxPlay.
   - Streams video to the frontend in real-time using **MJPEG** or **HLS**.
   - Records incoming streams into `.mp4` files on disk.
   - Reference: [FFmpeg Documentation](https://ffmpeg.org/documentation.html)

3. **Web Backend (API):**

   - Provides a REST API for frontend to start/stop recording.
   - Serves the live stream and recorded media.
   - Manages processes for FFmpeg.
   - Implemented in Go or Rust for performance.

4. **Web Frontend (UI):**

   - A React or Svelte single-page app.
   - Displays the live stream.
   - Provides controls for recording and browsing past recordings.

---

## ⚙ Technical Constraints

- **Network:**

  - AirPlay relies on mDNS (Bonjour), which requires multicast support.
  - The AirPlay receiver container will use `network_mode: host` to ensure the iPhone can discover it.
  - Web frontend should be accessible over the Internet.

- **Recording Path:**

  - All recordings saved in `/var/airplay-records`.
  - Filename format: `airplay-YYYYMMDD-HHMMSS.mp4`.

- **Dependencies:**

  - AirPlay: [UxPlay](https://github.com/FDH2/UxPlay)
  - mDNS: [Avahi](https://avahi.org/)
  - Media processing: [FFmpeg](https://ffmpeg.org/)

- **Reuse of Libraries:**

  - Must rely on existing libraries and projects (UxPlay, FFmpeg).
  - Avoid reinventing AirPlay or mDNS protocols.

---

## 🗂 Dockerized Architecture

```yaml
version: "3.8"
services:
  airplay:
    build: ./airplay
    network_mode: host
    devices:
      - "/dev/fb0:/dev/fb0"
      - "/dev/snd:/dev/snd"
    volumes:
      - "/var/run/dbus:/var/run/dbus"
      - "/var/run/avahi-daemon/socket:/var/run/avahi-daemon/socket"
      - "airplay-records:/var/airplay-records"
    restart: unless-stopped

  web:
    build: ./web
    ports:
      - "8080:80"
    volumes:
      - "airplay-records:/var/airplay-records"
    restart: unless-stopped

volumes:
  airplay-records:
```

- **AirPlay Service:** Uses host network for mDNS and exposes AirPlay service via Avahi.
- **Web Service:** Serves frontend and APIs; accessible via `http://<host-ip>:8080`.
- **Shared Volume:** `airplay-records` volume is shared to store recorded files.

---

## 🚀 Implementation Plan (Split into Stages)

1. **Prototype AirPlay Receiver:**

   - Build UxPlay in a Docker container.
   - Test mDNS discovery from iPhone.
   - Validate video rendering to framebuffer (`/dev/fb0`) and audio output to ALSA loopback.

2. **Add Media Capture:**

   - Use FFmpeg to read `/dev/fb0` and loopback audio.
   - Stream video in real-time using MJPEG over HTTP.
   - Test latency and optimize buffer sizes.

3. **Backend API:**

   - Implement endpoints:
     - `POST /api/record/start`
     - `POST /api/record/stop`
     - `GET /api/records`
   - Integrate with FFmpeg to control recording processes.

4. **Frontend:**

   - Create UI with React/Svelte.
   - Display MJPEG stream (`<img src="/stream.mjpeg">`).
   - Add buttons to start/stop recording and list recorded files.

5. **Packaging and Deployment:**

   - Write `deploy.sh` to:
     - Stop/remove all containers and images.
     - Clean volumes and cache.
     - Install host dependencies.
     - Rebuild and start containers.

---

## 📝 Best Practices

1. **Modularity:**

   - Split code into small, testable modules.
   - Avoid large monolithic files (split backend, frontend, and service logic).

2. **Cursor Rules:**

   - Always break tasks into smaller sub-tasks.
   - Keep source files small and focused.
   - Maintain strict separation between backend and frontend concerns.

3. **Testing:**

   - Add logs for key operations.
   - Test AirPlay discovery and streaming on multiple devices.

4. **External References:**

   - UxPlay GitHub: [https://github.com/FDH2/UxPlay](https://github.com/FDH2/UxPlay)
   - FFmpeg Filters: [https://ffmpeg.org/ffmpeg-filters.html](https://ffmpeg.org/ffmpeg-filters.html)
   - Avahi Tutorial: [https://wiki.archlinux.org/title/Avahi](https://wiki.archlinux.org/title/Avahi)
   - Docker Networking: [https://docs.docker.com/network/](https://docs.docker.com/network/)

---

## 📂 Deployment Script Example

```bash
#!/bin/bash
echo "Stopping and cleaning up Docker..."
docker-compose down
docker system prune -af
docker volume prune -f

echo "Installing host dependencies..."
sudo apt update
sudo apt install -y avahi-daemon ffmpeg docker-compose
sudo modprobe snd_aloop

echo "Rebuilding and starting containers..."
docker-compose build
docker-compose up -d
```

---

This plan provides detailed guidance for developers and helps IDE tools like Cursor follow consistent practices.

