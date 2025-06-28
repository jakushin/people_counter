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
from app.byte_tracker import ByteTrackerWrapper, TrackedPerson

# Настройка уровней логирования
DEBUG_MODE = os.environ.get('DEBUG_MODE', 'false').lower() == 'true'
VERBOSE_MODE = os.environ.get('VERBOSE_MODE', 'false').lower() == 'true'

def debug_log(message):
    """Логировать только в debug режиме"""
    if DEBUG_MODE:
        logging.info(message)

def verbose_log(message):
    """Логировать только в verbose режиме"""
    if VERBOSE_MODE:
        logging.info(message)

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
        debug_log(f"[PD_INIT] PersonDetector init in PID: {os.getpid()}, Thread: {threading.get_ident()}")
        # Автоматически определяем число доступных ядер
        try:
            import torch
            num_cores = multiprocessing.cpu_count()
            torch.set_num_threads(num_cores)
            torch.set_num_interop_threads(min(2, num_cores))
            debug_log(f"[INIT] PyTorch num_threads set to {num_cores}")
            debug_log(f"[INIT] torch.get_num_threads(): {torch.get_num_threads()}, torch.get_num_interop_threads(): {torch.get_num_interop_threads()}")
        except Exception as e:
            logging.warning(f"[WARN] Could not set PyTorch threads: {e}")
        try:
            with suppress_all_output():
                # Используем yolov8m.pt для детекции людей
                self.model = YOLO('yolov8m.pt')
        except Exception as e:
            logging.error(f'YOLO model load error: {e}')
            raise
        
        # Инициализируем YOLO модель
        self.model = YOLO('yolov8s.pt')
        
        # Инициализируем трекер ByteTrack
        # self.tracker = ByteTrackerWrapper()
        
        # Временно отключаем трекинг для диагностики
        self.tracker = None

    def detect(self, frame, roi=None):
        try:
            t0 = time.time()
            h, w = frame.shape[:2]
            crop_offset = (0, 0)
            crop_frame = frame
            pts = np.array(roi, dtype=np.int32) if roi and len(roi) >= 3 else None
            if pts is not None:
                xs = pts[:, 0]
                ys = pts[:, 1]
                x_min, x_max = max(0, xs.min()), min(w, xs.max())
                y_min, y_max = max(0, ys.min()), min(h, ys.max())
                if x_max > x_min and y_max > y_min:
                    crop_frame = frame[y_min:y_max, x_min:x_max]
                    crop_offset = (int(x_min), int(y_min))
                    verbose_log(f"[CROP] ROI crop: x_min={x_min}, x_max={x_max}, y_min={y_min}, y_max={y_max}, crop_shape={crop_frame.shape}, original_shape={frame.shape}")
                else:
                    logging.warning(f"[CROP] Invalid crop dimensions: x_min={x_min}, x_max={x_max}, y_min={y_min}, y_max={y_max}")
                    return self._create_empty_frame(frame.shape[:2]), 0, 0, 0
            else:
                verbose_log(f"[CROP] No ROI, analyzing full frame: shape={frame.shape}")
                x_min, y_min = 0, 0
                crop_offset = (0, 0)
            crop_h, crop_w = crop_frame.shape[:2]
            imgsz = self.calculate_adaptive_imgsz(crop_h, crop_w, h, w)
            verbose_log(f"[YOLO] Using imgsz={imgsz} for crop {crop_w}x{crop_h}")
            
            # Детальная информация о системе только в debug режиме
            if DEBUG_MODE:
                thread_id = threading.get_ident()
                pid = os.getpid()
                cpu_percent = psutil.cpu_percent(interval=None)
                cpu_per_core = psutil.cpu_percent(interval=None, percpu=True)
                mem = psutil.virtual_memory()
                proc_mem = psutil.Process(os.getpid()).memory_info().rss / (1024*1024)
                import torch
                logging.info(f"[DETECT] [PersonDetector] PID: {pid}, Thread ID: {thread_id}, torch.get_num_threads(): {torch.get_num_threads()}, torch.get_num_interop_threads(): {torch.get_num_interop_threads()}, CPU: {cpu_percent}%, CPU per core: {cpu_per_core}, RSS: {proc_mem:.1f} MB, System RAM: {mem.percent}%")
            
            with suppress_all_output():
                results = self.model(crop_frame, imgsz=imgsz, conf=0.5, verbose=False)
            t1 = time.time()
            annotated = frame.copy()
            person_count = 0
            
            # Подготавливаем детекции для ByteTrack
            detections = []
            if results and results[0].boxes is not None and len(results[0].boxes) > 0:
                boxes = results[0].boxes.xyxy.cpu().numpy()
                clss = results[0].boxes.cls.cpu().numpy()
                confs = results[0].boxes.conf.cpu().numpy()
                
                # Логируем обнаружение объектов всегда, так как это важно для диагностики
                logging.info(f"[DETECT] Found {len(boxes)} objects, classes: {clss}, confidences: {confs}")
                
                # Фильтруем только людей
                for i, (box, cls, conf) in enumerate(zip(boxes, clss, confs)):
                    if cls == 0:  # person class
                        # Фильтруем по confidence
                        if conf < 0.5:  # Минимальный порог confidence
                            verbose_log(f"[FILTER] Skipping low confidence detection: {conf:.3f}")
                            continue
                        
                        # Проверяем на NaN значения
                        if np.isnan(box).any():
                            verbose_log(f"[FILTER] Skipping bbox with NaN values: {box}")
                            continue
                        
                        x1, y1, x2, y2 = map(int, box)
                        
                        # Добавляем смещение от crop области
                        x1 += crop_offset[0]
                        y1 += crop_offset[1]
                        x2 += crop_offset[0]
                        y2 += crop_offset[1]
                        
                        # Проверяем размер bounding box (отфильтровываем слишком маленькие)
                        width = x2 - x1
                        height = y2 - y1
                        if width < 30 or height < 60:  # Минимальные размеры для человека
                            verbose_log(f"[FILTER] Skipping small bbox: {width}x{height}")
                            continue
                        
                        # Добавляем детекцию в список
                        detections.append((x1, y1, x2, y2, conf, 0))
            else:
                logging.info("[DETECT] No objects detected in crop")
            
            # Отрисовываем детекции людей
            # Сортируем детекции по позиции (слева направо) для стабильной нумерации
            sorted_detections = sorted(detections, key=lambda x: x[0])  # сортируем по x1 (левая координата)
            
            for i, (x1, y1, x2, y2, conf, cls_id) in enumerate(sorted_detections):
                # Проверяем, находится ли человек внутри ROI
                is_inside_roi = False
                if pts is not None:
                    # Проверяем центр bounding box
                    center_x = int(x1 + (x2 - x1) // 2)
                    center_y = int(y1 + (y2 - y1) // 2)
                    is_inside_roi = cv2.pointPolygonTest(pts, (center_x, center_y), False) >= 0
                    
                    # Если центр внутри, проверяем все углы
                    if is_inside_roi:
                        corners = [
                            (int(x1), int(y1)),  # top-left
                            (int(x2), int(y1)),  # top-right
                            (int(x2), int(y2)),  # bottom-right
                            (int(x1), int(y2))   # bottom-left
                        ]
                        
                        # Человек считается полностью внутри ROI только если все углы внутри
                        is_inside_roi = all(
                            cv2.pointPolygonTest(pts, corner, False) >= 0 
                            for corner in corners
                        )
                
                # Используем стабильные цвета на основе confidence, а не индекса
                if is_inside_roi:
                    if conf > 0.85:
                        color = (0, 255, 0)  # Ярко-зеленый для высокого confidence
                    else:
                        color = (0, 200, 0)  # Темно-зеленый для среднего confidence
                else:
                    if conf > 0.85:
                        color = (0, 165, 255)  # Оранжевый для высокого confidence
                    else:
                        color = (0, 100, 255)  # Темно-оранжевый для среднего confidence
                
                cv2.rectangle(annotated, (x1, y1), (x2, y2), color, 2)
                
                # Добавляем текст с confidence
                label = f'Person {i+1} ({conf:.2f})'
                if is_inside_roi:
                    label += ' (ROI)'
                    person_count += 1
                
                cv2.putText(annotated, label, (x1, y1-10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 2)
                
                # Логируем детекции
                logging.info(f"[DETECT] Person {i+1}: bbox=({x1},{y1},{x2},{y2}), conf={conf:.3f}, inside_roi={is_inside_roi}")
            
            t2 = time.time()
            # Рисуем ROI красными линиями
            if pts is not None:
                cv2.polylines(annotated, [pts], True, (255, 0, 0), 2)
            
            # Рисуем область поиска (crop area) синими линиями
            if crop_offset[0] > 0 or crop_offset[1] > 0:
                # Вычисляем координаты прямоугольника crop области
                crop_x1 = int(crop_offset[0])
                crop_y1 = int(crop_offset[1])
                crop_x2 = crop_x1 + crop_w
                crop_y2 = crop_y1 + crop_h
                
                # Рисуем прямоугольник crop области синими линиями
                cv2.rectangle(annotated, (crop_x1, crop_y1), (crop_x2, crop_y2), (255, 0, 0), 2)  # Синий цвет (BGR)
                
                # Добавляем текст с информацией о размере
                cv2.putText(annotated, f'Search: {crop_w}x{crop_h}', 
                           (crop_x1, crop_y1-10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 0, 0), 1)
            else:
                # Если ROI не задано, показываем что анализируется весь кадр
                cv2.rectangle(annotated, (0, 0), (w, h), (255, 0, 0), 2)  # Синий цвет (BGR)
                cv2.putText(annotated, f'Search: Full frame {w}x{h}', 
                           (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 0, 0), 1)
            t3 = time.time()
            
            encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 95]
            success, jpeg = cv2.imencode('.jpg', annotated, encode_param)
            if not success or jpeg is None or len(jpeg) == 0:
                logging.error(f"[JPEG] Failed to encode image: success={success}, jpeg_size={len(jpeg) if jpeg is not None else 'None'}")
                return self._create_empty_frame(frame.shape[:2]), crop_h, crop_w, imgsz
            t4 = time.time()
            
            # Логируем время обработки только в debug режиме
            if DEBUG_MODE:
                logging.info(f'[DETECTOR] Inference: {t1-t0:.3f}s, Draw: {t2-t1:.3f}s, JPEG: {t3-t2:.3f}s')
            
            return jpeg.tobytes(), crop_h, crop_w, imgsz
        except Exception as e:
            logging.error(f'Detection error: {e}', exc_info=True)
            print(f"[ERROR] Detection error: {e}")
            logging.error(f"[ERROR_DETAILS] Frame shape: {frame.shape}, ROI: {roi}, Crop offset: {crop_offset}")
            return self._create_empty_frame(frame.shape[:2]), 0, 0, 0

    def calculate_adaptive_imgsz(self, crop_h, crop_w, original_h, original_w):
        """Адаптивный выбор размера изображения для YOLO"""
        # Определяем максимальный размер оригинального изображения
        max_original = max(original_w, original_h)
        
        # Базовые размеры для разных типов кадров
        if max_original <= 640:
            max_imgsz = 640
            reason = "small_frame"
        elif max_original <= 1280:
            max_imgsz = 960
            reason = "medium_frame"
        else:
            max_imgsz = 1280
            reason = "large_frame"
        
        # Размер для кропа
        crop_imgsz = min(576, max(crop_w, crop_h))
        
        # Финальный размер
        imgsz = min(crop_imgsz, max_imgsz)
        
        # Логируем только в verbose режиме
        verbose_log(f"[YOLO_LOGIC] Crop: {crop_w}x{crop_h}, Original: {original_w}x{original_h}")
        verbose_log(f"[YOLO_LOGIC] Max_original: {max_original}, Max_imgsz: {max_imgsz} ({reason})")
        verbose_log(f"[YOLO_LOGIC] Crop_imgsz: {crop_imgsz}, Final_imgsz: {imgsz}")
        
        return imgsz

    def _create_empty_frame(self, shape):
        """Создать пустой кадр"""
        empty_frame = np.zeros((shape[0], shape[1], 3), dtype=np.uint8)
        encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 95]
        success, jpeg = cv2.imencode('.jpg', empty_frame, encode_param)
        return jpeg.tobytes() if success else b''

class MultiprocessPersonDetector:
    def __init__(self, num_workers=None):
        self.num_workers = num_workers or cpu_count()
        self.input_queue = Queue(maxsize=8*self.num_workers)
        self.output_queue = Queue(maxsize=8*self.num_workers)
        self.workers = []
        self.frame_idx = 0
        self.next_send_idx = 0
        debug_log(f"[MP_INIT] Main PID: {os.getpid()}, num_workers: {self.num_workers}")
        for i in range(self.num_workers):
            try:
                p = Process(target=self.worker, args=(self.input_queue, self.output_queue, i))
                p.daemon = True
                p.start()
                self.workers.append(p)
                debug_log(f"[MP_INIT] Started worker {i}, PID: {p.pid}")
            except Exception as e:
                logging.error(f"[MP_INIT] Failed to start worker {i}: {e}")
        self.result_buffer = {}

    @staticmethod
    def worker(input_queue, output_queue, worker_idx):
        debug_log(f"[MP_WORKER] Worker {worker_idx} started, PID: {os.getpid()}")
        detector = PersonDetector()
        if DEBUG_MODE:
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
        
        # Логируем только в debug режиме
        if DEBUG_MODE:
            pid = os.getpid()
            thread_id = threading.get_ident()
            logging.info(f"[DETECT] [MP_DETECTOR] Main PID: {pid}, Thread ID: {thread_id}, sending frame idx: {idx}")
            input_size = self.input_queue.qsize()
            output_size = self.output_queue.qsize()
            buffer_size = len(self.result_buffer)
            logging.info(f"[MP_QUEUE] Input queue: {input_size}, Output queue: {output_size}, Buffer: {buffer_size}")
        
        try:
            self.input_queue.put((idx, frame, roi), timeout=1)
        except pyqueue.Full:
            logging.error(f"[MP_QUEUE] Input queue full, dropping frame {idx}")
            return self._create_empty_frame(frame.shape[:2]), 0, 0, 0
        
        while True:
            try:
                out_idx, result = self.output_queue.get(timeout=2)
                self.result_buffer[out_idx] = result
                # Логируем получение результатов всегда, так как это важно для диагностики
                logging.info(f"[MP_RESULT] Received result for frame {out_idx}, buffer size: {len(self.result_buffer)}")
                if self.next_send_idx in self.result_buffer:
                    res = self.result_buffer.pop(self.next_send_idx)
                    self.next_send_idx += 1
                    # Логируем возврат результатов всегда, так как это важно для диагностики
                    logging.info(f"[MP_RESULT] Returning frame {self.next_send_idx-1}, result size: {len(res) if isinstance(res, bytes) else 'tuple'}")
                    return res if isinstance(res, tuple) else (res, 0, 0, 0)
            except pyqueue.Empty:
                logging.warning(f"[MP_DETECTOR] Timeout waiting for result, frame {idx}, next_send_idx: {self.next_send_idx}")
                active_workers = sum(1 for w in self.workers if w.is_alive())
                logging.warning(f"[MP_WORKERS] Active workers: {active_workers}/{len(self.workers)}")
                return self._create_empty_frame(frame.shape[:2]), 0, 0, 0

    def _create_empty_frame(self, shape):
        """Создать пустой кадр"""
        empty_frame = np.zeros((shape[0], shape[1], 3), dtype=np.uint8)
        encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 95]
        success, jpeg = cv2.imencode('.jpg', empty_frame, encode_param)
        return jpeg.tobytes() if success else b'' 