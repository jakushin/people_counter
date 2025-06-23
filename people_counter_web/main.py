# main.py
import logging
from fastapi import FastAPI, Form
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from ultralytics import YOLO

from line_config import load_line_config, save_line_config
from rtsp_reader import RTSPReader

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

app = FastAPI()

# Настройки
RTSP_URL     = "rtsp://<user>:<pass>@<camera-ip>/stream"
TARGET_WIDTH = 960

# Подгружаем модель и конфиг линий
model = YOLO("yolov8n.pt")
start, end = load_line_config()

# Инициализируем RTSP reader и монтируем статику
rtsp_reader = RTSPReader(RTSP_URL, start, end, TARGET_WIDTH, model)
rtsp_reader.start()

app.mount("/static", StaticFiles(directory="static"), name="static")

@app.get("/", response_class=HTMLResponse)
async def index():
    return HTMLResponse(open("static/index.html", "r", encoding="utf-8").read())

@app.get("/video")
def video_feed():
    return StreamingResponse(rtsp_reader.frame_generator(),
                             media_type="multipart/x-mixed-replace; boundary=frame")

@app.get("/get_line")
async def get_line():
    start, end = rtsp_reader.line_start, rtsp_reader.line_end
    return JSONResponse({"line_start": start, "line_end": end})

@app.post("/set_line")
async def set_line(
    x1: int = Form(...), y1: int = Form(...),
    x2: int = Form(...), y2: int = Form(...)
):
    rtsp_reader.line_start = (x1, y1)
    rtsp_reader.line_end   = (x2, y2)
    save_line_config(rtsp_reader.line_start, rtsp_reader.line_end)
    return {"status": "ok"}

@app.get("/get_status")
async def get_status():
    size = f"{rtsp_reader.frame_width}x{rtsp_reader.frame_height}"
    return {"frame_size": size, "fps": round(rtsp_reader.fps, 2)}
