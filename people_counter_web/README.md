# People Detector (Axis RTSP, YOLO, WebSocket)

## Запуск

1. Клонируйте репозиторий и перейдите в папку проекта.
2. Соберите и запустите контейнеры:

```bash
docker-compose up --build
```

3. Откройте браузер и перейдите на http://localhost:8080
4. Введите параметры камеры (user, password, host) и нажмите "Старт".

## Параметры
- **user** — имя пользователя камеры
- **password** — пароль
- **host** — IP-адрес камеры (без rtsp:// и порта)

## Логирование
- Все ошибки backend пишутся в backend/app.log

## Технологии
- Backend: FastAPI, WebSocket, OpenCV, YOLOv8 (ultralytics)
- Frontend: HTML5, Canvas, WebSocket
- Docker, docker-compose

## TODO
- Интерактивное выделение области (ROI)
- Рисование линии для подсчёта входов/выходов
- События пересечения линии 