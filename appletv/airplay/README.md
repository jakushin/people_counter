# AirPlay Container (UxPlay + Avahi)

Этот контейнер реализует AirPlay-приёмник на базе UxPlay и Avahi для обнаружения устройств Apple.

## Сборка и запуск

```bash
cd airplay
sudo docker build -t appletv-airplay .
```

Контейнер должен запускаться только через docker-compose, чтобы корректно пробрасывать устройства и volume:

```bash
cd ..
docker-compose up --build airplay
```

## Состав
- UxPlay (https://github.com/FDH2/UxPlay)
- Avahi-daemon
- ffmpeg (для захвата видео/аудио)

## Запуск внутри контейнера

- Автоматически стартует avahi-daemon и UxPlay.
- Для корректной работы требуется проброс /dev/fb0 и /dev/snd, а также volume для хранения записей. 