import json
import os
import logging

LINE_CONFIG_FILE = "line_config.json"

def load_line_config():
    if os.path.exists(LINE_CONFIG_FILE):
        with open(LINE_CONFIG_FILE, "r") as f:
            data = json.load(f)
            return tuple(data[0]), tuple(data[1])
    else:
        # Дефолт
        return (400, 350), (500, 310)

def save_line_config(line_start, line_end):
    with open(LINE_CONFIG_FILE, "w") as f:
        json.dump([list(line_start), list(line_end)], f)
    logging.info(f"Saved line config: {line_start} - {line_end}")
