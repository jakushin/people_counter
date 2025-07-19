# AppleTV Frontend (React)

## Features
- Live AirPlay stream (MJPEG)
- Start/stop recording
- Gallery: play, download, delete recordings
- Auto-updating UI

## Development

```bash
cd frontend
npm install
npm run dev
```

Open http://localhost:5173

## Production build (Docker)

```bash
docker-compose up --build frontend
```

App will be available at http://localhost (port 80 in container)

## Pages

### Live Stream
- Shows live AirPlay stream
- Start/stop recording
- Recording status auto-updates

### Gallery
- List of all .mp4 recordings
- Play inline, download, or delete any file
- List auto-updates after recording or deletion 