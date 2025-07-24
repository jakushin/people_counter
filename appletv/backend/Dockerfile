# syntax=docker/dockerfile:1
FROM golang:1.22-alpine AS builder

# Устанавливаем ca-certificates для HTTPS
RUN apk update && apk --no-cache add ca-certificates git

WORKDIR /app

# Копируем go mod файлы
COPY go.mod ./

# Устанавливаем переменные окружения для Go proxy  
ENV GOPROXY=direct
ENV GOSUMDB=off

# Очищаем модульный кэш и инициализируем модуль
RUN go clean -modcache
RUN go mod tidy
RUN go mod download
RUN go mod verify

# Копируем исходный код
COPY . .

# Собираем приложение с отключенной проверкой модулей
RUN CGO_ENABLED=0 GOOS=linux go build -mod=mod -a -installsuffix cgo -o main .

# Финальный образ
FROM alpine:3.19

# Обновляем индексы пакетов и устанавливаем базовые пакеты
RUN apk update && apk upgrade && \
    apk add --no-cache \
    ca-certificates \
    ffmpeg \
    xwininfo \
    xset \
    xdpyinfo \
    docker-cli \
    && rm -rf /var/cache/apk/*

WORKDIR /root/

COPY --from=builder /app/main .

EXPOSE 8080

CMD ["./main"] 