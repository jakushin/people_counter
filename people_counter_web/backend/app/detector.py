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
        logging.info(f"[PD_INIT] PersonDetector init in PID: {os.getpid()}, Thread: {threading.get_ident()}")
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
            # --- Новый блок: вычисляем bounding box ROI и делаем crop ---
            crop_offset = (0, 0)
            crop_frame = frame
            pts = np.array(roi, dtype=np.int32) if roi and len(roi) >= 3 else None
            if pts is not None:
                xs = pts[:, 0]
                ys = pts[:, 1]
                x_min, x_max = max(0, xs.min()), min(w, xs.max())
                y_min, y_max = max(0, ys.min()), min(h, ys.max())
                # Проверяем, что crop не пустой
                if x_max > x_min and y_max > y_min:
                    crop_frame = frame[y_min:y_max, x_min:x_max]
                    crop_offset = (x_min, y_min)
                    logging.info(f"[CROP] ROI crop: x_min={x_min}, x_max={x_max}, y_min={y_min}, y_max={y_max}, crop_shape={crop_frame.shape}, original_shape={frame.shape}")
                else:
                    logging.warning(f"[CROP] Invalid crop dimensions: x_min={x_min}, x_max={x_max}, y_min={y_min}, y_max={y_max}")
                    # Возвращаем пустой кадр с заглушкой
                    return self._create_empty_frame(frame.shape[:2])
            else:
                logging.info(f"[CROP] No ROI, analyzing full frame: shape={frame.shape}")
                x_min, y_min = 0, 0
            imgsz = max(1280, crop_frame.shape[1], crop_frame.shape[0])
            thread_id = threading.get_ident()
            pid = os.getpid()
            cpu_percent = psutil.cpu_percent(interval=None)
            cpu_per_core = psutil.cpu_percent(interval=None, percpu=True)
            mem = psutil.virtual_memory()
            proc_mem = psutil.Process(os.getpid()).memory_info().rss / (1024*1024)
            import torch
            logging.info(f"[DETECT] [PersonDetector] PID: {pid}, Thread ID: {thread_id}, torch.get_num_threads(): {torch.get_num_threads()}, torch.get_num_interop_threads(): {torch.get_num_interop_threads()}, CPU: {cpu_percent}%, CPU per core: {cpu_per_core}, RSS: {proc_mem:.1f} MB, System RAM: {mem.percent}%")
            with suppress_all_output():
                results = self.model(crop_frame, imgsz=imgsz, conf=0.2)
            t1 = time.time()
            annotated = frame.copy()
            # Для object detection: рисуем bbox для каждого найденного человека
            person_count = 0
            if results and results[0].boxes is not None and len(results[0].boxes) > 0:
                boxes = results[0].boxes.xyxy.cpu().numpy()  # (N, 4)
                clss = results[0].boxes.cls.cpu().numpy()    # (N,)
                logging.info(f"[DETECT] Found {len(boxes)} objects, classes: {clss}")
                for box, cls_id in zip(boxes, clss):
                    if int(cls_id) != 0:
                        continue  # Только люди
                    # Смещаем bbox обратно в координаты исходного кадра
                    x1, y1, x2, y2 = map(int, box)
                    x1 += crop_offset[0]
                    x2 += crop_offset[0]
                    y1 += crop_offset[1]
                    y2 += crop_offset[1]
                    cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
                    if pts is not None and cv2.pointPolygonTest(pts, (float(cx), float(cy)), False) < 0:
                        logging.info(f"[ROI] Person center ({cx}, {cy}) outside ROI, skipping")
                        continue  # Центр bbox вне ROI
                    cv2.rectangle(annotated, (x1, y1), (x2, y2), (0,255,0), 2)
                    person_count += 1
                    logging.info(f"[DETECT] Person {person_count}: bbox=({x1},{y1},{x2},{y2}), center=({cx},{cy})")
            else:
                logging.info(f"[DETECT] No objects detected in crop")
            t2 = time.time()
            # Нарисовать ROI поверх
            if roi and len(roi) >= 3:
                pts = np.array(roi, dtype=np.int32)
                cv2.polylines(annotated, [pts], isClosed=True, color=(0,255,255), thickness=2)
            t3 = time.time()
            encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 95]
            success, jpeg = cv2.imencode('.jpg', annotated, encode_param)
            if not success or jpeg is None or len(jpeg) == 0:
                logging.error(f"[JPEG] Failed to encode image: success={success}, jpeg_size={len(jpeg) if jpeg is not None else 'None'}")
                return self._create_empty_frame(frame.shape[:2])
            t4 = time.time()
            logging.info(f'[DETECTOR] Inference: {t1-t0:.3f}s, Draw: {t2-t1:.3f}s, JPEG: {t3-t2:.3f}s')
            return jpeg.tobytes()
        except Exception as e:
            logging.error(f'Detection error: {e}', exc_info=True)
            print(f"[ERROR] Detection error: {e}")
            # Логируем дополнительную информацию для диагностики
            logging.error(f"[ERROR_DETAILS] Frame shape: {frame.shape}, ROI: {roi}, Crop offset: {crop_offset}")
            return self._create_empty_frame(frame.shape[:2])

    def _create_empty_frame(self, shape):
        """Создаёт пустой кадр-заглушку при ошибках"""
        try:
            # Создаём чёрный кадр с текстом "No image"
            h, w = shape
            empty_frame = np.zeros((h, w, 3), dtype=np.uint8)
            # Добавляем текст
            font = cv2.FONT_HERSHEY_SIMPLEX
            text = "No image"
            text_size = cv2.getTextSize(text, font, 1, 2)[0]
            text_x = (w - text_size[0]) // 2
            text_y = (h + text_size[1]) // 2
            cv2.putText(empty_frame, text, (text_x, text_y), font, 1, (255, 255, 255), 2)
            # Кодируем в JPEG
            encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 95]
            success, jpeg = cv2.imencode('.jpg', empty_frame, encode_param)
            if success:
                return jpeg.tobytes()
            else:
                logging.error("[JPEG] Failed to encode empty frame")
                return b''
        except Exception as e:
            logging.error(f"[EMPTY_FRAME] Error creating empty frame: {e}")
            return b''

class MultiprocessPersonDetector:
    def __init__(self, num_workers=None):
        self.num_workers = num_workers or cpu_count()
        self.input_queue = Queue(maxsize=8*self.num_workers)
        self.output_queue = Queue(maxsize=8*self.num_workers)
        self.workers = []
        self.frame_idx = 0
        self.next_send_idx = 0
        logging.info(f"[MP_INIT] Main PID: {os.getpid()}, num_workers: {self.num_workers}")
        for i in range(self.num_workers):
            try:
                p = Process(target=self.worker, args=(self.input_queue, self.output_queue, i))
                p.daemon = True
                p.start()
                self.workers.append(p)
                logging.info(f"[MP_INIT] Started worker {i}, PID: {p.pid}")
            except Exception as e:
                logging.error(f"[MP_INIT] Failed to start worker {i}: {e}")
        self.result_buffer = {}

    @staticmethod
    def worker(input_queue, output_queue, worker_idx):
        logging.info(f"[MP_WORKER] Worker {worker_idx} started, PID: {os.getpid()}")
        detector = PersonDetector()
        mem = psutil.virtual_memory()
        proc_mem = psutil.Process(os.getpid()).memory_info().rss / (1024*1024)
        logging.info(f"[MP_WORKER] Worker {worker_idx} PID: {os.getpid()}, RSS: {proc_mem:.1f} MB, System RAM: {mem.percent}%")
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
        pid = os.getpid()
        thread_id = threading.get_ident()
        logging.info(f"[DETECT] [MP_DETECTOR] Main PID: {pid}, Thread ID: {thread_id}, sending frame idx: {idx}")
        
        # Проверяем состояние очередей
        input_size = self.input_queue.qsize()
        output_size = self.output_queue.qsize()
        buffer_size = len(self.result_buffer)
        logging.info(f"[MP_QUEUE] Input queue: {input_size}, Output queue: {output_size}, Buffer: {buffer_size}")
        
        try:
            self.input_queue.put((idx, frame, roi), timeout=1)
        except pyqueue.Full:
            logging.error(f"[MP_QUEUE] Input queue full, dropping frame {idx}")
            return self._create_empty_frame(frame.shape[:2])
        
        while True:
            try:
                out_idx, result = self.output_queue.get(timeout=2)
                self.result_buffer[out_idx] = result
                logging.info(f"[MP_RESULT] Received result for frame {out_idx}, buffer size: {len(self.result_buffer)}")
                if self.next_send_idx in self.result_buffer:
                    res = self.result_buffer.pop(self.next_send_idx)
                    self.next_send_idx += 1
                    logging.info(f"[MP_RESULT] Returning frame {self.next_send_idx-1}, result size: {len(res)}")
                    return res
            except pyqueue.Empty:
                logging.warning(f"[MP_DETECTOR] Timeout waiting for result, frame {idx}, next_send_idx: {self.next_send_idx}")
                # Проверяем состояние воркеров
                active_workers = sum(1 for w in self.workers if w.is_alive())
                logging.warning(f"[MP_WORKERS] Active workers: {active_workers}/{len(self.workers)}")
                return self._create_empty_frame(frame.shape[:2])

    def _create_empty_frame(self, shape):
        """Создаёт пустой кадр-заглушку при ошибках"""
        try:
            # Создаём чёрный кадр с текстом "No image"
            h, w = shape
            empty_frame = np.zeros((h, w, 3), dtype=np.uint8)
            # Добавляем текст
            font = cv2.FONT_HERSHEY_SIMPLEX
            text = "No image"
            text_size = cv2.getTextSize(text, font, 1, 2)[0]
            text_x = (w - text_size[0]) // 2
            text_y = (h + text_size[1]) // 2
            cv2.putText(empty_frame, text, (text_x, text_y), font, 1, (255, 255, 255), 2)
            # Кодируем в JPEG
            encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 95]
            success, jpeg = cv2.imencode('.jpg', empty_frame, encode_param)
            if success:
                return jpeg.tobytes()
            else:
                logging.error("[JPEG] Failed to encode empty frame")
                return b''
        except Exception as e:
            logging.error(f"[EMPTY_FRAME] Error creating empty frame: {e}")
            return b'' 