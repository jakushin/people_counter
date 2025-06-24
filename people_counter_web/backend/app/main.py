import logging
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query
from fastapi.responses import HTMLResponse
from app.video_stream import VideoStream
from app.detector import PersonDetector
import cv2
import asyncio
import json

app = FastAPI()
logging.basicConfig(filename='app.log', level=logging.INFO)

@app.get("/")
def root():
    return {"status": "ok"}

@app.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    user: str = Query(...),
    password: str = Query(...),
    host: str = Query(...)
):
    await websocket.accept()
    rtsp_url = f"rtsp://{user}:{password}@{host}:554/axis-media/media.amp?streamprofile=stream1"
    try:
        stream = VideoStream(rtsp_url)
        detector = PersonDetector()
        async for frame, stats in stream.async_frames():
            try:
                result = detector.detect(frame)
                # Отправляем статистику как JSON
                await websocket.send_text(json.dumps({
                    'timestamp': stats['timestamp'],
                    'fps': stats['fps'],
                    'shape': stats['shape'],
                    'bitrate': None  # Можно добавить bitrate позже
                }))
                # Отправляем кадр как бинарные данные
                await websocket.send_bytes(result)
            except Exception as e:
                logging.error(f'Detection error: {e}')
                await asyncio.sleep(0.1)
    except WebSocketDisconnect:
        logging.info('WebSocket disconnected')
    except Exception as e:
        logging.error(f'WebSocket error: {e}')
        await websocket.close() 