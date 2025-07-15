# airplay_project_plan.md

## 🎯 Project Overview
This project implements an AirPlay receiver application that emulates an Apple TV device. The system is designed to run on **Ubuntu Server 24.04**, deployed in a **VM within Proxmox 8.4**. The application allows an **iPhone 16 Pro (iOS 16)** to discover it over AirPlay, stream video/audio content to it, and exposes a **web interface** for:

✅ Real-time display of the AirPlay stream in a browser.
✅ Starting/stopping recording of the incoming stream into `.mp4` files.
✅ Browsing, playing, and downloading recorded videos.

All components will run as **separate Docker containers** orchestrated by Docker Compose.

---

## 🖥 System Architecture

### Components
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
   - Provides a REST API for frontend to control recording and fetch metadata.
   - Serves the live stream and recorded media.
   - Manages FFmpeg processes.

4. **Web Frontend (UI):**
   - A React or Svelte single-page app.
   - Displays the live stream.
   - Provides controls for recording and browsing past recordings.

---

## 📡 API Specification

### `POST /api/record/start`
- **Description:** Start recording the current AirPlay stream.
- **Request Body (JSON):**
  ```json
  {
    "filename": "airplay-20250715-204500.mp4",  // optional, auto-generate if not provided
    "quality": "high"                           // optional: "high" (default), "medium", "low"
  }
  ```
- **Response (JSON):**
  ```json
  {
    "status": "recording",
    "file": "airplay-20250715-204500.mp4",
    "startedAt": "2025-07-15T20:45:00Z"
  }
  ```
- **Errors:**
  - 409 Conflict: "Recording already in progress."
  - 500 Internal Server Error: "Failed to start recording."

### `POST /api/record/stop`
- **Description:** Stop the current recording.
- **Response (JSON):**
  ```json
  {
    "status": "stopped",
    "file": "airplay-20250715-204500.mp4",
    "duration": 45.3  // seconds
  }
  ```
- **Errors:**
  - 400 Bad Request: "No active recording to stop."

### `GET /api/records`
- **Description:** Get a list of recorded video files.
- **Response (JSON):**
  ```json
  [
    {
      "filename": "airplay-20250715-204500.mp4",
      "size": 12345678, // bytes
      "duration": 120.5, // seconds
      "createdAt": "2025-07-15T20:45:00Z"
    },
    {
      "filename": "airplay-20250716-101200.mp4",
      "size": 9876543,
      "duration": 90.0,
      "createdAt": "2025-07-16T10:12:00Z"
    }
  ]
  ```

### Authentication
- **Authentication is not required** for this project.
- Both API and web UI are designed to be accessible without any login or authorization.

---

## 🎨 UI/UX Design

### Live Stream Page
- Video player showing the AirPlay stream.
- Record toggle button:
  - Label: "Start Recording" → "Stop Recording".
  - Recording indicator (red dot) when active.
- Link to **Gallery** page.

### Gallery Page
- List of recorded files:
  - Filename, duration, size.
  - Play button to watch inline.
  - Download button.

*(Low-fidelity mockups to be added in `/ui-mockups/` directory.)*

---

## 🛡️ Error Handling & Edge Cases
- If FFmpeg fails to start:
  - API returns 500 error with message "FFmpeg process failed."
  - Log the exact command and error output.
- If disk space is low:
  - Reject new recording requests with 507 Insufficient Storage.
- If multiple iPhones connect:
  - **Support only one AirPlay stream at a time.**
  - Return 409 Conflict if a second stream is attempted.

---

## 📜 Logging Requirements
- Log all key operations in structured JSON format.
  Example:
  ```json
  {
    "timestamp": "2025-07-15T20:45:00Z",
    "level": "info",
    "event": "recording_started",
    "filename": "airplay-20250715-204500.mp4"
  }
  ```
- Levels: info, warning, error, debug.
- Log AirPlay connections/disconnections, API calls, and FFmpeg errors.

---

## ✅ Testing Requirements
- Unit tests for backend API handlers.
- Mock FFmpeg process for API tests.
- Frontend tests for UI state changes (record button, gallery list).
- Integration tests to simulate an AirPlay connection.
- Minimal test coverage: **80%** of backend code.

---

## ⚡ Scalability
- **Support only one AirPlay stream at a time.**
- No multi-stream support is planned in the initial version.

---

## ⚙ Backend Language
- **Preferred:** Go (due to simpler concurrency model, smaller binary size).
- Rust can be considered if existing team expertise is stronger there.

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

