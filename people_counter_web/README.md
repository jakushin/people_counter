# People Counter Web Application

Веб-приложение для подсчета людей в видео потоке с использованием YOLOv8 и ROI (Region of Interest).

## 🚀 Возможности

- **Детекция людей** с помощью YOLOv8m
- **ROI (Region of Interest)** - анализ только выбранной области
- **Мультипроцессинг** для ускорения обработки
- **Адаптивный imgsz** - автоматическая подстройка размера входа под ROI
- **Поддержка камер** - подключение к RTSP камерам (Axis)
- **Поддержка видео** - загрузка и анализ MP4 файлов
- **Веб-интерфейс** - удобное управление через браузер

## 📋 Требования

- Docker и Docker Compose
- MP4 видео файлы (для тестирования)

## 🛠 Установка и запуск

1. **Клонируйте репозиторий:**
```bash
git clone <repository-url>
cd people_counter_web
```

2. **Запустите приложение:**
```bash
docker-compose up --build
```

3. **Откройте браузер:**
```
http://localhost:8080
```

## 🎯 Использование

### Подключение к камере

1. Выберите "Камера (RTSP)"
2. Введите параметры камеры:
   - **Пользователь** - имя пользователя
   - **Пароль** - пароль
   - **Host** - IP адрес камеры
3. Нажмите "Старт"

### Работа с видео файлами

1. **Выберите "Видео файл"**
2. **Загрузите видео:**
   - Нажмите "Выберите файл" и выберите MP4
   - Нажмите "Загрузить"
3. **Запустите анализ:**
   - Выберите видео из списка
   - Нажмите "Запустить видео"
   - Нажмите "Старт"

### Настройка ROI

1. **Нарисуйте область интереса:**
   - Кликните на изображение для добавления точек
   - Перетаскивайте точки для изменения формы
   - Добавьте точки между существующими (клик на линии)
2. **Сбросить ROI:** нажмите "Сбросить ROI"

## 📊 Мониторинг

В правом верхнем углу отображается:
- **Статус** подключения
- **FPS** - кадров в секунду
- **Размер** кадра
- **CPU** и **MEM** - загрузка системы
- **Crop** - размер ROI (ширина × высота)
- **imgsz** - размер входа для YOLO

## 🔧 Технические детали

### Архитектура

- **Backend** (Python/FastAPI) - обработка видео и детекция
- **Frontend** (HTML/JS) - веб-интерфейс
- **YOLOv8m** - модель детекции объектов
- **FFmpeg** - конвертация видео в RTSP поток

### Оптимизации

- **Мультипроцессинг** - 4 worker процесса
- **ROI кроп** - анализ только нужной области
- **Адаптивный imgsz** - подстройка под размер ROI
- **Фильтрация детекций** - по confidence и размеру bbox

### Форматы видео

- **Вход:** MP4 файлы
- **Обработка:** 1280×960, 10 FPS
- **Выход:** RTSP поток для анализа

## 📁 Структура файлов

```
people_counter_web/
├── backend/
│   ├── app/
│   │   ├── detector.py      # Детекция людей
│   │   ├── main.py          # FastAPI сервер
│   │   └── video_stream.py  # Обработка видео
│   ├── Dockerfile
│   └── requirements.txt
├── frontend/
│   ├── static/
│   │   ├── app.js           # JavaScript логика
│   │   ├── index.html       # Веб-интерфейс
│   │   └── style.css        # Стили
│   └── Dockerfile
├── videos/                  # Папка для видео файлов
├── data/                    # Папка для данных (ROI)
├── docker-compose.yml
└── README.md
```

## 🐛 Устранение неполадок

### Низкий FPS
- Уменьшите ROI область
- Проверьте загрузку CPU
- Убедитесь, что ROI не слишком большой

### Ошибки подключения
- Проверьте параметры камеры
- Убедитесь, что камера доступна по сети
- Проверьте логи в консоли браузера

### Проблемы с видео
- Убедитесь, что файл в формате MP4
- Проверьте размер файла (рекомендуется < 100MB)
- Перезапустите контейнеры при необходимости

## 📝 Логи

Логи доступны в контейнере backend:
```bash
docker-compose logs backend
```

Ключевые события:
- `[YOLO_LOGIC]` - логика выбора imgsz
- `[DETECT]` - детекции объектов
- `[CROP]` - информация о ROI
- `[MP_QUEUE]` - состояние очередей мультипроцессинга 