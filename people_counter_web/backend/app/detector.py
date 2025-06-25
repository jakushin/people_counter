import cv2
import numpy as np
import logging
from ultralytics import YOLO
import sys
import contextlib
import os

@contextlib.contextmanager
def suppress_all_output():
    # Подавляет stdout/stderr для Python и C/C++ (fd 1 и 2)
    with open(os.devnull, 'w') as devnull:
        old_stdout = sys.stdout
        old_stderr = sys.stderr
        old_fd1 = os.dup(1)
        old_fd2 = os.dup(2)
        sys.stdout = devnull
        sys.stderr = devnull
        os.dup2(devnull.fileno(), 1)
        os.dup2(devnull.fileno(), 2)
        try:
            yield
        finally:
            sys.stdout = old_stdout
            sys.stderr = old_stderr
            os.dup2(old_fd1, 1)
            os.dup2(old_fd2, 2)
            os.close(old_fd1)
            os.close(old_fd2)

# Подавить OpenCV/ffmpeg логи
os.environ['OPENCV_LOG_LEVEL'] = 'SILENT'
os.environ['OPENCV_FFMPEG_DEBUG'] = '0'
cv2.setLogLevel(0)

class PersonDetector:
    def __init__(self):
        try:
            with suppress_all_output():
                self.model = YOLO('yolov8n.pt')
        except Exception as e:
            logging.error(f'YOLO model load error: {e}')
            raise

    def detect(self, frame, roi=None):
        try:
            h, w = frame.shape[:2]
            # YOLO анализирует полный кадр
            with suppress_all_output():
                results = self.model(frame, classes=[0], imgsz=(w, h))
            annotated = frame.copy()
            # Подсветка bbox только если центр внутри ROI
            if results and len(results[0].boxes) > 0:
                boxes = results[0].boxes.xyxy.cpu().numpy()
                for box in boxes:
                    x1, y1, x2, y2 = map(int, box[:4])
                    cx = int((x1 + x2) / 2)
                    cy = int((y1 + y2) / 2)
                    inside = True
                    if roi and len(roi) >= 3:
                        pts = np.array(roi, dtype=np.int32)
                        inside = cv2.pointPolygonTest(pts, (cx, cy), False) >= 0
                    if inside:
                        cv2.rectangle(annotated, (x1, y1), (x2, y2), (0,255,0), 2)
            # Нарисовать ROI поверх
            if roi and len(roi) >= 3:
                pts = np.array(roi, dtype=np.int32)
                cv2.polylines(annotated, [pts], isClosed=True, color=(0,255,255), thickness=2)
            _, jpeg = cv2.imencode('.jpg', annotated)
            return jpeg.tobytes()
        except Exception as e:
            logging.error(f'Detection error: {e}', exc_info=True)
            return b'' 