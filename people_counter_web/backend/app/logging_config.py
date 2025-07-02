"""
Настройки логирования для системы детекции людей
"""

import os
import logging

# Настройка уровней логирования через переменные окружения
DEBUG_MODE = os.environ.get('DEBUG_MODE', 'false').lower() == 'true'
VERBOSE_MODE = os.environ.get('VERBOSE_MODE', 'false').lower() == 'true'
LOG_LEVEL = os.environ.get('LOG_LEVEL', 'INFO').upper()

def debug_log(message):
    """Логировать только в debug режиме"""
    if DEBUG_MODE:
        logging.info(message)

def verbose_log(message):
    """Логировать только в verbose режиме"""
    if VERBOSE_MODE:
        logging.info(message)

def setup_logging():
    """Настройка логирования"""
    # Определяем уровень логирования
    if DEBUG_MODE:
        level = logging.DEBUG
    elif VERBOSE_MODE:
        level = logging.INFO
    else:
        level = getattr(logging, LOG_LEVEL, logging.INFO)
    
    # Настройка форматирования
    formatter = logging.Formatter(
        '%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    
    # Настройка файлового хендлера
    file_handler = logging.FileHandler('app.log')
    file_handler.setFormatter(formatter)
    
    # Настройка консольного хендлера
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    
    # Настройка корневого логгера
    root_logger = logging.getLogger()
    root_logger.setLevel(level)
    root_logger.addHandler(file_handler)
    root_logger.addHandler(console_handler)
    
    # Подавляем логи от сторонних библиотек
    logging.getLogger('ultralytics').setLevel(logging.WARNING)
    logging.getLogger('torch').setLevel(logging.WARNING)
    logging.getLogger('cv2').setLevel(logging.WARNING)
    logging.getLogger('PIL').setLevel(logging.WARNING)

# Описание уровней логирования:
"""
DEBUG_MODE=true - включает все логи, включая детальную отладочную информацию
VERBOSE_MODE=true - включает расширенные логи, но без детальной отладки
По умолчанию - только важные события и ошибки

Категории логов:
1. [START] - инициализация системы (всегда)
2. [API] - API вызовы (debug/verbose)
3. [WS] - WebSocket события (debug/verbose)
4. [VIDEO_STREAM] - обработка видео (verbose)
5. [DETECT] - детекция объектов (verbose)
6. [MP_*] - мультипроцессинг (verbose)
7. [CROP] - ROI обработка (verbose)
8. [YOLO_*] - YOLO логика (verbose)
9. [MAIN] - основной цикл (verbose)
10. ERROR/WARNING - ошибки и предупреждения (всегда)
""" 