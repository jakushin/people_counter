# region_config.py
import json
import os

REGION_CONFIG_FILE = "region_config.json"
DEFAULT_REGION = (100,100,200,200)  # если нет файла, рисуем 100×100 сбоку

def load_region_config():
    if os.path.exists(REGION_CONFIG_FILE):
        with open(REGION_CONFIG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            return tuple(data)
    return DEFAULT_REGION

def save_region_config(region):
    with open(REGION_CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(list(region), f)
