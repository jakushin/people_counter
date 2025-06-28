import cv2
import asyncio
import logging
import time
import os
import sys
import contextlib

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

class VideoStream:
    def __init__(self, rtsp_url):
        self.rtsp_url = rtsp_url
        self.cap = None
        self.last_frame_time = None
        self.fps = 0
        self.frame_count = 0
        self.last_stat_time = time.time()
        self.is_file = os.path.isfile(rtsp_url)  # Проверяем, это файл или RTSP
        self.connect()

    @contextlib.contextmanager
    def suppress_stderr(self):
        old_stderr = sys.stderr
        try:
            sys.stderr = open(os.devnull, 'w')
            yield
        finally:
            sys.stderr.close()
            sys.stderr = old_stderr

    def connect(self):
        if self.cap:
            self.cap.release()
        debug_log(f'[VIDEO_STREAM] Attempting to connect to: {self.rtsp_url}')
        
        # Проверяем существование файла
        if self.is_file:
            if not os.path.exists(self.rtsp_url):
                logging.error(f'[VIDEO_STREAM] File does not exist: {self.rtsp_url}')
                raise RuntimeError(f'File does not exist: {self.rtsp_url}')
            file_size = os.path.getsize(self.rtsp_url)
            debug_log(f'[VIDEO_STREAM] File exists, size: {file_size} bytes')
        
        with self.suppress_stderr():
            self.cap = cv2.VideoCapture(self.rtsp_url)
        
        if not self.cap:
            logging.error(f'[VIDEO_STREAM] cv2.VideoCapture returned None for: {self.rtsp_url}')
            raise RuntimeError('cv2.VideoCapture returned None')
        
        if not self.cap.isOpened():
            logging.error(f'[VIDEO_STREAM] Cannot open video source: {self.rtsp_url}')
            raise RuntimeError('Cannot open video source')
        
        if self.is_file:
            debug_log(f'Video file opened: {self.rtsp_url}')
            # Получаем информацию о файле
            fps = self.cap.get(cv2.CAP_PROP_FPS)
            frame_count = self.cap.get(cv2.CAP_PROP_FRAME_COUNT)
            width = self.cap.get(cv2.CAP_PROP_FRAME_WIDTH)
            height = self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
            debug_log(f'[VIDEO_STREAM] File info: {width}x{height}, {fps} FPS, {frame_count} frames')
        else:
            debug_log('RTSP stream connected')

    async def async_frames(self):
        retry_delay = 2
        prev_time = time.time()
        frame_times = []  # Для диагностики рывков
        debug_log(f'[VIDEO_STREAM] Starting async_frames loop for: {self.rtsp_url}')
        
        while True:
            try:
                frame_start_time = time.time()
                ret, frame = self.cap.read()
                frame_read_time = time.time()
                
                if not ret:
                    if self.is_file:
                        # Для файлов - перезапускаем
                        logging.info('End of video file reached, restarting...')
                        self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                        continue
                    else:
                        # Для RTSP - переподключаемся
                        logging.warning(f'[VIDEO_STREAM] Frame read failed, reconnecting in {retry_delay}s...')
                        await asyncio.sleep(retry_delay)
                        self.connect()
                        continue
                
                now = time.time()
                delta = now - prev_time
                prev_time = now
                
                # Диагностика рывков
                frame_times.append(delta)
                if len(frame_times) > 30:  # Анализируем последние 30 кадров
                    frame_times.pop(0)
                    avg_delta = sum(frame_times) / len(frame_times)
                    min_delta = min(frame_times)
                    max_delta = max(frame_times)
                    if max_delta > avg_delta * 2:  # Если есть рывки
                        logging.warning(f'[VIDEO_STREAM] Frame timing issue: avg={avg_delta:.3f}s, min={min_delta:.3f}s, max={max_delta:.3f}s')
                
                # Логируем только каждые 100 кадров для уменьшения объема логов
                if self.frame_count % 100 == 0:
                    verbose_log(f'[VIDEO_STREAM] Frame received. Shape: {frame.shape}, Delta: {delta:.3f}s, Read time: {(frame_read_time - frame_start_time)*1000:.1f}ms')
                
                # FPS calculation
                self.frame_count += 1
                if self.last_stat_time is None:
                    self.last_stat_time = now
                if now - self.last_stat_time >= 1.0:
                    self.fps = self.frame_count / (now - self.last_stat_time)
                    self.frame_count = 0
                    self.last_stat_time = now
                    # Логируем FPS всегда, так как это важно для диагностики
                    logging.info(f'[VIDEO_STREAM] FPS: {self.fps:.2f}')
                
                yield frame, {
                    'timestamp': now,
                    'fps': round(self.fps, 2),
                    'shape': frame.shape[:2][::-1]  # (width, height)
                }
                
                # Убираем искусственную задержку - пусть система работает на максимальной скорости
                # Небольшая задержка только для RTSP чтобы не перегружать сеть
                if not self.is_file:
                    await asyncio.sleep(0.01)  # Только для RTSP потоков 
                    
            except Exception as e:
                logging.error(f'[VIDEO_STREAM] Error in async_frames: {e}')
                await asyncio.sleep(1)
                continue 