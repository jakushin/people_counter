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

    def detect(self, frame, roi=None, worker_idx=None):
        """
        Детекция людей на кадре
        Args:
            frame: numpy array с кадром
            roi: список точек ROI [(x1,y1), (x2,y2), ...]
            worker_idx: ID worker процесса (для логирования)
        """
        try:
            if worker_idx is not None:
                logging.info(f"[DETECTOR] Worker {worker_idx} starting detection")
            
            h, w = frame.shape[:2]
            verbose_log(f"[DETECTOR] Frame size: {w}x{h}")
            
            # Определяем область поиска
            if roi is not None and len(roi) >= 3:
                # Создаем маску для ROI
                mask = np.zeros((h, w), dtype=np.uint8)
                pts = np.array(roi, dtype=np.int32)
                cv2.fillPoly(mask, [pts], 255)
                
                # Находим границы ROI
                contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
                if contours:
                    x, y, crop_w, crop_h = cv2.boundingRect(contours[0])
                    crop_offset = (x, y)
                    verbose_log(f"[ROI] Crop area: {crop_w}x{crop_h} at offset {crop_offset}")
                else:
                    crop_offset = (0, 0)
                    crop_w, crop_h = w, h
                    verbose_log(f"[ROI] No valid ROI contours found, using full frame")
            else:
                crop_offset = (0, 0)
                crop_w, crop_h = w, h
                pts = None
                verbose_log(f"[ROI] No ROI provided, using full frame")
            
            # Адаптивный выбор размера изображения
            imgsz = self.calculate_adaptive_imgsz(crop_h, crop_w, h, w)
            
            # Кропаем область поиска
            if crop_offset[0] > 0 or crop_offset[1] > 0:
                crop_x1 = int(crop_offset[0])
                crop_y1 = int(crop_offset[1])
                crop_x2 = crop_x1 + crop_w
                crop_y2 = crop_y1 + crop_h
                crop_frame = frame[crop_y1:crop_y2, crop_x1:crop_x2]
                verbose_log(f"[CROP] Cropped frame size: {crop_frame.shape[1]}x{crop_frame.shape[0]}")
            else:
                crop_frame = frame
                verbose_log(f"[CROP] Using full frame (no crop)")
            
            t0 = time.time()
            # Детекция с YOLO
            results = self.model(crop_frame, imgsz=imgsz, conf=0.5, iou=0.7, verbose=False)
            t1 = time.time()
            
            if worker_idx is not None:
                logging.info(f"[DETECTOR] Worker {worker_idx} YOLO inference completed in {t1-t0:.3f}s")
            
            # Обработка результатов
            annotated = crop_frame.copy()
            person_count = 0
            
            if len(results) > 0:
                result = results[0]
                if result.boxes is not None and len(result.boxes) > 0:
                    boxes = result.boxes
                    confidences = boxes.conf.cpu().numpy()
                    class_ids = boxes.cls.cpu().numpy()
                    xyxy = boxes.xyxy.cpu().numpy()
                    
                    if worker_idx is not None:
                        logging.info(f"[DETECTOR] Worker {worker_idx} found {len(xyxy)} total detections")
                    
                    # Фильтруем только людей (class 0)
                    person_indices = np.where(class_ids == 0)[0]
                    
                    if worker_idx is not None:
                        logging.info(f"[DETECTOR] Worker {worker_idx} found {len(person_indices)} person detections")
                    
                    if len(person_indices) > 0:
                        person_confidences = confidences[person_indices]
                        person_boxes = xyxy[person_indices]
                        
                        # Дополнительная фильтрация по размеру и положению
                        filtered_indices = []
                        for i, (x1, y1, x2, y2) in enumerate(person_boxes):
                            box_w = x2 - x1
                            box_h = y2 - y1
                            aspect_ratio = box_w / box_h if box_h > 0 else 0
                            
                            # Проверяем размеры
                            min_size = 20
                            max_size = min(crop_w, crop_h) * 0.8
                            
                            if (box_w < min_size or box_h < min_size or 
                                box_w > max_size or box_h > max_size):
                                if worker_idx is not None:
                                    logging.info(f"[DETECTOR] Worker {worker_idx} filtered out detection {i}: size {box_w:.1f}x{box_h:.1f}")
                                continue
                            
                            # Проверяем aspect ratio (человек должен быть выше чем шире)
                            if aspect_ratio > 1.5 or aspect_ratio < 0.3:
                                if worker_idx is not None:
                                    logging.info(f"[DETECTOR] Worker {worker_idx} filtered out detection {i}: aspect ratio {aspect_ratio:.2f}")
                                continue
                            
                            # Проверяем расстояние от краев (не слишком близко к краям)
                            margin = 10
                            if (x1 < margin or y1 < margin or 
                                x2 > crop_w - margin or y2 > crop_h - margin):
                                if worker_idx is not None:
                                    logging.info(f"[DETECTOR] Worker {worker_idx} filtered out detection {i}: too close to edges")
                                continue
                            
                            filtered_indices.append(i)
                        
                        if worker_idx is not None:
                            logging.info(f"[DETECTOR] Worker {worker_idx} after filtering: {len(filtered_indices)} detections")
                        
                        # Сортируем по x-координате для стабильности ID
                        if filtered_indices:
                            filtered_indices.sort(key=lambda i: person_boxes[i][0])
                        
                        # Рисуем отфильтрованные детекции
                        for i, idx in enumerate(filtered_indices):
                            x1, y1, x2, y2 = person_boxes[idx]
                            conf = person_confidences[idx]
                            
                            # Конвертируем в int для OpenCV
                            x1, y1, x2, y2 = int(x1), int(y1), int(x2), int(y2)
                            
                            # Проверяем, находится ли человек внутри ROI
                            is_inside_roi = True
                            if pts is not None:
                                # Проверяем все четыре угла bounding box
                                corners = [
                                    (int(x1), int(y1)),   # top-left
                                    (int(x2), int(y1)),   # top-right
                                    (int(x2), int(y2)),   # bottom-right
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
                        
                        if worker_idx is not None:
                            logging.info(f"[DETECTOR] Worker {worker_idx} drawing detection {i}: color={color}, inside_roi={is_inside_roi}")
                        
                        cv2.rectangle(annotated, (x1, y1), (x2, y2), color, 2)
                        
                        # Добавляем текст с confidence
                        label = f'Person {i+1} ({conf:.2f})'
                        if is_inside_roi:
                            label += ' (ROI)'
                            person_count += 1
                        
                        cv2.putText(annotated, label, (x1, y1-10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 2)
                        
                        # Логируем детекции
                        if worker_idx is not None:
                            logging.info(f"[DETECTOR] Worker {worker_idx} Person {i+1}: bbox=({x1},{y1},{x2},{y2}), conf={conf:.3f}, inside_roi={is_inside_roi}")
            
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
                logging.info(f"[MP_WORKER] Worker {worker_idx} processing frame {idx}")
                result = detector.detect(frame, roi=roi, worker_idx=worker_idx)
                output_queue.put((idx, result))
                logging.info(f"[MP_WORKER] Worker {worker_idx} completed frame {idx}")
            except Exception as e:
                logging.error(f"[MP_WORKER] Worker {worker_idx} error: {e}")
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