# syntax=docker/dockerfile:1
FROM ubuntu:24.04

# Настройка окружения для неинтерактивной установки
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    avahi-daemon \
    uxplay \
    xvfb \
    alsa-utils \
    unclutter \
    openbox \
    x11-utils \
    x11-xserver-utils \
    xauth \
    xserver-xorg-core \
    xserver-xorg-video-dummy \
    libx11-6 \
    libxext6 \
    libxrender1 \
    libxtst6 \
    libxrandr2 \
    libxss1 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    dbus-x11 \
    pulseaudio \
    libnss3 \
    libgl1-mesa-dri \
    mesa-utils \
    && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"] 