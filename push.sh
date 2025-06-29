#!/bin/bash

# Скрипт для отправки изменений на GitHub с заменой email
# Использование: ./push.sh

echo "🚀 Отправка изменений на GitHub..."

# Проверяем, что мы в корневой директории git репозитория
if [ ! -d ".git" ]; then
    echo "❌ Ошибка: Необходимо запустить скрипт из корневой директории git репозитория"
    exit 1
fi

# Удаляем старые ссылки
echo "📝 Очистка старых ссылок..."
git update-ref -d refs/original/refs/heads/main 2>/dev/null || true
rm -rf .git/refs/original/ 2>/dev/null || true

# Заменяем email в коммитах
echo "🔄 Замена email в коммитах..."
export FILTER_BRANCH_SQUELCH_WARNING=1
git filter-branch --env-filter '
OLD_EMAIL="dmitriy.yakushin@jetbrains.com"
NEW_EMAIL="test123-asw@mail.ru"
if [ "$GIT_COMMITTER_EMAIL" = "$OLD_EMAIL" ]; then
    export GIT_COMMITTER_EMAIL="$NEW_EMAIL"
fi
if [ "$GIT_AUTHOR_EMAIL" = "$OLD_EMAIL" ]; then
    export GIT_AUTHOR_EMAIL="$NEW_EMAIL"
fi
' --tag-name-filter cat -- --branches --tags

# Проверяем результат filter-branch
if [ $? -ne 0 ]; then
    echo "❌ Ошибка при замене email в коммитах"
    exit 1
fi

# Отправляем на GitHub с принудительной отправкой
echo "📤 Отправка на GitHub..."
git push --force-with-lease

# Проверяем результат push
if [ $? -eq 0 ]; then
    echo "✅ Готово! Изменения отправлены на GitHub."
else
    echo "⚠️  Push не удался. Возможные причины:"
    echo "   - Email privacy restrictions на GitHub"
    echo "   - Нет прав на push в репозиторий"
    echo "   - Конфликт с удаленными изменениями"
    echo ""
    echo "💡 Попробуйте:"
    echo "   1. Настроить email privacy на https://github.com/settings/emails"
    echo "   2. Или использовать: git push --force (осторожно!)"
fi 