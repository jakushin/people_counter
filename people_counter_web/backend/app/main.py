import logging
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query
from fastapi.responses import HTMLResponse
from app.video_stream import VideoStream
from app.detector import PersonDetector, MultiprocessPersonDetector
import cv2
import asyncio
import json
import psutil
import time
import os
import multiprocessing

try:
    cv2.utils.logging.setLogLevel(cv2.utils.logging.LOG_LEVEL_ERROR)
except AttributeError:
    try:
        cv2.setLogLevel(cv2.LOG_LEVEL_ERROR)
    except AttributeError:
        pass  # Нет поддержки suppression

app = FastAPI()
logging.basicConfig(filename='app.log', level=logging.INFO)
logging.info(f"[START] CPU count: {multiprocessing.cpu_count()}, psutil.cpu_count(logical=True): {psutil.cpu_count(logical=True)}, psutil.cpu_count(logical=False): {psutil.cpu_count(logical=False)}")
logging.info(f"[START] Initial CPU usage: {psutil.cpu_percent()}%")

# Форсируем переменные окружения для потоков
os.environ['OMP_NUM_THREADS'] = str(multiprocessing.cpu_count())
os.environ['MKL_NUM_THREADS'] = str(multiprocessing.cpu_count())
os.environ['NUMEXPR_NUM_THREADS'] = str(multiprocessing.cpu_count())
os.environ['OPENBLAS_NUM_THREADS'] = str(multiprocessing.cpu_count())
os.environ['VECLIB_MAXIMUM_THREADS'] = str(multiprocessing.cpu_count())
logging.info(f"[ENV] OMP_NUM_THREADS={os.environ['OMP_NUM_THREADS']}, MKL_NUM_THREADS={os.environ['MKL_NUM_THREADS']}, NUMEXPR_NUM_THREADS={os.environ['NUMEXPR_NUM_THREADS']}, OPENBLAS_NUM_THREADS={os.environ['OPENBLAS_NUM_THREADS']}, VECLIB_MAXIMUM_THREADS={os.environ['VECLIB_MAXIMUM_THREADS']}")

ROI_FILE = '/data/roi.json'

def load_roi():
    try:
        if os.path.exists(ROI_FILE):
            with open(ROI_FILE, 'r') as f:
                return json.load(f)
    except Exception as e:
        logging.error(f'Failed to load ROI: {e}')
    return None

def save_roi(roi):
    try:
        os.makedirs(os.path.dirname(ROI_FILE), exist_ok=True)
        with open(ROI_FILE, 'w') as f:
            json.dump(roi, f)
    except Exception as e:
        logging.error(f'Failed to save ROI: {e}')

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
    roi = load_roi()
    # Сразу отправляем ROI клиенту, если оно есть
    if roi:
        await websocket.send_text(json.dumps({"type": "roi", "points": roi}))
    last_stat_time = 0
    last_cpu = 0
    last_mem = 0
    last_send_time = time.time()
    try:
        stream = VideoStream(rtsp_url)
        #detector = PersonDetector()
        detector = MultiprocessPersonDetector(num_workers=4)
        logging.info(f"[MAIN] Using detector class: {type(detector)}, PID: {os.getpid()}")
        async for frame, stats in stream.async_frames():
            try:
                roi_changed = False
                while websocket.client_state.value == 1:
                    try:
                        msg = await asyncio.wait_for(websocket.receive_text(), timeout=0.01)
                        data = json.loads(msg)
                        if data.get('type') == 'roi':
                            roi = data.get('points')
                            save_roi(roi)
                            roi_changed = True
                    except asyncio.TimeoutError:
                        break
                    except Exception:
                        break
                t0 = time.time()
                result = detector.detect(frame, roi=roi)
                t1 = time.time()
                now = time.time()
                logging.info(f'[MAIN] Detect+prep: {t1-t0:.3f}s, Time since last send: {now-last_send_time:.3f}s')
                last_send_time = now
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