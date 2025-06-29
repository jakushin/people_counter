#!/bin/bash

# Скрипт для автоматического обновления и пересборки на сервере
# Использование: ./build.sh

echo "🚀 Начинаем обновление и пересборку..."

# Проверяем, что мы в директории с docker-compose.yml
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Ошибка: Необходимо запустить скрипт из директории с docker-compose.yml"
    exit 1
fi

# Находим git репозиторий (может быть в родительских директориях)
GIT_ROOT=""
CURRENT_DIR=$(pwd)

while [ "$CURRENT_DIR" != "/" ]; do
    if [ -d "$CURRENT_DIR/.git" ]; then
        GIT_ROOT="$CURRENT_DIR"
        break
    fi
    CURRENT_DIR=$(dirname "$CURRENT_DIR")
done

if [ -z "$GIT_ROOT" ]; then
    echo "❌ Ошибка: Не найден git репозиторий в текущей или родительских директориях"
    exit 1
fi

echo "📁 Найден git репозиторий в: $GIT_ROOT"

# 1. Получаем последние изменения из git
echo "📥 Получение последних изменений из git..."
cd "$GIT_ROOT"
git pull

if [ $? -ne 0 ]; then
    echo "❌ Ошибка при получении изменений из git"
    exit 1
fi

echo "✅ Изменения получены успешно"

# Возвращаемся в директорию с docker-compose.yml
cd - > /dev/null

# 2. Останавливаем и удаляем все контейнеры, образы и volumes
echo "🛑 Остановка и очистка Docker..."
docker compose down --rmi all --volumes

if [ $? -ne 0 ]; then
    echo "⚠️  Предупреждение: Не удалось полностью очистить Docker (возможно, контейнеры уже остановлены)"
fi

echo "✅ Docker очищен"

# 3. Пересобираем и запускаем контейнеры
echo "🔨 Пересборка и запуск контейнеров..."
docker compose up --build

if [ $? -eq 0 ]; then
    echo "✅ Готово! Приложение успешно обновлено и запущено"
    echo ""
    echo "📊 Статус контейнеров:"
    docker compose ps
else
    echo "❌ Ошибка при пересборке и запуске контейнеров"
    exit 1
fi 