import logging
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query
from fastapi.responses import HTMLResponse
from app.video_stream import VideoStream
from app.detector import PersonDetector
import cv2
import asyncio
import json
import psutil
import time

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
    roi = None
    last_stat_time = 0
    last_cpu = 0
    last_mem = 0
    try:
        stream = VideoStream(rtsp_url)
        detector = PersonDetector()
        async for frame, stats in stream.async_frames():
            try:
                # Получаем ROI от клиента (если есть)
                while websocket.client_state.value == 1:
                    try:
                        msg = await asyncio.wait_for(websocket.receive_text(), timeout=0.01)
                        data = json.loads(msg)
                        if data.get('type') == 'roi':
                            roi = data.get('points')
                    except asyncio.TimeoutError:
                        break
                    except Exception:
                        break
                # Передаём ROI в детектор
                result = detector.detect(frame, roi=roi)
                now = time.time()
                if now - last_stat_time >= 2.0:
                    last_cpu = int(round(psutil.cpu_percent()))
                    last_mem = int(round(psutil.virtual_memory().percent))
                    last_stat_time = now
                await websocket.send_text(json.dumps({
                    'timestamp': stats['timestamp'],
                    'fps': stats['fps'],
                    'shape': stats['shape'],
                    'cpu': last_cpu,
                    'mem': last_mem,
                    'status': 'ok'
                }))
                await websocket.send_bytes(result)
            except Exception as e:
                logging.error(f'Detection error: {e}')
                await asyncio.sleep(0.1)
    except WebSocketDisconnect:
        logging.info('WebSocket disconnected')
    except Exception as e:
        logging.error(f'WebSocket error: {e}')
        await websocket.close() 