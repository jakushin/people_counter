# syntax=docker/dockerfile:1
FROM ubuntu:24.04

# Настройка окружения для неинтерактивной установки
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    avahi-daemon \
    uxplay \
    mc \
    tcpdump \
    htop \
    net-tools \
    avahi-utils \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    gstreamer1.0-tools \
    gstreamer1.0-x \
    gstreamer1.0-alsa \
    gstreamer1.0-pulseaudio \
    gstreamer1.0-vaapi \
    libavcodec-dev \
    libavutil-dev \
    libavformat-dev \
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
    libgles2-mesa-dev \
    libegl1-mesa-dev \
    mesa-utils \
    && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"] 