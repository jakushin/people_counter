#!/bin/bash
set -e

REQUIRED_PKGS=(docker.io docker-compose-v2 avahi-daemon)
MISSING=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done

if [ ${#MISSING[@]} -ne 0 ]; then
    echo "Installing missing packages: ${MISSING[*]}"
    sudo apt update
    sudo apt install -y "${MISSING[@]}"
    # Если среди установленных есть avahi-daemon — сразу останавливаем и отключаем автозапуск
    if [[ " ${MISSING[*]} " == *"avahi-daemon"* ]]; then
        echo "Disabling and stopping avahi-daemon on host..."
        sudo systemctl stop avahi-daemon || true
        sudo systemctl disable avahi-daemon || true
    fi
fi

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found after install!"
    exit 1
fi
if ! docker compose version &>/dev/null; then
    echo "ERROR: docker compose (v2) not found after install!"
    exit 1
fi
if ! command -v modprobe &>/dev/null; then
    echo "ERROR: modprobe not found! This is required for kernel module management."
    exit 1
fi

if [ ! -e /dev/fb0 ]; then
    echo "ERROR: /dev/fb0 not found! Video capture will not work."
    exit 1
fi
if [ ! -d /dev/snd ]; then
    echo "ERROR: /dev/snd not found! Audio capture will not work."
    exit 1
fi

if ! groups $USER | grep -qw video; then
    echo "ERROR: User $USER is not in 'video' group (required for /dev/fb0). Run: sudo usermod -aG video $USER && log out/in."
    exit 1
fi
if ! groups $USER | grep -qw audio; then
    echo "ERROR: User $USER is not in 'audio' group (required for /dev/snd). Run: sudo usermod -aG audio $USER && log out/in."
    exit 1
fi
if ! groups $USER | grep -qw docker; then
    echo "ERROR: User $USER is not in 'docker' group. Run: sudo usermod -aG docker $USER && log out/in."
    exit 1
fi

echo "Disabling and stopping avahi-daemon.socket and avahi-daemon on host..."
sudo systemctl disable avahi-daemon.socket || true
sudo systemctl stop avahi-daemon.socket || true
sudo systemctl disable avahi-daemon || true
sudo systemctl stop avahi-daemon || true
sleep 2
if pgrep -x avahi-daemon &>/dev/null; then
    echo "Killing avahi-daemon process manually..."
    sudo killall avahi-daemon || true
    sleep 1
fi
if pgrep -x avahi-daemon &>/dev/null; then
    echo "ERROR: avahi-daemon is still running on the host. Please check manually."
    exit 1
fi

# Ensure npm lock file for frontend
if [ -d frontend ]; then
    if [ ! -f frontend/package-lock.json ]; then
        echo "frontend/package-lock.json not found, creating minimal lock file..."
        touch frontend/package-lock.json
        echo "{}" > frontend/package-lock.json
    fi
fi

echo "Cleaning up logs directory..."
if [ ! -d logs ]; then
    echo "Creating logs directory..."
    mkdir -p logs
else
    echo "Logs directory exists, checking contents..."
    if [ "$(ls -A logs/)" ]; then
        echo "Found log files in logs directory:"
        ls -la logs/
        echo "Removing all files from logs directory..."
        rm -f logs/*
        echo "All log files removed."
    else
        echo "Logs directory is already empty."
    fi
fi
echo "Logs directory is ready."

echo "Stopping and cleaning up Docker..."
docker compose down
docker system prune -af
docker volume prune -f

echo "Rebuilding and starting containers..."
docker compose build --no-cache --full
docker compose up -d

echo "Done! If you changed group membership, please log out and log in again." 