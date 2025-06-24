import cv2
import numpy as np
import logging
from ultralytics import YOLO

class PersonDetector:
    def __init__(self):
        try:
            self.model = YOLO('yolov8n.pt')  # Можно заменить на yolov8s.pt для большей точности
        except Exception as e:
            logging.error(f'YOLO model load error: {e}')
            raise

    def detect(self, frame):
        try:
            results = self.model(frame, classes=[0])  # class 0 — person
            annotated = results[0].plot(line_width=1, labels=False, conf=False)
            _, jpeg = cv2.imencode('.jpg', annotated)
            return jpeg.tobytes()
        except Exception as e:
            logging.error(f'Detection error: {e}')
            return b'' 