import cv2
import numpy as np
import logging
from ultralytics import YOLO
import sys
import contextlib
import os
import multiprocessing

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
        # Автоматически определяем число доступных ядер
        try:
            import torch
            num_cores = multiprocessing.cpu_count()
            torch.set_num_threads(num_cores)
            torch.set_num_interop_threads(min(2, num_cores))
            print(f"[INFO] PyTorch num_threads set to {num_cores}")
        except Exception as e:
            print(f"[WARN] Could not set PyTorch threads: {e}")
        try:
            with suppress_all_output():
                # Используем yolov8m.pt для детекции людей
                self.model = YOLO('yolov8m.pt')
        except Exception as e:
            logging.error(f'YOLO model load error: {e}')
            raise

    def detect(self, frame, roi=None):
        try:
            h, w = frame.shape[:2]
            imgsz = max(1280, w, h)
            with suppress_all_output():
                results = self.model(frame, imgsz=imgsz, conf=0.2)
            annotated = frame.copy()
            # Для object detection: рисуем bbox для каждого найденного человека
            if results and results[0].boxes is not None and len(results[0].boxes) > 0:
                boxes = results[0].boxes.xyxy.cpu().numpy()  # (N, 4)
                clss = results[0].boxes.cls.cpu().numpy()    # (N,)
                pts = np.array(roi, dtype=np.int32) if roi and len(roi) >= 3 else None
                for box, cls_id in zip(boxes, clss):
                    if int(cls_id) != 0:
                        continue  # Только люди
                    x1, y1, x2, y2 = map(int, box)
                    cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
                    if pts is not None and cv2.pointPolygonTest(pts, (cx, cy), False) < 0:
                        continue  # Центр bbox вне ROI
                    cv2.rectangle(annotated, (x1, y1), (x2, y2), (0,255,0), 2)
            # Нарисовать ROI поверх
            if roi and len(roi) >= 3:
                pts = np.array(roi, dtype=np.int32)
                cv2.polylines(annotated, [pts], isClosed=True, color=(0,255,255), thickness=2)
            encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 95]
            _, jpeg = cv2.imencode('.jpg', annotated, encode_param)
            return jpeg.tobytes()
        except Exception as e:
            logging.error(f'Detection error: {e}', exc_info=True)
            print(f"[ERROR] Detection error: {e}")
            return b'' 