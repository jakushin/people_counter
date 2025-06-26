import cv2
import numpy as np
import logging
from ultralytics import YOLO
import sys
import contextlib
import os
import multiprocessing
import time
import threading
import psutil
from multiprocessing import Process, Queue, cpu_count
import queue as pyqueue

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
            logging.info(f"[INIT] PyTorch num_threads set to {num_cores}")
            logging.info(f"[INIT] torch.get_num_threads(): {torch.get_num_threads()}, torch.get_num_interop_threads(): {torch.get_num_interop_threads()}")
        except Exception as e:
            logging.warning(f"[WARN] Could not set PyTorch threads: {e}")
        try:
            with suppress_all_output():
                # Используем yolov8m.pt для детекции людей
                self.model = YOLO('yolov8m.pt')
        except Exception as e:
            logging.error(f'YOLO model load error: {e}')
            raise

    def detect(self, frame, roi=None):
        try:
            t0 = time.time()
            h, w = frame.shape[:2]
            imgsz = max(1280, w, h)
            thread_id = threading.get_ident()
            cpu_percent = psutil.cpu_percent(interval=None)
            cpu_per_core = psutil.cpu_percent(interval=None, percpu=True)
            import torch
            logging.info(f"[DETECT] Thread ID: {thread_id}, torch.get_num_threads(): {torch.get_num_threads()}, torch.get_num_interop_threads(): {torch.get_num_interop_threads()}, CPU: {cpu_percent}%, CPU per core: {cpu_per_core}")
            with suppress_all_output():
                results = self.model(frame, imgsz=imgsz, conf=0.2)
            t1 = time.time()
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
            t2 = time.time()
            # Нарисовать ROI поверх
            if roi and len(roi) >= 3:
                pts = np.array(roi, dtype=np.int32)
                cv2.polylines(annotated, [pts], isClosed=True, color=(0,255,255), thickness=2)
            t3 = time.time()
            encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 95]
            _, jpeg = cv2.imencode('.jpg', annotated, encode_param)
            t4 = time.time()
            logging.info(f'[DETECTOR] Inference: {t1-t0:.3f}s, Draw: {t2-t1:.3f}s, JPEG: {t3-t2:.3f}s')
            return jpeg.tobytes()
        except Exception as e:
            logging.error(f'Detection error: {e}', exc_info=True)
            print(f"[ERROR] Detection error: {e}")
            return b''

class MultiprocessPersonDetector:
    def __init__(self, num_workers=None):
        self.num_workers = num_workers or cpu_count()
        self.input_queue = Queue(maxsize=8*self.num_workers)
        self.output_queue = Queue(maxsize=8*self.num_workers)
        self.workers = []
        self.frame_idx = 0
        self.next_send_idx = 0
        for i in range(self.num_workers):
            p = Process(target=self.worker, args=(self.input_queue, self.output_queue))
            p.daemon = True
            p.start()
            self.workers.append(p)
        self.result_buffer = {}

    @staticmethod
    def worker(input_queue, output_queue):
        # В каждом процессе своя модель
        detector = PersonDetector()
        while True:
            try:
                idx, frame, roi = input_queue.get(timeout=1)
            except pyqueue.Empty:
                continue
            try:
                result = detector.detect(frame, roi=roi)
                output_queue.put((idx, result))
            except Exception as e:
                logging.error(f"[MP_WORKER] Error: {e}")
                output_queue.put((idx, b''))

    def detect(self, frame, roi=None):
        idx = self.frame_idx
        self.frame_idx += 1
        self.input_queue.put((idx, frame, roi))
        # Ждём следующий по порядку результат
        while True:
            try:
                out_idx, result = self.output_queue.get(timeout=2)
                self.result_buffer[out_idx] = result
                # Отправляем только если готов следующий по порядку
                if self.next_send_idx in self.result_buffer:
                    res = self.result_buffer.pop(self.next_send_idx)
                    self.next_send_idx += 1
                    return res
            except pyqueue.Empty:
                logging.warning("[MP_DETECTOR] Timeout waiting for result")
                return b'' 