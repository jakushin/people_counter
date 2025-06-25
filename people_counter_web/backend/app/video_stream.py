import cv2
import asyncio
import logging
import time
import os
import sys

class VideoStream:
    def __init__(self, rtsp_url):
        self.rtsp_url = rtsp_url
        self.cap = None
        self.last_frame_time = None
        self.fps = 0
        self.frame_count = 0
        self.last_stat_time = time.time()
        self.error_count = 0
        self.max_errors = 10
        self.connect()

    def connect(self):
        if self.cap:
            self.cap.release()
        
        # Подавление ffmpeg/h264 ошибок через временное перенаправление stderr
        def suppress_stderr():
            sys.stderr.flush()
            devnull = os.open(os.devnull, os.O_WRONLY)
            old_stderr = os.dup(2)
            os.dup2(devnull, 2)
            os.close(devnull)
            return old_stderr
        def restore_stderr(old_stderr):
            sys.stderr.flush()
            os.dup2(old_stderr, 2)
            os.close(old_stderr)
        old_stderr = suppress_stderr()
        try:
            self.cap = cv2.VideoCapture(self.rtsp_url)
        finally:
            restore_stderr(old_stderr)
        
        # Настройки для более надежной работы с проблемными RTSP потоками
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)  # Минимальный буфер
        self.cap.set(cv2.CAP_PROP_FPS, 10)  # Ограничиваем FPS
        self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*'H264'))
        
        # Настройки для обработки ошибок декодирования
        self.cap.set(cv2.CAP_PROP_TIMEOUT, 5000)  # 5 секунд таймаут
        
        if not self.cap.isOpened():
            logging.error(f'Cannot open RTSP stream: {self.rtsp_url}')
            raise RuntimeError('Cannot open RTSP stream')
        
        logging.info('RTSP stream connected')
        self.error_count = 0  # Сбрасываем счетчик ошибок при успешном подключении

    async def async_frames(self):
        retry_delay = 2
        consecutive_errors = 0
        max_consecutive_errors = 5
        
        while True:
            if not self.cap or not self.cap.isOpened():
                logging.warning('RTSP stream lost, reconnecting...')
                await asyncio.sleep(retry_delay)
                try:
                    self.connect()
                    consecutive_errors = 0  # Сбрасываем счетчик при успешном переподключении
                except Exception as e:
                    logging.error(f'Reconnect failed: {e}')
                    consecutive_errors += 1
                    if consecutive_errors >= max_consecutive_errors:
                        retry_delay = min(retry_delay * 2, 30)  # Увеличиваем задержку
                    continue
            
            try:
                ret, frame = self.cap.read()
                now = time.time()
                
                if not ret or frame is None:
                    consecutive_errors += 1
                    self.error_count += 1
                    
                    if consecutive_errors >= max_consecutive_errors:
                        logging.warning(f'Too many consecutive errors ({consecutive_errors}), reconnecting...')
                        self.cap.release()
                        await asyncio.sleep(retry_delay)
                        consecutive_errors = 0
                        continue
                    
                    logging.warning(f'Failed to read frame from RTSP stream (error {consecutive_errors}/{max_consecutive_errors})')
                    await asyncio.sleep(0.5)  # Короткая пауза перед следующей попыткой
                    continue
                
                # Успешное чтение кадра
                consecutive_errors = 0
                
                # FPS calculation
                self.frame_count += 1
                if self.last_stat_time is None:
                    self.last_stat_time = now
                if now - self.last_stat_time >= 1.0:
                    self.fps = self.frame_count / (now - self.last_stat_time)
                    self.frame_count = 0
                    self.last_stat_time = now
                
                yield frame, {
                    'timestamp': now,
                    'fps': round(self.fps, 2),
                    'shape': frame.shape[:2][::-1]  # (width, height)
                }
                
                await asyncio.sleep(0.1)  # ~10 fps
                
            except Exception as e:
                consecutive_errors += 1
                self.error_count += 1
                logging.error(f'Error reading frame: {e}')
                
                if consecutive_errors >= max_consecutive_errors:
                    logging.warning(f'Too many consecutive errors ({consecutive_errors}), reconnecting...')
                    self.cap.release()
                    await asyncio.sleep(retry_delay)
                    consecutive_errors = 0
                    continue
                
                await asyncio.sleep(0.5) 