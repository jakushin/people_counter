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
        self.connect()

    def connect(self):
        if self.cap:
            self.cap.release()
        # Подавляем stderr только на время создания VideoCapture
        old_stderr = sys.stderr
        try:
            sys.stderr = open(os.devnull, 'w')
            self.cap = cv2.VideoCapture(self.rtsp_url)
        finally:
            sys.stderr.close()
            sys.stderr = old_stderr
        if not self.cap or not self.cap.isOpened():
            logging.error(f'Cannot open RTSP stream: {self.rtsp_url}')
            raise RuntimeError('Cannot open RTSP stream')
        logging.info('RTSP stream connected')

    async def async_frames(self):
        retry_delay = 2
        while True:
            if not self.cap or not self.cap.isOpened():
                logging.warning('RTSP stream lost, reconnecting...')
                await asyncio.sleep(retry_delay)
                try:
                    self.connect()
                except Exception as e:
                    logging.error(f'Reconnect failed: {e}')
                    continue
            ret, frame = self.cap.read()
            now = time.time()
            if not ret or frame is None:
                logging.warning('Failed to read frame from RTSP stream, reconnecting...')
                self.cap.release()
                await asyncio.sleep(retry_delay)
                continue
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
            await asyncio.sleep(0.01)  # минимальная пауза для предотвращения 100% CPU 