import json
import os

LINE_CONFIG_FILE = "line_config.json"
DEFAULT_START = (400, 350)
DEFAULT_END   = (500, 310)

def load_line_config() -> tuple[tuple[int,int], tuple[int,int]]:
    """Загрузить координаты линии из файла или вернуть дефолт."""
    if os.path.exists(LINE_CONFIG_FILE):
        with open(LINE_CONFIG_FILE, "r") as f:
            data = json.load(f)
            return tuple(data[0]), tuple(data[1])
    return DEFAULT_START, DEFAULT_END

def save_line_config(line_start: tuple[int,int], line_end: tuple[int,int]) -> None:
    """Сохранить координаты линии (логируется только в DEBUG)."""
    with open(LINE_CONFIG_FILE, "w") as f:
        json.dump([list(line_start), list(line_end)], f)
    # Для отладки:
    # import logging; logging.getLogger(__name__).debug(f"Line config saved: {line_start} → {line_end}")
