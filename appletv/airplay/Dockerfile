# syntax=docker/dockerfile:1
FROM ubuntu:24.04

# Настройка окружения для неинтерактивной установки
ENV DEBIAN_FRONTEND=noninteractive

# Установка базовых зависимостей и инструментов для сборки
RUN apt-get update && apt-get install -y \
    # Build tools
    build-essential \
    cmake \
    git \
    pkg-config \
    # UxPlay dependencies
    libssl-dev \
    libplist-dev \
    libavahi-client-dev \
    libavahi-compat-libdnssd-dev \
    # GStreamer development libraries
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    # GStreamer runtime plugins
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
    # System dependencies
    avahi-daemon \
    mc \
    tcpdump \
    htop \
    net-tools \
    avahi-utils \
    tzdata \
    # X11 and display
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

# Устанавливаем timezone Belgrade  
ENV TZ=Europe/Belgrade
RUN ln -snf /usr/share/zoneinfo/Europe/Belgrade /etc/localtime && echo "Europe/Belgrade" > /etc/timezone
RUN dpkg-reconfigure -f noninteractive tzdata

# Скачиваем и компилируем UxPlay из исходного кода
WORKDIR /tmp
RUN git clone https://github.com/FDH2/UxPlay.git && \
    cd UxPlay && \
    echo "=== Building UxPlay from source ===" && \
    git log --oneline -n 5 && \
    echo "=== Latest commit info ===" && \
    mkdir build && \
    cd build && \
    cmake .. && \
    make -j$(nproc) && \
    make install && \
    cd / && \
    rm -rf /tmp/UxPlay

# Проверяем установленную версию
RUN uxplay --version 2>&1 | head -5 || echo "UxPlay installed successfully"

COPY start.sh /start.sh
RUN chmod +x /start.sh
CMD ["/start.sh"] 