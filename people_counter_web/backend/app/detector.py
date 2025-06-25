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
                # Используем pose-модель
                self.model = YOLO('yolov8n-pose.pt')
        except Exception as e:
            logging.error(f'YOLO model load error: {e}')
            raise

    def detect(self, frame, roi=None):
        try:
            h, w = frame.shape[:2]
            # imgsz явно больше, чем размер кадра (например, 1280)
            imgsz = max(1280, w, h)
            with suppress_all_output():
                results = self.model(frame, imgsz=imgsz, conf=0.2)
            annotated = frame.copy()
            # Подсветка только если ключевые точки головы и хотя бы одного плеча внутри ROI
            if results and len(results[0].keypoints) > 0:
                kps = results[0].keypoints.xy.cpu().numpy()  # (N, 17, 2)
                for i, kp in enumerate(kps):
                    # YOLOv8-pose: 0 - nose, 5 - left shoulder, 6 - right shoulder
                    nose = kp[0]
                    l_shoulder = kp[5]
                    r_shoulder = kp[6]
                    inside = True
                    if roi and len(roi) >= 3:
                        pts = np.array(roi, dtype=np.int32)
                        # Проверяем, что nose и хотя бы одно плечо внутри ROI
                        inside = (cv2.pointPolygonTest(pts, tuple(nose), False) >= 0 and
                                  (cv2.pointPolygonTest(pts, tuple(l_shoulder), False) >= 0 or
                                   cv2.pointPolygonTest(pts, tuple(r_shoulder), False) >= 0))
                    if inside:
                        # bbox по ключевым точкам (голова+туловище)
                        min_x = int(np.min(kp[:,0]))
                        min_y = int(np.min(kp[:,1]))
                        max_x = int(np.max(kp[:,0]))
                        max_y = int(np.max(kp[:,1]))
                        # Фильтрация по размеру и соотношению сторон
                        bw, bh = max_x - min_x, max_y - min_y
                        aspect = bh / (bw+1e-5)
                        if bw > 15 and bh > 30 and aspect > 1.2:
                            cv2.rectangle(annotated, (min_x, min_y), (max_x, max_y), (0,255,0), 2)
                            # Нарисовать ключевые точки головы и плеч
                            for idx in [0,5,6]:
                                x, y = int(kp[idx][0]), int(kp[idx][1])
                                cv2.circle(annotated, (x, y), 4, (0,255,255), -1)
            # Нарисовать ROI поверх
            if roi and len(roi) >= 3:
                pts = np.array(roi, dtype=np.int32)
                cv2.polylines(annotated, [pts], isClosed=True, color=(0,255,255), thickness=2)
            # JPEG качество 95
            encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 95]
            _, jpeg = cv2.imencode('.jpg', annotated, encode_param)
            return jpeg.tobytes()
        except Exception as e:
            logging.error(f'Detection error: {e}', exc_info=True)
            return b'' 