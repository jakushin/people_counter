import cv2
import asyncio
import logging

class VideoStream:
    def __init__(self, rtsp_url):
        self.rtsp_url = rtsp_url
        self.cap = cv2.VideoCapture(rtsp_url)
        if not self.cap.isOpened():
            logging.error(f'Cannot open RTSP stream: {rtsp_url}')
            raise RuntimeError('Cannot open RTSP stream')

    async def async_frames(self):
        while True:
            ret, frame = self.cap.read()
            if not ret:
                logging.error('Failed to read frame from RTSP stream')
                await asyncio.sleep(0.1)
                continue
            await asyncio.sleep(0.1)  # ~10 fps
            yield frame 