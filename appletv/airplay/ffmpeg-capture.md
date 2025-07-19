# FFmpeg Capture Scheme

- Video: захват с /dev/fb0 (framebuffer)
- Audio: захват с ALSA loopback (snd_aloop)

Пример команды (будет использоваться backend):

```bash
ffmpeg -f fbdev -framerate 30 -i /dev/fb0 -f alsa -i hw:Loopback,1 -c:v libx264 -preset ultrafast -c:a aac -strict -2 output.mp4
```

Для MJPEG стрима в браузер:

```bash
ffmpeg -f fbdev -framerate 10 -i /dev/fb0 -vf scale=1280:720 -f mjpeg http://backend:8080/api/stream
``` 