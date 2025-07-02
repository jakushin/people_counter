# region_config.py
import json
import os

REGION_CONFIG_FILE = "region_config.json"
# дефолт — ничего не обрезаем (используем полный кадр)
DEFAULT_REGION = None  # или [0,0,960,540] если нужно задавать frame_size

def load_region_config():
    """Возвращает либо [x1,y1,x2,y2], либо None."""
    if os.path.exists(REGION_CONFIG_FILE):
        with open(REGION_CONFIG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            return tuple(data)
    return DEFAULT_REGION

def save_region_config(region: tuple[int,int,int,int]) -> None:
    """Сохраняет прямоугольник в файл."""
    with open(REGION_CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(list(region), f)
    # DEBUG: logging.getLogger(__name__).debug(f"Region saved: {region}")
