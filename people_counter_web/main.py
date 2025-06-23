# main.py
import logging
import os

from fastapi import FastAPI, Form
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from ultralytics import YOLO

from line_config import load_line_config, save_line_config
from rtsp_reader import RTSPReader

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger(__name__)

RTSP_URL = os.getenv("RTSP_URL")
if not RTSP_URL:
    logger.error("RTSP_URL не задан в окружении")
    raise SystemExit(1)

TARGET_WIDTH = 960

app = FastAPI()
app.mount("/static", StaticFiles(directory="static"), name="static")

model = YOLO("yolov8n.pt")
start, end = load_line_config()
reader = RTSPReader(RTSP_URL, start, end, TARGET_WIDTH, model)
reader.start()

@app.get("/", response_class=HTMLResponse)
async def index():
    return HTMLResponse(open("static/index.html", encoding="utf-8").read())

@app.get("/video")
def video_feed():
    return StreamingResponse(
        reader.frame_generator(),
        media_type="multipart/x-mixed-replace; boundary=frame"
    )

@app.get("/get_line")
async def get_line():
    return JSONResponse({
        "line_start": reader.line_start,
        "line_end":   reader.line_end
    })

@app.post("/set_line")
async def set_line(
    x1: int = Form(...), y1: int = Form(...),
    x2: int = Form(...), y2: int = Form(...)
):
    reader.line_start = (x1, y1)
    reader.line_end   = (x2, y2)
    save_line_config(reader.line_start, reader.line_end)
    return {"status": "ok"}

@app.get("/get_status")
async def get_status():
    return JSONResponse({
        "fps":       round(reader.fps,  2),
        "resolution": f"{reader.frame_width}×{reader.frame_height}",
        "bitrate":   round(reader.bitrate,  1),  # в kbps
        "coords":    f"{reader.line_start} → {reader.line_end}"
    })

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000)
