# rtsp_reader.py
import cv2
import threading
import time
from ultralytics import YOLO

class RTSPReader:
    def __init__(self, url, line_start, line_end, target_width, model):
        self.url = url
        self.line_start = line_start
        self.line_end = line_end
        self.target_width = target_width
        self.model = model

        self.frame = None
        self.fps = 0.0
        self.bitrate = 0.0
        self.frame_width = target_width
        self.frame_height = 0
        self.src_width = 0
        self.src_height = 0
        self.running = False

    def start(self):
        if self.running:
            return
        self.running = True
        self.thread = threading.Thread(target=self._reader_loop, daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False
        if hasattr(self, "thread"):
            self.thread.join()

    def _reader_loop(self):
        cap = cv2.VideoCapture(self.url)
        if not cap.isOpened():
            raise RuntimeError(f"Cannot open RTSP: {self.url}")
        self.src_width  = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        self.src_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

        prev = time.time()
        cnt = 0
        while self.running:
            ret, frame = cap.read()
            if not ret:
                time.sleep(0.1)
                continue

            # FPS
            cnt += 1
            now = time.time()
            if now - prev >= 1.0:
                self.fps = cnt / (now - prev)
                cnt = 0
                prev = now

            # Resize for display
            h, w = frame.shape[:2]
            scale = self.target_width / w
            nh = int(h * scale)
            disp = cv2.resize(frame, (self.target_width, nh))
            self.frame_width, self.frame_height = self.target_width, nh

            # **Больше не рисуем линию здесь** — всё в браузере
            self.frame = disp

        cap.release()

    def frame_generator(self):
        while True:
            if self.frame is None:
                time.sleep(0.05)
                continue
            ret, jpeg = cv2.imencode('.jpg', self.frame)
            if not ret:
                continue
            data = jpeg.tobytes()
            self.bitrate = len(data) * self.fps * 8 / 1000
            yield (
                b'--frame\r\n'
                b'Content-Type: image/jpeg\r\n\r\n' +
                data +
                b'\r\n'
            )
