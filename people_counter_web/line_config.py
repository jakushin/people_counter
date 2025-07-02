# line_config.py
import json
import os

LINE_CONFIG_FILE = "line_config.json"
DEFAULT_START = (400, 350)
DEFAULT_END   = (500, 310)

def load_line_config():
    if os.path.exists(LINE_CONFIG_FILE):
        with open(LINE_CONFIG_FILE, "r", encoding="utf-8") as f:
            a, b = json.load(f)
            return tuple(a), tuple(b)
    return DEFAULT_START, DEFAULT_END

def save_line_config(start, end):
    with open(LINE_CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump([list(start), list(end)], f)
