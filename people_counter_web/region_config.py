# region_config.py
import json
import os

REGION_CONFIG_FILE = "region_config.json"

def load_region_config():
    """Возвращает список точек полигона или пустой список."""
    if os.path.exists(REGION_CONFIG_FILE):
        try:
            with open(REGION_CONFIG_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except:
            return []
    return []

def save_region_config(region: list) -> None:
    """Сохраняет полигон в файл."""
    with open(REGION_CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(region, f)