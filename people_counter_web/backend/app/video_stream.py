import cv2
import asyncio
import logging
import time
import os
import sys
import contextlib

class VideoStream:
    def __init__(self, rtsp_url):
        self.rtsp_url = rtsp_url
        self.cap = None
        self.last_frame_time = None
        self.fps = 0
        self.frame_count = 0
        self.last_stat_time = time.time()
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
        with self.suppress_stderr():
            self.cap = cv2.VideoCapture(self.rtsp_url)
        if not self.cap or not self.cap.isOpened():
            logging.error(f'Cannot open RTSP stream: {self.rtsp_url}')
            raise RuntimeError('Cannot open RTSP stream')
        logging.info('RTSP stream connected')

    async def async_frames(self):
        retry_delay = 2
        prev_time = time.time()
        while True:
            if not self.cap or not self.cap.isOpened():
                logging.warning('RTSP stream lost, reconnecting...')
                await asyncio.sleep(retry_delay)
                try:
                    self.connect()
                except Exception as e:
                    logging.error(f'Reconnect failed: {e}')
                    continue
            with self.suppress_stderr():
                ret, frame = self.cap.read()
            now = time.time()
            delta = now - prev_time
            prev_time = now
            logging.info(f'[VIDEO_STREAM] Frame received. Delta: {delta:.3f} s')
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
                logging.info(f'[VIDEO_STREAM] FPS: {self.fps:.2f}')
            yield frame, {
                'timestamp': now,
                'fps': round(self.fps, 2),
                'shape': frame.shape[:2][::-1]  # (width, height)
            }
            await asyncio.sleep(0.01)  # уменьшено для теста максимального FPS 