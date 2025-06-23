import cv2
import threading
import time
import logging

class RTSPReader:
    def __init__(self, url, line_start, line_end, target_width, model):
        self.url = url
        self.line_start = line_start
        self.line_end = line_end
        self.target_width = target_width
        self.model = model

        self.frame = None
        self.running = False

        self.fps = 0.0
        self.frame_width = 0
        self.frame_height = 0

    def start(self):
        self.running = True
        self.thread = threading.Thread(target=self._reader_thread, daemon=True)
        self.thread.start()

    def stop(self):
        self.running = False
        if hasattr(self, 'thread'):
            self.thread.join()

    def _reader_thread(self):
        cap = cv2.VideoCapture(self.url)
        if not cap.isOpened():
            logging.error(f"Failed to open RTSP stream: {self.url}")
            return

        logging.info(f"RTSP stream opened successfully: {self.url}")

        prev_time = time.time()
        frame_count = 0

        while self.running:
            ret, frame = cap.read()
            if not ret:
                logging.warning("Frame not read")
                time.sleep(0.1)
                continue

            frame_count += 1
            now = time.time()
            if now - prev_time >= 1.0:
                self.fps = frame_count / (now - prev_time)
                frame_count = 0
                prev_time = now

            # Resize
            height, width = frame.shape[:2]
            self.frame_width = width
            self.frame_height = height
            scale = self.target_width / width
            new_height = int(height * scale)
            frame_resized = cv2.resize(frame, (self.target_width, new_height))

            # Draw line + points
            cv2.line(frame_resized, self.line_start, self.line_end, (0, 255, 0), 2)
            cv2.circle(frame_resized, self.line_start, 8, (0, 0, 255), -1)
            cv2.circle(frame_resized, self.line_end, 8, (0, 0, 255), -1)

            # Add diagnostics
            diag_text = f"FPS: {self.fps:.2f}\nRES: {self.frame_width}x{self.frame_height}\nLine: {self.line_start}-{self.line_end}"
            y_offset = 20
            for line in diag_text.split('\n'):
                cv2.putText(frame_resized, line, (self.target_width - 400, y_offset),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
                y_offset += 25

            self.frame = frame_resized

        cap.release()
        logging.info("RTSP reader stopped")

    def frame_generator(self):
        while True:
            if self.frame is None:
                time.sleep(0.05)
                continue

            ret, jpeg = cv2.imencode('.jpg', self.frame)
            if not ret:
                continue

            yield (b'--frame\r\n'
                   b'Content-Type: image/jpeg\r\n\r\n' + jpeg.tobytes() + b'\r\n')
