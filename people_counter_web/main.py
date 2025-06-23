import os
import logging
from fastapi import FastAPI, Form
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from ultralytics import YOLO
from rtsp_reader import RTSPReader
from line_config import load_line_config, save_line_config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# CONFIG
TARGET_WIDTH = 960
RTSP_URL = os.getenv("RTSP_URL", "rtsp://view:123qweASD@172.25.109.148:554/axis-media/media.amp?streamprofile=stream1")

# Load line config
line_start, line_end = load_line_config()

# Load YOLO model
model = YOLO('yolov8n.pt')
logger.info("YOLOv8 model loaded successfully")

# Init RTSP reader
rtsp_reader = RTSPReader(RTSP_URL, line_start, line_end, TARGET_WIDTH, model)

# FastAPI app
app = FastAPI()
app.mount("/static", StaticFiles(directory="static"), name="static")

@app.on_event("startup")
async def startup_event():
    logger.info("Application startup")
    rtsp_reader.start()

@app.on_event("shutdown")
async def shutdown_event():
    logger.info("Application shutdown")
    rtsp_reader.stop()

@app.get("/", response_class=HTMLResponse)
async def index():
    with open("static/index.html") as f:
        html_content = f.read()
    return HTMLResponse(content=html_content)

@app.get("/video")
async def video_feed():
    return StreamingResponse(rtsp_reader.frame_generator(), media_type="multipart/x-mixed-replace; boundary=frame")

@app.get("/get_line")
async def get_line():
    return JSONResponse({
        "line_start": rtsp_reader.line_start,
        "line_end": rtsp_reader.line_end,
    })

@app.post("/set_line")
async def set_line(
    x1: int = Form(...),
    y1: int = Form(...),
    x2: int = Form(...),
    y2: int = Form(...)
):
    rtsp_reader.line_start = (x1, y1)
    rtsp_reader.line_end = (x2, y2)
    save_line_config(rtsp_reader.line_start, rtsp_reader.line_end)
    return JSONResponse({"status": "ok"})

@app.get("/get_status")
async def get_status():
    return JSONResponse({
        "frame_size": f"{rtsp_reader.frame_width}x{rtsp_reader.frame_height}",
        "fps": round(rtsp_reader.fps, 2),
    })
