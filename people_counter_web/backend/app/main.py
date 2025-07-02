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
debug_log(f"[START] CPU count: {multiprocessing.cpu_count()}, psutil.cpu_count(logical=True): {psutil.cpu_count(logical=True)}, psutil.cpu_count(logical=False): {psutil.cpu_count(logical=False)}")
debug_log(f"[START] Initial CPU usage: {psutil.cpu_percent()}%")

# Форсируем переменные окружения для потоков
os.environ['OMP_NUM_THREADS'] = str(multiprocessing.cpu_count())
os.environ['MKL_NUM_THREADS'] = str(multiprocessing.cpu_count())
os.environ['NUMEXPR_NUM_THREADS'] = str(multiprocessing.cpu_count())
os.environ['OPENBLAS_NUM_THREADS'] = str(multiprocessing.cpu_count())
os.environ['VECLIB_MAXIMUM_THREADS'] = str(multiprocessing.cpu_count())
debug_log(f"[ENV] OMP_NUM_THREADS={os.environ['OMP_NUM_THREADS']}, MKL_NUM_THREADS={os.environ['MKL_NUM_THREADS']}, NUMEXPR_NUM_THREADS={os.environ['NUMEXPR_NUM_THREADS']}, OPENBLAS_NUM_THREADS={os.environ['OPENBLAS_NUM_THREADS']}, VECLIB_MAXIMUM_THREADS={os.environ['VECLIB_MAXIMUM_THREADS']}")

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

def save_roi(points):
    try:
        os.makedirs(os.path.dirname(ROI_FILE), exist_ok=True)
        with open(ROI_FILE, 'w') as f:
            json.dump(points, f)
    except Exception as e:
        logging.error(f'Failed to save ROI: {e}')

def get_video_files() -> List[str]:
    """Получить список доступных видео файлов"""
    try:
        if not os.path.exists(VIDEOS_DIR):
            os.makedirs(VIDEOS_DIR, exist_ok=True)
        # Показываем только конвертированные файлы (без префикса tmp_)
        files = []
        all_files = os.listdir(VIDEOS_DIR)
        debug_log(f'[API] All files in directory: {all_files}')
        
        for f in all_files:
            # Показываем только файлы .mp4, которые НЕ начинаются с tmp_
            if f.lower().endswith('.mp4') and not f.startswith('tmp_'):
                files.append(f)
                debug_log(f'[API] Added video file: {f}')
        
        result = sorted(files)
        debug_log(f'[API] Final video list: {result}')
        return result
    except Exception as e:
        logging.error(f'[API] Failed to get video files: {e}', exc_info=True)
        return []

def stop_current_video():
    """Остановить текущий видео поток"""
    global current_video_file
    if current_video_file:
        debug_log(f'Stopped video: {current_video_file}')
        current_video_file = None

def start_video_stream(video_filename: str) -> bool:
    """Проверить и запустить видео файл"""
    global current_video_file
    
    debug_log(f'[API] start_video_stream called with: {video_filename}')
    
    # Проверяем доступность ffmpeg
    try:
        result = subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            logging.error(f'[API] FFmpeg not available: {result.stderr}')
            return False
        debug_log(f'[API] FFmpeg version: {result.stdout.split()[2]}')
    except Exception as e:
        logging.error(f'[API] FFmpeg check failed: {e}')
        return False
    
    # Проверяем существование конвертированного файла (без префикса)
    video_path = os.path.join(VIDEOS_DIR, video_filename)
    
    debug_log(f'[API] Looking for video file: {video_path}')
    
    # Проверяем, что есть в папке
    try:
        all_files = os.listdir(VIDEOS_DIR)
        debug_log(f'[API] Files in videos directory: {all_files}')
        
        # Ищем файл по точному совпадению
        if video_filename not in all_files:
            logging.error(f'[API] Video file not found: {video_filename}')
            return False
            
        debug_log(f'[API] Found file: {video_path}')
        
    except Exception as e:
        logging.error(f'[API] Cannot list directory: {e}')
        return False
    
    file_size = os.path.getsize(video_path)
    debug_log(f'[API] Video file exists: {video_filename}, size: {file_size} bytes')
    
    # Проверяем, что файл не пустой
    if file_size == 0:
        logging.error(f'[API] Video file is empty: {video_path}')
        return False
    
    current_video_file = video_filename
    debug_log(f'[API] Video stream started successfully: {video_filename}')
    return True

@app.get("/")
def root():
    return {"status": "ok"}

@app.get("/api/videos")
def list_videos():
    """Получить список доступных видео файлов"""
    return {"videos": get_video_files()}

@app.post("/api/videos/upload")
async def upload_video(file: UploadFile = File(...)):
    """Загрузить новое видео"""
    if not file.filename.lower().endswith('.mp4'):
        raise HTTPException(status_code=400, detail="Only MP4 files are supported")
    
    try:
        # Создать папку если не существует
        os.makedirs(VIDEOS_DIR, exist_ok=True)
        
        # Сохранить оригинальный файл с префиксом tmp_
        tmp_filename = f"tmp_{file.filename}"
        tmp_path = os.path.join(VIDEOS_DIR, tmp_filename)
        with open(tmp_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        
        debug_log(f'[API] Original video uploaded as: {tmp_filename}')
        
        # Конвертируем в нужный формат с оригинальным именем
        converted_path = os.path.join(VIDEOS_DIR, file.filename)
        
        cmd = [
            'ffmpeg',
            '-i', tmp_path,
            '-vf', 'scale=1280:960,fps=10',  # конвертация в нужный формат
            '-c:v', 'libx264',  # кодек
            '-preset', 'faster',  # более быстрый пресет, но с лучшим сжатием
            '-crf', '23',  # качество сжатия (18-28 хорошее качество)
            '-maxrate', '2M',  # максимальный битрейт
            '-bufsize', '4M',  # размер буфера
            '-y',  # перезаписать файл если существует
            converted_path
        ]
        
        debug_log(f'[API] Converting video: {" ".join(cmd)}')
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        
        if result.returncode != 0:
            logging.error(f'[API] FFmpeg conversion failed: {result.stderr}')
            raise HTTPException(status_code=500, detail="Video conversion failed")
        
        # Удаляем временный файл
        os.remove(tmp_path)
        debug_log(f'[API] Video converted successfully: {file.filename}')
        debug_log(f'[API] Temporary file removed: {tmp_filename}')
        
        return {"filename": file.filename, "message": f"Video uploaded and converted: {file.filename}"}
        
    except Exception as e:
        logging.error(f'[API] Upload error: {e}')
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/videos/start")
def start_video(video_filename: str = Query(...)):
    """Запустить видео как RTSP поток"""
    global current_video_file
    
    debug_log(f'[API] start_video called with: {video_filename}')
    debug_log(f'[API] current_video_file before: {current_video_file}')
    
    video_path = os.path.join(VIDEOS_DIR, video_filename)
    if not os.path.exists(video_path):
        raise HTTPException(status_code=404, detail="Video file not found")
    
    debug_log(f'[API] Starting video: {video_filename}')
    current_video_file = video_filename
    debug_log(f'[API] current_video_file after set: {current_video_file}')
    
    if start_video_stream(video_filename):
        debug_log(f'[API] Video started successfully: {video_filename}')
        debug_log(f'[API] current_video_file after success: {current_video_file}')
        return {"message": f"Video stream started: {video_filename}"}
    else:
        logging.error(f'[API] Failed to start video: {video_filename}')
        current_video_file = None  # Сбрасываем при ошибке
        debug_log(f'[API] current_video_file after failure: {current_video_file}')
        raise HTTPException(status_code=500, detail="Failed to start video stream")

@app.post("/api/videos/stop")
def stop_video():
    """Остановить текущий видео поток"""
    global current_video_file
    debug_log(f'[API] stop_video called, current_video_file: {current_video_file}')
    if current_video_file:
        debug_log(f'[API] Stopping video: {current_video_file}')
        current_video_file = None
        debug_log(f'[API] current_video_file after stop: {current_video_file}')
        return {"message": "Video stream stopped"}
    else:
        debug_log('[API] No video to stop')
        return {"message": "No video stream to stop"}

@app.get("/api/videos/current")
def get_current_video():
    """Получить информацию о текущем видео"""
    return {"current_video": current_video_file}

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    global current_video_file
    await websocket.accept()
    debug_log(f'[WS] WebSocket connection accepted')
    debug_log(f'[WS] current_video_file at connection start: {current_video_file}')
    logging.info(f'[WS] WebSocket connection accepted, current_video_file at start: {current_video_file}')
    
    # Получаем учетные данные через первое сообщение
    try:
        # Ждем первое сообщение с учетными данными
        msg = await websocket.receive_text()
        data = json.loads(msg)
        
        if data.get('type') == 'auth':
            user = data.get('user', 'dummy')
            password = data.get('password', 'dummy')
            host = data.get('host', 'dummy')
            debug_log(f'[WS] Authentication received. User: {user}, Host: {host}')
        else:
            # Если первое сообщение не auth, используем dummy значения
            user, password, host = 'dummy', 'dummy', 'dummy'
            debug_log(f'[WS] No auth message, using dummy credentials')
    except Exception as e:
        # В случае ошибки используем dummy значения
        user, password, host = 'dummy', 'dummy', 'dummy'
        debug_log(f'[WS] Auth error, using dummy credentials: {e}')
    
    # Определяем источник видео
    if current_video_file:
        # Используем конвертированное видео как файл
        video_path = os.path.join(VIDEOS_DIR, current_video_file)
        debug_log(f'[WS] Using video file: {current_video_file} -> {video_path}')
        logging.info(f'[WS] Source selected: VIDEO_FILE, current_video_file: {current_video_file}, video_path: {video_path}')
        # Передаем путь к файлу вместо RTSP URL
        rtsp_url = video_path
        source_type = "VIDEO_FILE"
    else:
        # Используем камеру
        # Явно сбрасываем current_video_file, если вдруг он не None
        if current_video_file is not None:
            debug_log(f'[WS] Switching to CAMERA, resetting current_video_file from {current_video_file} to None')
            logging.info(f'[WS] Switching to CAMERA, resetting current_video_file from {current_video_file} to None')
            current_video_file = None
        rtsp_url = f"rtsp://{user}:{password}@{host}:554/axis-media/media.amp?streamprofile=stream1"
        debug_log(f'[WS] Using camera stream: {rtsp_url}')
        logging.info(f'[WS] Source selected: CAMERA, current_video_file: {current_video_file}, rtsp_url: {rtsp_url}')
        source_type = "CAMERA"

    debug_log(f'[WS] Source type: {source_type}, URL: {rtsp_url}')
    debug_log(f'[WS] Current video file state: {current_video_file}')
    logging.info(f'[WS] Final source type: {source_type}, current_video_file: {current_video_file}, URL: {rtsp_url}')
    
    roi = load_roi()
    # Сразу отправляем ROI клиенту, если оно есть
    if roi:
        try:
            await websocket.send_text(json.dumps({"type": "roi", "points": roi}))
            debug_log(f'[WS] ROI sent to client: {roi}')
        except Exception as e:
            logging.error(f'[WS] Failed to send ROI: {e}')
    
    last_stat_time = 0
    last_cpu = 0
    last_mem = 0
    last_send_time = time.time()
    frame_count = 0
    
    # Инициализируем переменные метрик
    avg_cpu_cores = []
    avg_disk_percent = 0
    avg_read_speed = 0
    avg_write_speed = 0
    avg_read_latency = 0
    avg_write_latency = 0
    avg_net_sent_mbps = 0
    avg_net_recv_mbps = 0
    mem_total_gb = 0
    mem_used_gb = 0
    mem_available_gb = 0
    disk_total_gb = 0
    disk_used_gb = 0
    
    try:
        debug_log(f'[WS] Creating VideoStream for: {rtsp_url}')
        stream = VideoStream(rtsp_url)
        debug_log(f'[WS] VideoStream created successfully')
        
        #detector = PersonDetector()
        detector = MultiprocessPersonDetector(num_workers=4)
        debug_log(f"[MAIN] Using detector class: {type(detector)}, PID: {os.getpid()}")
        debug_log(f"[MAIN] VideoStream created successfully for: {rtsp_url}")
        
        async for frame, stats in stream.async_frames():
            frame_count += 1
            # Логируем только каждые 100 кадров для уменьшения объема логов
            if frame_count % 100 == 1:
                # Логируем информацию о кадрах всегда, так как это важно для диагностики
                logging.info(f"[MAIN] Frame {frame_count}: shape={frame.shape}, fps={stats.get('fps', 'N/A')}")
            
            try:
                # Проверяем состояние WebSocket перед обработкой
                if websocket.client_state.value != 1:
                    logging.warning(f'[WS] WebSocket not connected, state: {websocket.client_state.value}')
                    break
                
                roi_changed = False
                # Обрабатываем входящие сообщения
                while websocket.client_state.value == 1:
                    try:
                        msg = await asyncio.wait_for(websocket.receive_text(), timeout=0.01)
                        data = json.loads(msg)
                        if data.get('type') == 'roi':
                            roi = data.get('points')
                            save_roi(roi)
                            roi_changed = True
                            # Логируем обновление ROI всегда, так как это важно
                            logging.info(f'[WS] ROI updated: {roi}')
                    except asyncio.TimeoutError:
                        break
                    except Exception as e:
                        logging.warning(f'[WS] Error processing message: {e}')
                        break
                
                # Детекция
                t0 = time.time()
                result, crop_h, crop_w, imgsz = detector.detect(frame, roi=roi)
                t1 = time.time()
                now = time.time()
                
                detect_time = t1 - t0
                time_since_last = now - last_send_time
                
                # Логируем только медленные кадры или каждые 100 кадров
                if detect_time > 0.2 or frame_count % 100 == 1:
                    # Логируем время обработки всегда, так как это важно для диагностики
                    logging.info(f'[MAIN] Frame {frame_count}: Detect+prep: {detect_time:.3f}s, Time since last send: {time_since_last:.3f}s')
                last_send_time = now
                
                # Отправляем статистику каждую секунду (максимальная частота)
                if now - last_stat_time >= 1.0:
                    # Дебаг логи для диагностики
                    debug_log(f'[DEBUG] Sending stats update: time_since_last={now - last_stat_time:.1f}s, frame_count={frame_count}')
                    
                    # CPU информация
                    cpu_percent = round(psutil.cpu_percent(interval=None))
                    cpu_per_core = [round(x) for x in psutil.cpu_percent(interval=None, percpu=True)]
                    
                    # Память информация
                    mem = psutil.virtual_memory()
                    mem_percent = mem.percent
                    mem_total_gb = round(mem.total / (1024**3))
                    mem_used_gb = round(mem.used / (1024**3))
                    mem_available_gb = round(mem.available / (1024**3))
                    
                    # Диск информация
                    disk = psutil.disk_usage('/')
                    disk_percent = disk.percent
                    disk_total_gb = round(disk.total / (1024**3))
                    disk_used_gb = round(disk.used / (1024**3))
                    
                    # Диск I/O статистика (текущая скорость)
                    disk_io = psutil.disk_io_counters()
                    if disk_io:
                        # Получаем текущие значения
                        current_read_bytes = disk_io.read_bytes
                        current_write_bytes = disk_io.write_bytes
                        current_read_count = disk_io.read_count
                        current_write_count = disk_io.write_count
                        
                        # Вычисляем скорость относительно предыдущих значений
                        if hasattr(stream, '_prev_disk_io'):
                            time_diff = now - stream._prev_disk_io['time']
                            if time_diff > 0:
                                read_speed = (current_read_bytes - stream._prev_disk_io['read_bytes']) / time_diff
                                write_speed = (current_write_bytes - stream._prev_disk_io['write_bytes']) / time_diff
                                read_latency = (current_read_count - stream._prev_disk_io['read_count']) / time_diff
                                write_latency = (current_write_count - stream._prev_disk_io['write_count']) / time_diff
                            else:
                                read_speed = write_speed = read_latency = write_latency = 0
                        else:
                            read_speed = write_speed = read_latency = write_latency = 0
                        
                        # Сохраняем текущие значения для следующего расчета
                        stream._prev_disk_io = {
                            'time': now,
                            'read_bytes': current_read_bytes,
                            'write_bytes': current_write_bytes,
                            'read_count': current_read_count,
                            'write_count': current_write_count
                        }
                    else:
                        read_speed = write_speed = read_latency = write_latency = 0
                    
                    # Сетевая информация (текущая скорость в Mbps)
                    net_io = psutil.net_io_counters()
                    current_sent_bytes = net_io.bytes_sent
                    current_recv_bytes = net_io.bytes_recv
                    
                    # Вычисляем текущую скорость сети
                    if hasattr(stream, '_prev_net_io'):
                        time_diff = now - stream._prev_net_io['time']
                        if time_diff > 0:
                            net_sent_mbps = ((current_sent_bytes - stream._prev_net_io['sent_bytes']) * 8) / (1024**2 * time_diff)
                            net_recv_mbps = ((current_recv_bytes - stream._prev_net_io['recv_bytes']) * 8) / (1024**2 * time_diff)
                        else:
                            net_sent_mbps = net_recv_mbps = 0
                    else:
                        net_sent_mbps = net_recv_mbps = 0
                    
                    # Сохраняем текущие значения для следующего расчета
                    stream._prev_net_io = {
                        'time': now,
                        'sent_bytes': current_sent_bytes,
                        'recv_bytes': current_recv_bytes
                    }
                    
                    # Сглаживание метрик за 2 секунды (2 измерения по 1 секунде)
                    if not hasattr(stream, '_metrics_history'):
                        stream._metrics_history = []
                    
                    current_metrics = {
                        'cpu_all': cpu_percent,
                        'cpu_cores': cpu_per_core,
                        'mem_percent': mem_percent,
                        'disk_percent': disk_percent,
                        'read_speed': read_speed,
                        'write_speed': write_speed,
                        'read_latency': read_latency,
                        'write_latency': write_latency,
                        'net_sent_mbps': net_sent_mbps,
                        'net_recv_mbps': net_recv_mbps,
                        'timestamp': now
                    }
                    
                    stream._metrics_history.append(current_metrics)
                    
                    # Оставляем только последние 2 измерений (2 секунды)
                    if len(stream._metrics_history) > 2:
                        stream._metrics_history.pop(0)
                    
                    # Вычисляем средние значения
                    if len(stream._metrics_history) > 0:
                        avg_cpu_all = round(sum(m['cpu_all'] for m in stream._metrics_history) / len(stream._metrics_history))
                        avg_mem_percent = round(sum(m['mem_percent'] for m in stream._metrics_history) / len(stream._metrics_history))
                        avg_disk_percent = round(sum(m['disk_percent'] for m in stream._metrics_history) / len(stream._metrics_history))
                        avg_read_speed = sum(m['read_speed'] for m in stream._metrics_history) / len(stream._metrics_history)
                        avg_write_speed = sum(m['write_speed'] for m in stream._metrics_history) / len(stream._metrics_history)
                        avg_read_latency = sum(m['read_latency'] for m in stream._metrics_history) / len(stream._metrics_history)
                        avg_write_latency = sum(m['write_latency'] for m in stream._metrics_history) / len(stream._metrics_history)
                        avg_net_sent_mbps = sum(m['net_sent_mbps'] for m in stream._metrics_history) / len(stream._metrics_history)
                        avg_net_recv_mbps = sum(m['net_recv_mbps'] for m in stream._metrics_history) / len(stream._metrics_history)
                        
                        # Для CPU ядер вычисляем среднее по каждому ядру
                        num_cores = len(cpu_per_core)
                        avg_cpu_cores = []
                        for core_idx in range(num_cores):
                            core_avg = sum(m['cpu_cores'][core_idx] for m in stream._metrics_history) / len(stream._metrics_history)
                            avg_cpu_cores.append(round(core_avg))
                    else:
                        # Если нет истории, используем текущие значения
                        avg_cpu_all = cpu_percent
                        avg_cpu_cores = cpu_per_core
                        avg_mem_percent = mem_percent
                        avg_disk_percent = disk_percent
                        avg_read_speed = read_speed
                        avg_write_speed = write_speed
                        avg_read_latency = read_latency
                        avg_write_latency = write_latency
                        avg_net_sent_mbps = net_sent_mbps
                        avg_net_recv_mbps = net_recv_mbps
                    
                    # Всегда обновляем значения и время (убираем условие с порогом 5%)
                    last_cpu = avg_cpu_all
                    last_mem = avg_mem_percent
                    last_stat_time = now
                    
                    # Логируем статистику всегда, так как она важна для диагностики
                    logging.info(f'[WS] Stats update: CPU={last_cpu}%, MEM={last_mem}%, DISK={avg_disk_percent}%')
                    
                    # Дебаг логи для диагностики
                    debug_log(f'[DEBUG] Metrics calculated: history_size={len(stream._metrics_history)}, avg_cpu={avg_cpu_all}%, avg_mem={avg_mem_percent}%')
                
                # Отправляем кадр клиенту
                try:
                    # Проверяем состояние перед отправкой
                    if websocket.client_state.value != 1:
                        logging.warning(f'[WS] WebSocket disconnected before send, state: {websocket.client_state.value}')
                        break
                    
                    # Отправляем метаданные для диагностики
                    metadata = {
                        'timestamp': stats['timestamp'],
                        'fps': stats['fps'],
                        'shape': stats['shape'],
                        'cpu_all': last_cpu,
                        'cpu_cores': avg_cpu_cores,
                        'mem_percent': last_mem,
                        'mem_total_gb': mem_total_gb,
                        'mem_used_gb': mem_used_gb,
                        'mem_available_gb': mem_available_gb,
                        'disk_percent': avg_disk_percent,
                        'disk_total_gb': disk_total_gb,
                        'disk_used_gb': disk_used_gb,
                        'disk_read_speed': avg_read_speed,
                        'disk_write_speed': avg_write_speed,
                        'disk_read_latency': avg_read_latency,
                        'disk_write_latency': avg_write_latency,
                        'net_sent_mbps': avg_net_sent_mbps,
                        'net_recv_mbps': avg_net_recv_mbps,
                        'status': 'ok',
                        'crop_h': crop_h,
                        'crop_w': crop_w,
                        'imgsz': imgsz,
                        'frame_count': frame_count,
                        'source_type': source_type
                    }
                    
                    # Дебаг логи для диагностики отправки
                    debug_log(f'[DEBUG] Sending metadata: frame_count={frame_count}, metadata_size={len(str(metadata))} chars')
                    
                    await websocket.send_text(json.dumps(metadata))
                    
                    # Проверяем состояние перед отправкой изображения
                    if websocket.client_state.value != 1:
                        logging.warning(f'[WS] WebSocket disconnected before image send, state: {websocket.client_state.value}')
                        break
                    
                    # Отправляем изображение
                    await websocket.send_bytes(result)
                    
                    # Логируем только каждые 200 кадров
                    if frame_count % 200 == 1:
                        verbose_log(f'[WS] Frame {frame_count} sent successfully')
                    
                except Exception as e:
                    logging.error(f'[WS] Error sending frame {frame_count}: {e}')
                    break
                    
            except Exception as e:
                logging.error(f'[WS] Detection error in frame {frame_count}: {e}')
                await asyncio.sleep(0.1)
                
    except Exception as e:
        logging.error(f'[WS] Error creating VideoStream: {e}', exc_info=True)
        try:
            if websocket.client_state.value == 1:
                await websocket.send_text(json.dumps({
                    'status': 'error',
                    'message': f'Failed to create video stream: {str(e)}'
                }))
        except Exception as send_error:
            logging.error(f'[WS] Failed to send error message: {send_error}')
    except WebSocketDisconnect:
        debug_log(f'[WS] WebSocket disconnected after {frame_count} frames')
    except Exception as e:
        logging.error(f'[WS] WebSocket error: {e}')
        try:
            await websocket.close()
        except:
            pass 