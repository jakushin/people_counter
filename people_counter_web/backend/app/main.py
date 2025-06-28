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
        # Показываем только конвертированные файлы и убираем префикс converted_
        files = []
        all_files = os.listdir(VIDEOS_DIR)
        logging.info(f'[API] All files in directory: {all_files}')
        
        for f in all_files:
            if f.startswith('converted_') and f.lower().endswith('.mp4'):
                # Убираем префикс converted_ для отображения
                original_name = f[10:]  # убираем 'converted_'
                files.append(original_name)
                logging.info(f'[API] Added video file: {original_name} (from {f})')
        
        result = sorted(files)
        logging.info(f'[API] Final video list: {result}')
        return result
    except Exception as e:
        logging.error(f'[API] Failed to get video files: {e}', exc_info=True)
        return []

def stop_current_video():
    """Остановить текущий видео поток"""
    global current_video_file
    if current_video_file:
        logging.info(f'Stopped video: {current_video_file}')
        current_video_file = None

def start_video_stream(video_filename: str) -> bool:
    """Проверить и запустить видео файл"""
    global current_video_file
    
    logging.info(f'[API] start_video_stream called with: {video_filename}')
    
    # Проверяем доступность ffmpeg
    try:
        result = subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            logging.error(f'[API] FFmpeg not available: {result.stderr}')
            return False
        logging.info(f'[API] FFmpeg version: {result.stdout.split()[2]}')
    except Exception as e:
        logging.error(f'[API] FFmpeg check failed: {e}')
        return False
    
    # Проверяем существование конвертированного файла
    converted_filename = f"converted_{video_filename}"
    converted_path = os.path.join(VIDEOS_DIR, converted_filename)
    
    logging.info(f'[API] Looking for converted file: {converted_path}')
    
    # Проверяем, что есть в папке
    try:
        all_files = os.listdir(VIDEOS_DIR)
        logging.info(f'[API] Files in videos directory: {all_files}')
        
        # Ищем файл по точному совпадению
        found_file = None
        for file in all_files:
            if file == converted_filename:
                found_file = file
                break
        
        if found_file is None:
            logging.error(f'[API] Converted video file not found: {converted_filename}')
            return False
            
        # Используем найденный файл
        actual_path = os.path.join(VIDEOS_DIR, found_file)
        logging.info(f'[API] Found file: {actual_path}')
        
    except Exception as e:
        logging.error(f'[API] Cannot list directory: {e}')
        return False
    
    file_size = os.path.getsize(actual_path)
    logging.info(f'[API] Converted video file exists: {found_file}, size: {file_size} bytes')
    
    # Проверяем, что файл не пустой
    if file_size == 0:
        logging.error(f'[API] Converted video file is empty: {actual_path}')
        return False
    
    current_video_file = found_file
    logging.info(f'[API] Video stream started successfully: {found_file}')
    return True

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
        
        # Сохранить оригинальный файл
        original_path = os.path.join(VIDEOS_DIR, file.filename)
        with open(original_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        
        logging.info(f'[API] Original video uploaded: {file.filename}')
        
        # Конвертируем в нужный формат сразу при загрузке
        converted_filename = f"converted_{file.filename}"
        converted_path = os.path.join(VIDEOS_DIR, converted_filename)
        
        cmd = [
            'ffmpeg',
            '-i', original_path,
            '-vf', 'scale=1280:960,fps=10',  # конвертация в нужный формат
            '-c:v', 'libx264',  # кодек
            '-preset', 'ultrafast',  # быстрый пресет
            '-y',  # перезаписать файл если существует
            converted_path
        ]
        
        logging.info(f'[API] Converting video: {" ".join(cmd)}')
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        
        if result.returncode != 0:
            logging.error(f'[API] FFmpeg conversion failed. Return code: {result.returncode}')
            logging.error(f'[API] FFmpeg stderr: {result.stderr}')
            # Удаляем оригинальный файл если конвертация не удалась
            os.remove(original_path)
            raise HTTPException(status_code=500, detail="Failed to convert video")
        
        logging.info(f'[API] Video converted successfully: {converted_filename}')
        
        # Удаляем оригинальный файл после успешной конвертации
        try:
            os.remove(original_path)
            logging.info(f'[API] Original file removed: {file.filename}')
        except Exception as e:
            logging.warning(f'[API] Failed to remove original file: {e}')
        
        return {"message": "Video uploaded and converted successfully", "filename": file.filename, "converted_filename": converted_filename}
        
    except Exception as e:
        logging.error(f'[API] Error uploading video: {e}', exc_info=True)
        raise HTTPException(status_code=500, detail="Failed to upload video")

@app.post("/api/videos/start")
def start_video(video_filename: str = Query(...)):
    """Запустить видео как RTSP поток"""
    global current_video_file
    
    if not os.path.exists(os.path.join(VIDEOS_DIR, video_filename)):
        raise HTTPException(status_code=404, detail="Video file not found")
    
    logging.info(f'[API] Starting video: {video_filename}')
    current_video_file = video_filename
    
    if start_video_stream(video_filename):
        logging.info(f'[API] Video started successfully: {video_filename}')
        return {"message": f"Video stream started: {video_filename}"}
    else:
        logging.error(f'[API] Failed to start video: {video_filename}')
        current_video_file = None  # Сбрасываем при ошибке
        raise HTTPException(status_code=500, detail="Failed to start video stream")

@app.post("/api/videos/stop")
def stop_video():
    """Остановить текущий видео поток"""
    global current_video_file
    if current_video_file:
        logging.info(f'[API] Stopping video: {current_video_file}')
        current_video_file = None
        return {"message": "Video stream stopped"}
    else:
        logging.info('[API] No video to stop')
        return {"message": "No video stream to stop"}

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
    
    logging.info(f'[WS] Starting video stream with source: {rtsp_url}')
    logging.info(f'[WS] Current video file state: {current_video_file}')
    last_stat_time = 0
    last_cpu = 0
    last_mem = 0
    last_send_time = time.time()
    try:
        logging.info(f'[WS] Creating VideoStream for: {rtsp_url}')
        stream = VideoStream(rtsp_url)
        logging.info(f'[WS] VideoStream created successfully')
        
        #detector = PersonDetector()
        detector = MultiprocessPersonDetector(num_workers=4)
        logging.info(f"[MAIN] Using detector class: {type(detector)}, PID: {os.getpid()}")
        logging.info(f"[MAIN] VideoStream created successfully for: {rtsp_url}")
        
        async for frame, stats in stream.async_frames():
            logging.info(f"[MAIN] Received frame: shape={frame.shape}, stats={stats}")
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
    except Exception as e:
        logging.error(f'[WS] Error creating VideoStream: {e}', exc_info=True)
        await websocket.send_text(json.dumps({
            'status': 'error',
            'message': f'Failed to create video stream: {str(e)}'
        }))
    except WebSocketDisconnect:
        logging.info('WebSocket disconnected')
    except Exception as e:
        logging.error(f'WebSocket error: {e}')
        await websocket.close() 