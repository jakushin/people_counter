# rtsp_reader.py
import cv2
import threading
import time
from ultralytics import YOLO

class RTSPReader:
    def __init__(
        self,
        url: str,
        line_start: tuple[int,int],
        line_end: tuple[int,int],
        target_width: int,
        model: YOLO,
    ):
        self.url = url
        self.line_start = line_start
        self.line_end = line_end
        self.target_width = target_width
        self.model = model

        self.frame = None
        self.fps = 0.0
        self.frame_width = target_width
        self.frame_height = 0
        self.running = False

    def start(self) -> None:
        if self.running:
            return
        self.running = True
        self.thread = threading.Thread(target=self._reader_loop, daemon=True)
        self.thread.start()

    def stop(self) -> None:
        self.running = False
        if hasattr(self, "thread"):
            self.thread.join()

    def _reader_loop(self) -> None:
        cap = cv2.VideoCapture(self.url)
        if not cap.isOpened():
            raise RuntimeError(f"Cannot open RTSP stream: {self.url}")

        prev_time = time.time()
        frame_count = 0

        while self.running:
            ret, frame = cap.read()
            if not ret:
                time.sleep(0.1)
                continue

            # Расчёт FPS
            frame_count += 1
            now = time.time()
            if now - prev_time >= 1.0:
                self.fps = frame_count / (now - prev_time)
                frame_count = 0
                prev_time = now

            # Resize
            h, w = frame.shape[:2]
            scale = self.target_width / w
            new_h = int(h * scale)
            frame = cv2.resize(frame, (self.target_width, new_h))
            self.frame_width, self.frame_height = self.target_width, new_h

            # Нарисовать линию (точки через HTML)
            cv2.line(frame, self.line_start, self.line_end, (0,255,0), 2)

            self.frame = frame

        cap.release()

    def frame_generator(self):
        """Генератор JPEG-кадров для StreamingResponse."""
        while True:
            if self.frame is None:
                time.sleep(0.05)
                continue
            ret, jpeg = cv2.imencode('.jpg', self.frame)
            if not ret:
                continue
            yield (
                b'--frame\r\n'
                b'Content-Type: image/jpeg\r\n\r\n' +
                jpeg.tobytes() +
                b'\r\n'
            )
