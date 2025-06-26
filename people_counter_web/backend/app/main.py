import logging
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Query, UploadFile, File, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from app.video_stream import VideoStream
from app.detector import PersonDetector, MultiprocessPersonDetector
import cv2
import asyncio
import json
import psutil
import time
import os
import multiprocessing
import subprocess
import shutil
from typing import List, Optional

try:
    cv2.utils.logging.setLogLevel(cv2.utils.logging.LOG_LEVEL_ERROR)
except AttributeError:
    try:
        cv2.setLogLevel(cv2.LOG_LEVEL_ERROR)
    except AttributeError:
        pass  # Нет поддержки suppression

app = FastAPI()

# Добавляем CORS middleware для работы с frontend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
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
VIDEOS_DIR = '/videos'
RTSP_PORT = 8554
current_video_file = None

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

def get_video_files() -> List[str]:
    """Получить список доступных видео файлов"""
    try:
        if not os.path.exists(VIDEOS_DIR):
            os.makedirs(VIDEOS_DIR, exist_ok=True)
        files = [f for f in os.listdir(VIDEOS_DIR) if f.lower().endswith('.mp4')]
        return sorted(files)
    except Exception as e:
        logging.error(f'Failed to get video files: {e}')
        return []

def stop_current_video():
    """Остановить текущий видео поток"""
    global current_video_file
    if current_video_file:
        logging.info(f'Stopped video: {current_video_file}')
        current_video_file = None

def start_video_stream(video_filename: str) -> bool:
    """Запустить видео как файловый поток"""
    global current_video_file
    
    # Проверяем доступность ffmpeg
    try:
        result = subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            logging.error(f'FFmpeg not available: {result.stderr}')
            return False
        logging.info(f'FFmpeg version: {result.stdout.split()[2]}')
    except Exception as e:
        logging.error(f'FFmpeg check failed: {e}')
        return False
    
    # Остановить предыдущий процесс
    stop_current_video()
    
    video_path = os.path.join(VIDEOS_DIR, video_filename)
    if not os.path.exists(video_path):
        logging.error(f'Video file not found: {video_path}')
        return False
    
    try:
        # Простая команда ffmpeg для конвертации в нужный формат
        output_path = os.path.join(VIDEOS_DIR, f'converted_{video_filename}')
        cmd = [
            'ffmpeg',
            '-i', video_path,
            '-vf', 'scale=1280:960,fps=10',  # конвертация в нужный формат
            '-c:v', 'libx264',  # кодек
            '-preset', 'ultrafast',  # быстрый пресет
            '-y',  # перезаписать файл если существует
            output_path
        ]
        
        logging.info(f'[FFMPEG] Converting video: {" ".join(cmd)}')
        
        # Конвертируем видео
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            logging.error(f'FFmpeg conversion failed. Return code: {result.returncode}')
            logging.error(f'FFmpeg stderr: {result.stderr}')
            return False
        
        logging.info(f'Video converted successfully: {output_path}')
        current_video_file = f'converted_{video_filename}'
        return True
            
    except Exception as e:
        logging.error(f'Error converting video: {e}', exc_info=True)
        return False

@app.get("/")
def root():
    return {"status": "ok"}

@app.get("/api/videos")
def get_videos():
    """Получить список доступных видео"""
    videos = get_video_files()
    return {"videos": videos}

@app.post("/api/videos/upload")
async def upload_video(file: UploadFile = File(...)):
    """Загрузить новое видео"""
    if not file.filename.lower().endswith('.mp4'):
        raise HTTPException(status_code=400, detail="Only MP4 files are supported")
    
    try:
        # Создать папку если не существует
        os.makedirs(VIDEOS_DIR, exist_ok=True)
        
        # Сохранить файл
        file_path = os.path.join(VIDEOS_DIR, file.filename)
        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        
        logging.info(f'Uploaded video: {file.filename}')
        return {"message": "Video uploaded successfully", "filename": file.filename}
        
    except Exception as e:
        logging.error(f'Error uploading video: {e}')
        raise HTTPException(status_code=500, detail="Failed to upload video")

@app.post("/api/videos/start")
def start_video(video_filename: str = Query(...)):
    """Запустить видео как RTSP поток"""
    if not os.path.exists(os.path.join(VIDEOS_DIR, video_filename)):
        raise HTTPException(status_code=404, detail="Video file not found")
    
    if start_video_stream(video_filename):
        return {"message": f"Video stream started: {video_filename}"}
    else:
        raise HTTPException(status_code=500, detail="Failed to start video stream")

@app.post("/api/videos/stop")
def stop_video():
    """Остановить текущий видео поток"""
    stop_current_video()
    return {"message": "Video stream stopped"}

@app.get("/api/videos/current")
def get_current_video():
    """Получить информацию о текущем видео"""
    return {"current_video": current_video_file}

@app.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
    user: str = Query(...),
    password: str = Query(...),
    host: str = Query(...)
):
    await websocket.accept()
    
    # Определяем источник видео
    if current_video_file:
        # Используем конвертированное видео как файл
        video_path = os.path.join(VIDEOS_DIR, current_video_file)
        logging.info(f'[WS] Using video file: {current_video_file} -> {video_path}')
        # Передаем путь к файлу вместо RTSP URL
        rtsp_url = video_path
    else:
        # Используем камеру
        rtsp_url = f"rtsp://{user}:{password}@{host}:554/axis-media/media.amp?streamprofile=stream1"
        logging.info(f'[WS] Using camera stream: {rtsp_url}')
    
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
                result, crop_h, crop_w, imgsz = detector.detect(frame, roi=roi)
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
                    'status': 'ok',
                    'crop_h': crop_h,
                    'crop_w': crop_w,
                    'imgsz': imgsz
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