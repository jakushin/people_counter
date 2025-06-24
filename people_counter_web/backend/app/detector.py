import cv2
import numpy as np
import logging
from ultralytics import YOLO
import sys
import contextlib

@contextlib.contextmanager
def suppress_stdout_stderr():
    with open('/dev/null', 'w') as devnull:
        old_stdout = sys.stdout
        old_stderr = sys.stderr
        sys.stdout = devnull
        sys.stderr = devnull
        try:
            yield
        finally:
            sys.stdout = old_stdout
            sys.stderr = old_stderr

class PersonDetector:
    def __init__(self):
        try:
            with suppress_stdout_stderr():
                self.model = YOLO('yolov8n.pt')
        except Exception as e:
            logging.error(f'YOLO model load error: {e}')
            raise

    def detect(self, frame, roi=None):
        try:
            mask = None
            if roi and len(roi) >= 3:
                mask = np.zeros(frame.shape[:2], dtype=np.uint8)
                pts = np.array(roi, dtype=np.int32)
                cv2.fillPoly(mask, [pts], 255)
                frame_roi = cv2.bitwise_and(frame, frame, mask=mask)
            else:
                frame_roi = frame
            with suppress_stdout_stderr():
                results = self.model(frame_roi, classes=[0])
            annotated = results[0].plot(line_width=1, labels=False, conf=False)
            # Нарисовать ROI поверх annotated
            if mask is not None:
                overlay = annotated.copy()
                cv2.polylines(overlay, [pts], isClosed=True, color=(0,255,255), thickness=2)
                annotated = cv2.addWeighted(overlay, 0.7, annotated, 0.3, 0)
            _, jpeg = cv2.imencode('.jpg', annotated)
            return jpeg.tobytes()
        except Exception as e:
            logging.error(f'Detection error: {e}')
            return b'' 