# Enhanced Auto-Reconnection System

## Overview
Система автоматического переподключения WebRTC была существенно улучшена для решения проблем с быстрыми переподключениями iPhone к UxPlay.

## Key Features

### 1. Window ID Tracking
- **Проблема**: Система отслеживала только наличие окна, но не его конкретный ID
- **Решение**: Добавлено отслеживание конкретного ID окна iPhone
- **Результат**: Система теперь детектирует переподключения даже когда новое окно создается сразу после исчезновения старого

### 2. Multiple Auto-Reconnection Triggers

#### Trigger 1: Classic Window Disappearance/Appearance
- iPhone полностью отключается от UxPlay
- Окно исчезает, затем появляется снова
- Обрабатывается функциями `handleWindowDisappeared()` и `handleWindowAppeared()`

#### Trigger 2: Window ID Change Detection  
- iPhone быстро переподключается к UxPlay
- Старое окно исчезает и сразу создается новое с другим ID
- Обрабатывается функцией `handleWindowIDChanged()`

#### Trigger 3: WebRTC Connection Loss
- WebRTC соединение закрывается, но iPhone остается подключенным к UxPlay
- Срабатывает функция `checkAutoReconnectAfterCleanup()`
- Автоматически пытается восстановить WebRTC соединение

### 3. Enhanced Performance
- **Интервал мониторинга**: Уменьшен с 5 до 3 секунд
- **Подтверждения**: Уменьшены с 2 до 1 проверки для быстрой реакции
- **Cooldown**: Уменьшен с 10 до 5 секунд между попытками

### 4. Improved Logging
- Детальное логирование ID окон
- Отслеживание причин переподключений
- Диагностика состояния системы автопереподключения

## How It Works

### Window State Monitoring
```go
// Enhanced monitoring with window ID tracking
windowCount, windowID := getWindowCountAndID()

// Check for window ID change (iPhone reconnection with new window)
if hasWindowByCount && lastWindowState && lastWindowID != "" && 
   currentWindowID != "" && lastWindowID != currentWindowID {
    handleWindowIDChanged(currentWindowID)
}
```

### Auto-Reconnection Logic
1. **Window Presence Check**: Есть ли окно iPhone?
2. **WebSocket Check**: Активно ли WebSocket соединение с браузером?
3. **Cooldown Check**: Прошло ли достаточно времени с последней попытки?
4. **Session State**: Нужно ли очистить существующую сессию?

### Supported Scenarios

#### Scenario 1: Quick iPhone Reconnection
```
iPhone disconnects → iPhone reconnects (1 second) → Auto-reconnect triggers
Old window: 0xa00002 → New window: 0xe00002 → WebRTC restarts
```

#### Scenario 2: WebRTC Connection Loss
```
WebRTC fails → iPhone still connected → Auto-reconnect triggers
Window exists: 0xe00002 → WebRTC restarts → Video resumes
```

#### Scenario 3: Classic Disconnect/Reconnect
```
iPhone fully disconnects → Window disappears → iPhone reconnects → Auto-reconnect triggers
Window: None → Window: 0xf00002 → WebRTC starts
```

## New Functions

### `getWindowCountAndID() (int, string)`
- Returns both window count and specific window ID
- Replaces simple presence detection with detailed tracking

### `handleWindowIDChanged(newWindowID string)`
- Handles iPhone reconnections with new window IDs
- Cleans up existing sessions before reconnecting

### `checkAutoReconnectAfterCleanup()`
- Triggers auto-reconnection after WebRTC session cleanup
- Ensures continuity when WebRTC fails but iPhone remains connected

## Configuration

### Constants
```go
WINDOW_STATE_CONFIRMATION_CHECKS = 1     // Faster confirmation
AUTO_RECONNECT_COOLDOWN = 5 * time.Second // Quicker retry
```

### Monitor Interval
```go
time.Sleep(3 * time.Second)  // Every 3 seconds instead of 5
```

## Expected User Experience

1. **Start WebRTC** → Video streams
2. **iPhone disconnects** → System detects disconnection
3. **iPhone reconnects** → Auto-reconnection triggers immediately
4. **Video resumes** → No manual intervention required

## Benefits

- ✅ **Zero manual intervention** for iPhone reconnections
- ✅ **Fast response time** (3-5 seconds max)
- ✅ **Handles all reconnection scenarios**
- ✅ **Maintains WebSocket connection** throughout process
- ✅ **Real-time status updates** to browser
- ✅ **Robust error handling** with fallback mechanisms

## Log Examples

### Window ID Change Detection
```
[AUTO-RECONNECT] WINDOW ID CHANGED: 0xa00002 -> 0xe00002 (iPhone reconnected!)
[AUTO-RECONNECT] Starting automatic WebRTC reconnection for window ID change
```

### WebRTC Cleanup Auto-Reconnection
```
[CLEANUP] iPhone still connected (window 0xe00002), attempting auto-reconnection
[CLEANUP] Auto-reconnection successful
```

### Enhanced Monitoring
```
[window-monitor] Total windows found: 1 (ID: 0xe00002)
[AUTO-RECONNECT] Checking window state: hasWindow=true->true, windowID=0xa00002->0xe00002
``` 