package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/pion/rtp"
	"github.com/pion/webrtc/v3"
)

// Глобальная система управления WebRTC сессиями
type WebRTCSession struct {
	ID           string
	PeerConn     *webrtc.PeerConnection  
	FFmpegCmd    *exec.Cmd
	VideoConn    *net.UDPConn
	AudioConn    *net.UDPConn
	VideoPort    int
	AudioPort    int
	WebSocket    *websocket.Conn
	Context      context.Context
	CancelFunc   context.CancelFunc
	StartTime    time.Time
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

var (
	lastWindowSize string // Для отслеживания изменений размера окна
	webrtcMutex  sync.Mutex
	airPlayState = &AirPlayState{
		SizeHistory: make([]SizeChangeEvent, 0, 50), // Храним последние 50 изменений
	}
	airPlayStateMutex sync.RWMutex
	startTime time.Time
)

// Debug logging system
type DebugMessage struct {
	Timestamp time.Time `json:"timestamp"`
	Level     string    `json:"level"`
	Category  string    `json:"category"`
	Event     string    `json:"event"`
	Message   string    `json:"message"`
	Details   map[string]interface{} `json:"details,omitempty"`
}

type DebugLogger struct {
	connections map[*websocket.Conn]bool
	mutex       sync.RWMutex
	messages    []DebugMessage
	maxMessages int
}

var (
	debugLogger *DebugLogger
	debugLoggerMutex sync.Mutex
	debugLoggingEnabled bool = false
)

func initDebugLogger() {
	debugLogger = &DebugLogger{
		connections: make(map[*websocket.Conn]bool),
		messages:    make([]DebugMessage, 0),
		maxMessages: 1000, // Keep last 1000 messages for saving
	}
}

func (dl *DebugLogger) AddConnection(conn *websocket.Conn) {
	dl.mutex.Lock()
	defer dl.mutex.Unlock()
	dl.connections[conn] = true
	
	// Send recent messages to new connection
	for _, msg := range dl.messages {
		msgBytes, _ := json.Marshal(msg)
		conn.WriteMessage(websocket.TextMessage, msgBytes)
	}
}

func (dl *DebugLogger) RemoveConnection(conn *websocket.Conn) {
	dl.mutex.Lock()
	defer dl.mutex.Unlock()
	delete(dl.connections, conn)
}

func (dl *DebugLogger) Broadcast(level, category, event, message string, details map[string]interface{}) {
	debugMsg := DebugMessage{
		Timestamp: time.Now(),
		Level:     level,
		Category:  category,
		Event:     event,
		Message:   message,
		Details:   details,
	}
	
	dl.mutex.Lock()
	// Add to history
	dl.messages = append(dl.messages, debugMsg)
	if len(dl.messages) > dl.maxMessages {
		dl.messages = dl.messages[len(dl.messages)-dl.maxMessages:]
	}
	
	// Broadcast to all connected debug clients
	msgBytes, _ := json.Marshal(debugMsg)
	deadConnections := make([]*websocket.Conn, 0)
	
	for conn := range dl.connections {
		if err := conn.WriteMessage(websocket.TextMessage, msgBytes); err != nil {
			deadConnections = append(deadConnections, conn)
		}
	}
	
	// Remove dead connections
	for _, conn := range deadConnections {
		delete(dl.connections, conn)
	}
	dl.mutex.Unlock()
	
	// Also log to console for server-side debugging
	log.Printf("[DEBUG] [%s/%s] %s: %s", category, event, level, message)
}

func (dl *DebugLogger) SaveToFile() error {
	dl.mutex.RLock()
	defer dl.mutex.RUnlock()
	
	filePath := "/var/log/appletv/debug.txt"
	file, err := os.Create(filePath)
	if err != nil {
		return fmt.Errorf("failed to create debug file: %v", err)
	}
	defer file.Close()
	
	file.WriteString(fmt.Sprintf("=== DEBUG LOG SAVED AT %s ===\n\n", time.Now().Format("2006-01-02 15:04:05")))
	
	for _, msg := range dl.messages {
		line := fmt.Sprintf("[%s] [%s] [%s/%s] %s", 
			msg.Timestamp.Format("15:04:05.000"), 
			msg.Level, 
			msg.Category, 
			msg.Event, 
			msg.Message)
		
		if msg.Details != nil && len(msg.Details) > 0 {
			detailsJson, _ := json.Marshal(msg.Details)
			line += fmt.Sprintf(" | Details: %s", string(detailsJson))
		}
		
		file.WriteString(line + "\n")
	}
	
	return nil
}

// Convenience functions for debug logging
func debugLog(level, category, event, message string, details ...map[string]interface{}) {
	if debugLogger == nil || !debugLoggingEnabled {
		return
	}
	var det map[string]interface{}
	if len(details) > 0 {
		det = details[0]
	}
	debugLogger.Broadcast(level, category, event, message, det)
}

func debugInfo(category, event, message string, details ...map[string]interface{}) {
	debugLog("INFO", category, event, message, details...)
}

func debugWarning(category, event, message string, details ...map[string]interface{}) {
	debugLog("WARNING", category, event, message, details...)
}

func debugError(category, event, message string, details ...map[string]interface{}) {
	debugLog("ERROR", category, event, message, details...)
}

func debugSuccess(category, event, message string, details ...map[string]interface{}) {
	debugLog("SUCCESS", category, event, message, details...)
}

// Global variables for session management and auto-reconnection
var (
	activeSession   *WebRTCSession
	sessionMutex    sync.Mutex
	globalLastWindowID string // Global window ID across all sessions
	preservedWebSocket *websocket.Conn // WebSocket сохраненный для auto-reconnection
	
	// WebSocket write synchronization
	websocketWriteMutex sync.Mutex
	
	// Auto-reconnection state
	lastWindowState          bool = false
	lastWindowID             string = "" // NEW: Track specific window ID
	windowStateCheckCount    int = 0
	activeWebSocketConn      *websocket.Conn = nil
	autoReconnectEnabled     bool = true
	lastAutoReconnectAttempt time.Time = time.Time{}
	
	// NEW: Track reconnection readiness when WebSocket is closed
	phoneReconnectedAndReady bool = false
	reconnectedWindowID      string = ""
)

// Constants for auto-reconnection
const (
	WINDOW_STATE_CONFIRMATION_CHECKS = 5  // Increased stability against false window detection
	AUTO_RECONNECT_COOLDOWN = 5 * time.Second  // Reduced cooldown for quicker reconnections
)

// Thread-safe WebSocket write wrapper to prevent concurrent write panics
func safeWriteWebSocket(conn *websocket.Conn, message []byte) error {
	websocketWriteMutex.Lock()
	defer websocketWriteMutex.Unlock()
	return conn.WriteMessage(websocket.TextMessage, message)
}

func findFreePort() (int, error) {
	for i := 0; i < 100; i++ {
		port := 5000 + rand.Intn(1000)
		addr, err := net.ResolveUDPAddr("udp", fmt.Sprintf(":%d", port))
		if err != nil {
			continue
		}
		conn, err := net.ListenUDP("udp", addr)
		if err != nil {
			continue
		}
		conn.Close()
		return port, nil
	}
	return 0, fmt.Errorf("no free ports found")
}

// Умное ожидание UxPlay окна с уведомлениями клиента
// Simplified version for auto-reconnect without WebSocket notifications
func waitForUxPlayWindowSimple(timeout time.Duration) (*AirPlayWindow, error) {
	log.Printf("[INFO] WebRTC: Waiting for UxPlay window (timeout: %v)", timeout)
	
	startTime := time.Now()
	
	for {
		if time.Since(startTime) > timeout {
			return nil, fmt.Errorf("timeout: UxPlay window not found within %v", timeout)
		}
		
		// ИСПРАВЛЕНО: Используем findWindow() вместо getUxPlayWindows()
		windowID, width, height, err := findWindow()
		if err == nil && windowID != "" && width >= 100 && height >= 100 {
			log.Printf("[SUCCESS] WebRTC: Found UxPlay window after %v - ID: %s, Size: %dx%d", 
				time.Since(startTime), windowID, width, height)
			return &AirPlayWindow{
				ID:     windowID,
				Name:   "UxPlay Window",
				Width:  width,
				Height: height,
				X:      0,
				Y:      0,
			}, nil
		}
		
		time.Sleep(1 * time.Second)
	}
}

func waitForUxPlayWindow(conn *websocket.Conn, timeout time.Duration) (string, int, int, error) {
	start := time.Now()
	checkInterval := 2 * time.Second
	lastNotification := time.Time{}
	
	log.Printf("[INFO] WebRTC: Waiting for UxPlay window (timeout: %.0fs)", timeout.Seconds())
	
	// Отправляем начальный статус клиенту
	safeWriteWebSocket(conn, []byte(`{"type":"status","message":"Waiting for AirPlay connection..."}`))
	
	for time.Since(start) < timeout {
		// Проверяем окно
		windowID, width, height, err := findWindow()
		if err == nil && windowID != "" && width >= 100 && height >= 100 {
			log.Printf("[SUCCESS] WebRTC: Found UxPlay window after %.1fs - ID: %s, Size: %dx%d", 
				time.Since(start).Seconds(), windowID, width, height)
			
			// Уведомляем клиента об успехе
			safeWriteWebSocket(conn, []byte(`{"type":"status","message":"AirPlay window found, starting WebRTC..."}`))
			return windowID, width, height, nil
		}
		
		
		// Периодически уведомляем клиента о состоянии ожидания
		if time.Since(lastNotification) >= 5*time.Second {
			elapsed := time.Since(start).Seconds()
			remaining := timeout.Seconds() - elapsed
			message := fmt.Sprintf("Still waiting for AirPlay connection... (%.0fs remaining)", remaining)
			
			conn.WriteMessage(websocket.TextMessage, []byte(fmt.Sprintf(`{"type":"status","message":"%s"}`, message)))
			log.Printf("[INFO] WebRTC: Window check %d - no suitable window found (elapsed: %.1fs)", 
				int(elapsed/checkInterval.Seconds())+1, elapsed)
			lastNotification = time.Now()
		}
		
		// Проверяем что WebSocket соединение еще активно
		conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		_, _, err = conn.ReadMessage()
		if err == nil {
			// Получили сообщение - игнорируем, но соединение активно
		} else if !isTimeoutError(err) {
			// Реальная ошибка соединения
			return "", 0, 0, fmt.Errorf("WebSocket connection lost during window wait: %v", err)
		}
		conn.SetReadDeadline(time.Time{}) // Сбрасываем deadline
		
		time.Sleep(checkInterval)
	}
	
	return "", 0, 0, fmt.Errorf("timeout waiting for UxPlay window after %.1fs", timeout.Seconds())
}

// Проверка на timeout ошибку
func isTimeoutError(err error) bool {
	if netErr, ok := err.(net.Error); ok {
		return netErr.Timeout()
	}
	return false
}


// Безопасная очистка WebRTC сессии
func (s *WebRTCSession) Cleanup() {
	if s == nil {
		return
	}
	
	log.Printf("[INFO] WebRTC: Cleaning up session %s (uptime: %.1fs)", s.ID, time.Since(s.StartTime).Seconds())
	
	// 1. Отменить context для всех goroutines
	if s.CancelFunc != nil {
		s.CancelFunc()
	}
	
	// 2. Убить FFmpeg процесс
	if s.FFmpegCmd != nil && s.FFmpegCmd.Process != nil {
		log.Printf("[DEBUG] WebRTC: Terminating FFmpeg process PID %d", s.FFmpegCmd.Process.Pid)
		s.FFmpegCmd.Process.Kill()
		s.FFmpegCmd.Wait() // Ждем завершения процесса
	}
	
	// 3. Закрыть RTP connections
	if s.VideoConn != nil {
		log.Printf("[DEBUG] WebRTC: Closing video RTP connection (port %d)", s.VideoPort)
		s.VideoConn.Close()
	}
	if s.AudioConn != nil {
		log.Printf("[DEBUG] WebRTC: Closing audio RTP connection (port %d)", s.AudioPort)
		s.AudioConn.Close()
	}
	
	// 4. Закрыть PeerConnection
	if s.PeerConn != nil {
		log.Printf("[DEBUG] WebRTC: Closing PeerConnection")
		s.PeerConn.Close()
	}
	
	// 5. Закрыть WebSocket (если не сохранен для auto-reconnection)
	if s.WebSocket != nil {
		if s.WebSocket == preservedWebSocket {
			log.Printf("[DEBUG] WebRTC: WebSocket preserved for auto-reconnection, not closing")
		} else {
			log.Printf("[DEBUG] WebRTC: Closing WebSocket connection")
			s.WebSocket.Close()
		}
	}
	
	log.Printf("[SUCCESS] WebRTC: Session %s cleanup completed", s.ID)
}

// Частичная очистка для auto-reconnection (сохраняет WebSocket)
func (s *WebRTCSession) PartialCleanup() {
	if s == nil {
		return
	}
	
	log.Printf("[INFO] WebRTC: Partial cleanup for auto-reconnection - session %s (uptime: %.1fs)", s.ID, time.Since(s.StartTime).Seconds())
	
	// 1. Отменить context для всех goroutines
	if s.CancelFunc != nil {
		s.CancelFunc()
	}
	
	// 2. Убить FFmpeg процесс
	if s.FFmpegCmd != nil && s.FFmpegCmd.Process != nil {
		log.Printf("[DEBUG] WebRTC: Terminating FFmpeg process PID %d", s.FFmpegCmd.Process.Pid)
		s.FFmpegCmd.Process.Kill()
		s.FFmpegCmd.Wait()
	}
	
	// 3. Закрыть RTP connections
	if s.VideoConn != nil {
		log.Printf("[DEBUG] WebRTC: Closing video RTP connection (port %d)", s.VideoPort)
		s.VideoConn.Close()
	}
	if s.AudioConn != nil {
		log.Printf("[DEBUG] WebRTC: Closing audio RTP connection (port %d)", s.AudioPort)
		s.AudioConn.Close()
	}
	
	// 4. Закрыть PeerConnection
	if s.PeerConn != nil {
		log.Printf("[DEBUG] WebRTC: Closing PeerConnection")
		s.PeerConn.Close()
	}
	
	// 5. НЕ закрываем WebSocket - сохраняем для auto-reconnection!
	log.Printf("[SUCCESS] WebRTC: Partial cleanup completed, WebSocket preserved for auto-reconnection")
}

// Принудительная очистка активной сессии
func cleanupActiveSession() {
	sessionMutex.Lock()
	defer sessionMutex.Unlock()
	
	if activeSession != nil {
		log.Printf("[INFO] WebRTC: Force cleaning up active session before starting new one")
		activeSession.Cleanup()
		activeSession = nil
		
		// ИСПРАВЛЕНО: НЕ отключаем auto-reconnect при очистке сессии
		// Автоматическое переподключение должно оставаться активным
		log.Printf("[DEBUG] WebRTC: Auto-reconnect remains enabled after session cleanup")
	}
}

func findFreePortWithRetry(retries int) (int, error) {
	for i := 0; i < retries; i++ {
		port, err := findFreePort()
		if err == nil {
			return port, nil
		}
		log.Printf("[DEBUG] Failed to find free port, retrying... (Attempt %d/%d)", i+1, retries)
		time.Sleep(1 * time.Second) // Wait a bit before retrying
	}
	return 0, fmt.Errorf("failed to find free port after %d retries", retries)
}

func startFFmpegRTP(windowID string, winW, winH int, videoPort, audioPort int) (*exec.Cmd, error) {
	// Дополнительная диагностика перед запуском
	log.Printf("[DEBUG] WebRTC: Pre-capture diagnostics for window %s", windowID)
	
	// Проверяем что окно еще существует локально
	checkCmd := exec.Command("xwininfo", "-id", windowID)
	checkCmd.Env = append(os.Environ(), "DISPLAY=:0", "XAUTHORITY=/root/.Xauthority")
	checkOut, checkErr := checkCmd.Output()
	if checkErr != nil {
		log.Printf("[ERROR] Window %s no longer exists: %v", windowID, checkErr)
		return nil, fmt.Errorf("target window no longer exists: %v", checkErr)
	}
	
	// Парсим текущие размеры окна
	currentW, currentH := winW, winH
	for _, line := range strings.Split(string(checkOut), "\n") {
		if strings.Contains(line, "Width:") {
			if fields := strings.Fields(line); len(fields) >= 2 {
				if w, err := strconv.Atoi(fields[1]); err == nil {
					currentW = w
				}
			}
		}
		if strings.Contains(line, "Height:") {
			if fields := strings.Fields(line); len(fields) >= 2 {
				if h, err := strconv.Atoi(fields[1]); err == nil {
					currentH = h
				}
			}
		}
	}
	
	log.Printf("[INFO] WebRTC: Window %s current size: %dx%d (expected: %dx%d)", 
		windowID, currentW, currentH, winW, winH)
	
	// Используем текущие размеры
	winW, winH = currentW, currentH
	
	// Проверяем доступные аудио устройства (для диагностики)
	log.Printf("[DEBUG] WebRTC: Checking available audio devices...")
	
	// Проверяем ALSA устройства
	alsaCmd := exec.Command("aplay", "-l")
	alsaOut, alsaErr := alsaCmd.Output()
	if alsaErr == nil {
		log.Printf("[DEBUG] ALSA devices available:\n%s", string(alsaOut))
	} else {
		log.Printf("[DEBUG] ALSA not available: %v", alsaErr)
	}
	
	// Проверяем PulseAudio устройства
	pulseCmd := exec.Command("pactl", "list", "sources")
	pulseOut, pulseErr := pulseCmd.Output()
	if pulseErr == nil {
		log.Printf("[DEBUG] PulseAudio sources available:\n%s", string(pulseOut))
	} else {
		log.Printf("[DEBUG] PulseAudio not available: %v", pulseErr)
	}
	
	log.Printf("[INFO] WebRTC: Starting optimized video capture from AirPlay window")
	debugInfo("FFMPEG", "capture_start", "Starting optimized video capture from AirPlay window", map[string]interface{}{
		"windowID": windowID,
		"width": winW,
		"height": winH,
		"videoPort": videoPort,
		"audioPort": audioPort,
	})
	
	// Оптимизированные параметры FFmpeg для лучшего захвата
	args := []string{
		// Входной поток: захват конкретного окна
		"-f", "x11grab",
		"-draw_mouse", "0",        // Отключаем курсор мыши
		"-window_id", windowID,
		"-video_size", fmt.Sprintf("%dx%d", winW, winH), // Явно указываем размер
		"-framerate", "30",
		"-probesize", "10M",       // Увеличиваем размер пробы
		"-i", ":0",
		
		// Фильтры: масштабирование до четных размеров и улучшение качества
		"-vf", fmt.Sprintf("scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p"),
		
		// Видео кодирование: оптимизировано для WebRTC
		"-c:v", "libx264",
		"-preset", "ultrafast",    // Самая быстрая предустановка
		"-tune", "zerolatency",    // Минимальная задержка
		"-profile:v", "baseline",  // Совместимость с WebRTC
		"-level", "3.1",           // Немного выше для лучшего качества
		"-pix_fmt", "yuv420p",     // Стандартный формат пикселей
		
		// Ключевые кадры и GOP
		"-g", "30",                // GOP размер = framerate
		"-keyint_min", "30",       // Минимальный интервал ключевых кадров
		"-sc_threshold", "0",      // Отключаем автоматическое определение смены сцены
		
		// Битрейт и качество
		"-b:v", "2M",              // Битрейт видео 2 Мбит/с
		"-maxrate", "2.5M",        // Максимальный битрейт
		"-bufsize", "5M",          // Размер буфера
		"-crf", "28",              // Постоянное качество (18-28 хорошо)
		
		// ИСПРАВЛЕНО: RTP выход на хост (backend использует host networking)
		"-f", "rtp",
		"-payload_type", "103",    // H.264 payload type 103 (совместимость с WebRTC)
		fmt.Sprintf("rtp://127.0.0.1:%d", videoPort), // Localhost работает с host networking
	}
	
	// ИСПРАВЛЕНО: Выполняем FFmpeg локально в backend контейнере, где окно найдено
	cmd := exec.Command("ffmpeg", args...)
	cmd.Env = append(os.Environ(), 
		"DISPLAY=:0", 
		"XAUTHORITY=/root/.Xauthority",
		"LIBVA_DRIVER_NAME=i965", // Для аппаратного ускорения (если доступно)
	)
	
	// Перенаправляем stderr для логирования ошибок FFmpeg
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	
	log.Printf("[INFO] WebRTC: Starting FFmpeg with command:")
	log.Printf("[INFO]   ffmpeg %s", strings.Join(args, " "))
	log.Printf("[INFO] WebRTC: Video capture: window %s (%dx%d) -> RTP port %d", 
		windowID, winW, winH, videoPort)
	
	err := cmd.Start()
	if err != nil {
		debugError("FFMPEG", "start_failed", "Failed to start FFmpeg process", map[string]interface{}{
			"error": err.Error(),
			"windowID": windowID,
			"videoPort": videoPort,
		})
		return cmd, err
	}
	
	debugSuccess("FFMPEG", "started", "FFmpeg process started successfully", map[string]interface{}{
		"windowID": windowID,
		"videoPort": videoPort,
		"processID": cmd.Process.Pid,
	})
	
	return cmd, nil
}

// Функция для диагностики DISPLAY окружения
func diagnoseDisplay() {
	log.Printf("=== ДИАГНОСТИКА DISPLAY ===")
	log.Printf("DISPLAY environment variable: %s", os.Getenv("DISPLAY"))
	
	// Проверяем доступность разных дисплеев
	displays := []string{":0", ":1", ":10", ":99"}
	for _, display := range displays {
		cmd := exec.Command("xdpyinfo", "-display", display)
		if err := cmd.Run(); err == nil {
			log.Printf("Display %s is AVAILABLE", display)
		} else {
			log.Printf("Display %s is NOT available: %v", display, err)
		}
	}
	
	// Проверяем X11 сокеты
	if files, err := os.ReadDir("/tmp/.X11-unix"); err == nil {
		log.Printf("X11 sockets found: %d", len(files))
		for _, file := range files {
			log.Printf("  - %s", file.Name())
		}
	} else {
		log.Printf("No X11 sockets found: %v", err)
	}
	
	// Проверяем Xauthority
	if xauth := os.Getenv("XAUTHORITY"); xauth != "" {
		if _, err := os.Stat(xauth); err == nil {
			log.Printf("XAUTHORITY file exists: %s", xauth)
		} else {
			log.Printf("XAUTHORITY file not found: %s", xauth)
		}
	} else {
		log.Printf("XAUTHORITY not set")
	}
}

// Функция для простой проверки X11
func testX11Connection() {
	log.Printf("=== ПРОВЕРКА X11 СОЕДИНЕНИЯ ===")
	
	// Простая проверка доступности X11 дисплея
	cmd := exec.Command("xdpyinfo", "-display", ":0")
	if err := cmd.Run(); err == nil {
		log.Printf("X11 display :0 is accessible")
	} else {
		log.Printf("X11 display :0 is not accessible: %v", err)
	}
}

// Enhanced window monitor for faster auto-reconnection
func startWindowMonitor() {
	go func() {
		for {
				// Enhanced monitoring with window ID tracking
	windowCount, windowID := getWindowCountAndID()
	log.Printf("[window-monitor] Total windows found: %d (ID: %s, Last: %s)", windowCount, windowID, lastWindowID)
			
			// Используем количество окон как индикатор наличия UxPlay
			hasWindow := windowCount > 0
			
			if hasWindow {
				log.Printf("[window-monitor] UxPlay window found: %s", windowID)
			}
			handleWindowStateChange(hasWindow)
			
			// Faster monitoring interval for quicker detection
			time.Sleep(1 * time.Second)
		}
	}()
}

func main() {
	// Инициализируем логирование
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Printf("Starting AppleTV Backend Server...")
	
	// Initialize debug logger
	initDebugLogger()
	debugInfo("SYSTEM", "startup", "AppleTV Backend Server starting up")
	
	// Initialize auto-reconnect state
	log.Printf("[AUTO-RECONNECT] Initializing enhanced auto-reconnect system")
	lastWindowState = false
	lastWindowID = ""
	windowStateCheckCount = 0
	autoReconnectEnabled = true
	log.Printf("[AUTO-RECONNECT] Initial state: lastWindowState=%v, lastWindowID=%s, autoReconnectEnabled=%v", 
		lastWindowState, lastWindowID, autoReconnectEnabled)
	
	// Check if there's already a window present at startup
	initialCount, initialWindowID := getWindowCountAndID()
	if initialCount > 0 && initialWindowID != "" {
		log.Printf("[AUTO-RECONNECT] Window already present at startup: %s", initialWindowID)
		lastWindowID = initialWindowID
		lastWindowState = true
	}
	
	// Выполняем диагностику DISPLAY
	diagnoseDisplay()
	
	// Проверяем X11 соединение
	testX11Connection()
	
	// Запускаем мониторинг окон
	startWindowMonitor()
	
	// Инициализация времени запуска
	startTime = time.Now()
	
	// Инициализация рандома для выбора портов
	rand.Seed(time.Now().UnixNano())
	
	// Проверяем доступность каталога для записи
	recordDir := "/var/airplay-records"
	if _, err := os.Stat(recordDir); os.IsNotExist(err) {
		log.Printf("Creating record directory: %s", recordDir)
		if err := os.MkdirAll(recordDir, 0755); err != nil {
			log.Printf("Failed to create record directory: %v", err)
		}
	}
	
	// Проверяем доступность каталога для логов
	logDir := "/var/log/appletv"
	if _, err := os.Stat(logDir); os.IsNotExist(err) {
		log.Printf("Creating log directory: %s", logDir)
		if err := os.MkdirAll(logDir, 0755); err != nil {
			log.Printf("Failed to create log directory: %v", err)
		}
	}

	// Запускаем мониторинг состояния AirPlay
	go checkAirPlayStatus()
	
	r := gin.Default()
	
	// Add CORS middleware
	r.Use(func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Origin, Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization")
		
		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		
		c.Next()
	})
	
	// Добавляем middleware для логирования всех запросов
	r.Use(gin.LoggerWithFormatter(func(param gin.LogFormatterParams) string {
		return fmt.Sprintf("[GIN] %v | %3d | %13v | %15s | %-7s %s\n",
			param.TimeStamp.Format("2006/01/02 - 15:04:05"),
			param.StatusCode,
			param.Latency,
			param.ClientIP,
			param.Method,
			param.Path,
		)
	}))

	r.GET("/api/health", func(c *gin.Context) {
		c.JSON(200, gin.H{"status": "ok"})
	})

	r.POST("/api/record/start", func(c *gin.Context) {
		var req StartRecordRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request"})
			return
		}
		err := StartRecording(req.Filename)
		if err != nil {
			if err.Error() == "Recording already in progress" {
				c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			} else {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to start recording"})
			}
			return
		}
		resp := StartRecordResponse{
			Status:    "recording",
			File:      req.Filename,
			StartedAt: time.Now().UTC(),
		}
		c.JSON(http.StatusOK, resp)
	})

	r.POST("/api/record/stop", func(c *gin.Context) {
		file, dur, err := StopRecording()
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		resp := StopRecordResponse{
			Status:   "stopped",
			File:     file,
			Duration: dur,
		}
		c.JSON(http.StatusOK, resp)
	})

	r.GET("/api/records", func(c *gin.Context) {
		files, err := ListRecordFiles()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to list records"})
			return
		}
		c.JSON(http.StatusOK, files)
	})

	r.GET("/api/records/:filename", func(c *gin.Context) {
		filename := c.Param("filename")
		if filename == "" || len(filename) > 128 || filepath.Ext(filename) != ".mp4" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid filename"})
			return
		}
		fullPath := filepath.Join(recordsDir, filename)
		c.FileAttachment(fullPath, filename)
	})

	r.DELETE("/api/records/:filename", func(c *gin.Context) {
		filename := c.Param("filename")
		if filename == "" || len(filename) > 128 || filepath.Ext(filename) != ".mp4" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid filename"})
			return
		}
		fullPath := filepath.Join(recordsDir, filename)
		err := os.Remove(fullPath)
		if err != nil {
			if os.IsNotExist(err) {
				c.JSON(http.StatusNotFound, gin.H{"error": "File not found"})
			} else {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to delete file"})
			}
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "deleted", "file": filename})
	})

	r.GET("/api/record/status", func(c *gin.Context) {
		recordingMu.Lock()
		defer recordingMu.Unlock()
		if recordingCmd != nil {
			c.JSON(http.StatusOK, gin.H{
				"recording": true,
				"file": recordingFile,
				"startedAt": recordingStart.UTC(),
			})
		} else {
			c.JSON(http.StatusOK, gin.H{"recording": false})
		}
	})



	r.GET("/api/webrtc/status", func(c *gin.Context) {
		sessionMutex.Lock()
		defer sessionMutex.Unlock()
		
		status := gin.H{
			"active": activeSession != nil,
			"hasSession": activeSession != nil,
		}
		
		if activeSession != nil {
			status["sessionID"] = activeSession.ID
			status["uptime"] = time.Since(activeSession.StartTime).Seconds()
			status["videoPort"] = activeSession.VideoPort
			status["audioPort"] = activeSession.AudioPort
			status["hasFFmpeg"] = activeSession.FFmpegCmd != nil
			status["hasVideoConn"] = activeSession.VideoConn != nil
			status["hasAudioConn"] = activeSession.AudioConn != nil
			
			if activeSession.PeerConn != nil {
				status["connectionState"] = activeSession.PeerConn.ConnectionState().String()
				status["iceConnectionState"] = activeSession.PeerConn.ICEConnectionState().String()
			}
		}
		
		c.JSON(http.StatusOK, status)
	})

	r.POST("/api/webrtc/cleanup", func(c *gin.Context) {
		log.Printf("[INFO] Manual WebRTC cleanup requested")
		cleanupActiveSession()
		
		c.JSON(http.StatusOK, gin.H{
			"status": "cleaned",
			"message": "WebRTC session cleaned up successfully",
		})
	})

	r.GET("/api/airplay/status", gin.WrapH(http.HandlerFunc(airplayStatusHandler)))
	r.GET("/api/airplay/diagnostics", gin.WrapH(http.HandlerFunc(airplayDiagnosticsHandler)))
	r.GET("/api/airplay/logs", gin.WrapH(http.HandlerFunc(airplayLogsHandler)))

	// Debug API endpoints
	r.GET("/api/debug/stream", gin.WrapH(http.HandlerFunc(debugStreamHandler)))
	r.POST("/api/debug/save", gin.WrapH(http.HandlerFunc(debugSaveHandler)))
	r.POST("/api/debug/start", gin.WrapH(http.HandlerFunc(debugStartHandler)))
	r.POST("/api/debug/stop", gin.WrapH(http.HandlerFunc(debugStopHandler)))











	// WebRTC handlers
	r.GET("/api/webrtc/signal", gin.WrapH(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("[INFO] === WebRTC REQUEST RECEIVED === From: %s, Method: %s, URL: %s", r.RemoteAddr, r.Method, r.URL.Path)
		log.Printf("[DEBUG] WebRTC Headers: Upgrade=%s, Connection=%s", r.Header.Get("Upgrade"), r.Header.Get("Connection"))
		
		webrtcMutex.Lock()
		defer webrtcMutex.Unlock()

			sessionMutex.Lock()
	hasActiveSession := activeSession != nil
	if !hasActiveSession {
		// Reserve session slot immediately to prevent race conditions
		activeSession = &WebRTCSession{
			ID: "reserved_" + fmt.Sprintf("%d", time.Now().Unix()),
		}
		log.Printf("[DEBUG] Session slot reserved, starting WebRTC setup")
	}
	sessionMutex.Unlock()
	
	if hasActiveSession {
		log.Printf("[WARNING] WebRTC session already active, rejecting new connection")
		http.Error(w, "WebRTC session already active", http.StatusConflict)
		return
	}

	log.Printf("[DEBUG] === WebRTC Signaling Started ===")
		
		// Умное ожидание UxPlay окна для переподключений

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("[ERROR] WebSocket upgrade failed: %v", err)
			return
		}
		defer conn.Close()
		
		// Store WebSocket connection reference for auto-reconnection
		activeWebSocketConn = conn
		defer func() {
			// Clear WebSocket reference when connection closes
			activeWebSocketConn = nil
			// ИСПРАВЛЕНО: НЕ отключаем auto-reconnect при закрытии WebSocket
			// Автоматическое переподключение должно работать независимо от WebSocket
			log.Printf("[DEBUG] WebRTC: WebSocket closed, but auto-reconnect remains enabled")
			debugInfo("WEBSOCKET", "connection_closed", "WebSocket closed, but auto-reconnect remains enabled")
		}()
		
		log.Printf("[INFO] WebSocket connection established")
		debugSuccess("WEBSOCKET", "connection_established", "WebSocket connection established for WebRTC signaling", map[string]interface{}{
			"remoteAddr": r.RemoteAddr,
		})
		
		logger := &logWriter{level: "info", event: "webrtc_signaling_open"}
		json.NewEncoder(logger).Encode(map[string]interface{}{"timestamp": time.Now().Format(time.RFC3339)})
		
		// Force immediate window state check when WebSocket connects
		// This catches cases where iPhone reconnected between monitoring intervals
		windowCount, currentWindowID := getWindowCountAndID()
		if windowCount > 0 && currentWindowID != "" {
			log.Printf("[AUTO-RECONNECT] Force checking window state on WebSocket connect: found window %s", currentWindowID)
			
			// Always initialize state properly
			if !lastWindowState {
				lastWindowState = true
				lastWindowID = currentWindowID
				windowStateCheckCount = 0
				
				// Only set reconnection readiness flags if NOT in startup period
				if time.Since(startTime) >= 30*time.Second {
					log.Printf("[AUTO-RECONNECT] Detected missed iPhone reconnection, updating state")
					phoneReconnectedAndReady = true
					reconnectedWindowID = currentWindowID
					log.Printf("[AUTO-RECONNECT] Set reconnection readiness for window %s", currentWindowID)
				} else {
					log.Printf("[AUTO-RECONNECT] Window found during startup period (uptime: %.1fs) - initializing state but no reconnection", time.Since(startTime).Seconds())
				}
			}
		}

		// WebRTC configuration для host network режима (без STUN серверов) - moved up to avoid goto issues
		config := webrtc.Configuration{
			ICEServers:         []webrtc.ICEServer{}, // В host режиме STUN серверы не нужны
			ICETransportPolicy: webrtc.ICETransportPolicyAll, // Разрешаем все типы транспорта
		}
		
		// Создаем MediaEngine и регистрируем кодеки
		mediaEngine := &webrtc.MediaEngine{}
		if err := mediaEngine.RegisterDefaultCodecs(); err != nil {
			log.Printf("[ERROR] Failed to register default codecs: %v", err)
			conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","message":"Failed to register codecs"}`))
			return
		}
		
		// Регистрируем H.264 кодек на payload type 103 для совместимости с FFmpeg
		if err := mediaEngine.RegisterCodec(webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:    webrtc.MimeTypeH264,
				ClockRate:   90000,
				Channels:    0,
				SDPFmtpLine: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f",
			},
			PayloadType: 103,
		}, webrtc.RTPCodecTypeVideo); err != nil {
			log.Printf("[ERROR] Failed to register H.264 codec: %v", err)
			conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","message":"Failed to register H.264 codec"}`))
			return
		}
		log.Printf("[DEBUG] WebRTC: Registered H.264 codec on payload type 103")
		
		// Создаем SettingEngine для host network настроек
		settingEngine := webrtc.SettingEngine{}
		
		// Настройки для лучшей работы в host network режиме
		settingEngine.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6})
		
		// Принудительно используем только WiFi интерфейс, исключаем Docker bridge
		settingEngine.SetInterfaceFilter(func(interfaceName string) bool {
			// Разрешаем только WiFi/Ethernet интерфейсы, исключаем Docker
			return interfaceName != "docker0" && interfaceName != "br-" && !strings.HasPrefix(interfaceName, "veth")
		})
		
		log.Printf("[DEBUG] WebRTC: Configured SettingEngine for host network mode")
		
		// Настройка только для host candidates (без срефлексивных)
		settingEngine.SetNAT1To1IPs([]string{"192.168.1.115"}, webrtc.ICECandidateTypeHost)
		
		// Создаем API с нашими настройками
		api := webrtc.NewAPI(webrtc.WithMediaEngine(mediaEngine), webrtc.WithSettingEngine(settingEngine))
		
		log.Printf("[DEBUG] WebRTC: Creating PeerConnection for host network mode")
		peerConnection, err := api.NewPeerConnection(config)
		if err != nil {
			log.Printf("[ERROR] Failed to create PeerConnection: %v", err)
			// Clear reserved session on error
			sessionMutex.Lock()
			activeSession = nil
			sessionMutex.Unlock()
			conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","message":"Failed to create peer connection"}`))
			return
		}
		
		log.Printf("[INFO] WebRTC: PeerConnection created successfully")
		
		// Создаем новую WebRTC сессию (moved up to avoid goto issues)
		sessionCtx, sessionCancel := context.WithCancel(context.Background())
		sessionID := fmt.Sprintf("session_%d", time.Now().Unix())
		
		sessionMutex.Lock()
		// Replace the reserved session with the real session
		activeSession.ID = sessionID
		activeSession.PeerConn = peerConnection
		activeSession.WebSocket = conn
		activeSession.Context = sessionCtx
		activeSession.CancelFunc = sessionCancel
		activeSession.StartTime = time.Now()
		sessionMutex.Unlock()
		
		// Enable auto-reconnection for this session
		autoReconnectEnabled = true
		
		log.Printf("[INFO] WebRTC: Created session %s", sessionID)
		
		// Обеспечиваем cleanup при завершении функции
			defer func() {
		sessionMutex.Lock()
		if activeSession != nil && activeSession.ID == sessionID {
			activeSession.Cleanup()
			activeSession = nil
		}
		sessionMutex.Unlock()
	}()

		// ICE connection state monitoring с подробным логированием
		peerConnection.OnICEConnectionStateChange(func(connectionState webrtc.ICEConnectionState) {
			log.Printf("[INFO] WebRTC: ICE Connection State changed to: %s", connectionState.String())
			
			details := map[string]interface{}{
				"state": connectionState.String(),
				"sessionID": sessionID,
			}
			
			switch connectionState {
			case webrtc.ICEConnectionStateNew:
				log.Printf("[DEBUG] WebRTC: ICE connection is new, waiting for candidates")
				debugInfo("WEBRTC", "ice_state_new", "ICE connection is new, waiting for candidates", details)
			case webrtc.ICEConnectionStateChecking:
				log.Printf("[DEBUG] WebRTC: ICE connection is checking connectivity")
				debugInfo("WEBRTC", "ice_state_checking", "ICE connection is checking connectivity", details)
			case webrtc.ICEConnectionStateConnected:
				log.Printf("[SUCCESS] WebRTC: ICE connection established successfully!")
				debugSuccess("WEBRTC", "ice_state_connected", "ICE connection established successfully!", details)
			case webrtc.ICEConnectionStateCompleted:
				log.Printf("[SUCCESS] WebRTC: ICE connection completed successfully!")
				debugSuccess("WEBRTC", "ice_state_completed", "ICE connection completed successfully!", details)
			case webrtc.ICEConnectionStateFailed:
				log.Printf("[ERROR] WebRTC: ICE connection failed - no connectivity established")
				debugError("WEBRTC", "ice_state_failed", "ICE connection failed - no connectivity established", details)
				cleanupWebRTCSession()
			case webrtc.ICEConnectionStateDisconnected:
				log.Printf("[WARNING] WebRTC: ICE connection disconnected")
				debugWarning("WEBRTC", "ice_state_disconnected", "ICE connection disconnected", details)
				cleanupWebRTCSession()
			case webrtc.ICEConnectionStateClosed:
				log.Printf("[INFO] WebRTC: ICE connection closed")
				debugInfo("WEBRTC", "ice_state_closed", "ICE connection closed", details)
				cleanupWebRTCSession()
			}
		})

		// Connection state monitoring  
		peerConnection.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
			log.Printf("[INFO] WebRTC: Connection State changed to: %s", state.String())
			
			iceState := peerConnection.ICEConnectionState()
			details := map[string]interface{}{
				"connectionState": state.String(),
				"iceState": iceState.String(),
				"sessionID": sessionID,
			}
			
			// Детальное логирование для диагностики
			if state == webrtc.PeerConnectionStateConnected {
				log.Printf("[SUCCESS] WebRTC: PeerConnection is now CONNECTED - media should be flowing")
				log.Printf("[SUCCESS] WebRTC: ICE Connection State: %s", iceState.String())
				debugSuccess("WEBRTC", "connection_established", "PeerConnection is now CONNECTED - media should be flowing", details)
			} else if state == webrtc.PeerConnectionStateFailed {
				log.Printf("[ERROR] WebRTC: PeerConnection FAILED - connection lost")
				log.Printf("[ERROR] WebRTC: ICE Connection State at failure: %s", iceState.String())
				debugError("WEBRTC", "connection_failed", "PeerConnection FAILED - connection lost", details)
			} else if state == webrtc.PeerConnectionStateClosed {
				log.Printf("[INFO] WebRTC: PeerConnection CLOSED")
				debugInfo("WEBRTC", "connection_closed", "PeerConnection CLOSED", details)
			} else if state == webrtc.PeerConnectionStateDisconnected {
				log.Printf("[WARNING] WebRTC: PeerConnection DISCONNECTED - may recover")
				debugWarning("WEBRTC", "connection_disconnected", "PeerConnection DISCONNECTED - may recover", details)
			} else if state == webrtc.PeerConnectionStateConnecting {
				debugInfo("WEBRTC", "connection_connecting", "PeerConnection is connecting", details)
			} else if state == webrtc.PeerConnectionStateNew {
				debugInfo("WEBRTC", "connection_new", "PeerConnection created", details)
			}
			
			if state == webrtc.PeerConnectionStateFailed || state == webrtc.PeerConnectionStateClosed {
				log.Printf("[WARNING] WebRTC: Connection failed/closed, cleaning up session")
				debugWarning("WEBRTC", "connection_cleanup", "Connection failed/closed, cleaning up session", details)
				cleanupWebRTCSession()
			}
		})

		// DTLS state monitoring (критично для диагностики)
		peerConnection.OnDataChannel(func(dc *webrtc.DataChannel) {
			log.Printf("[DEBUG] WebRTC: DataChannel opened: %s", dc.Label())
		})
		
		// Monitoring connection gathering state
		peerConnection.OnICEGatheringStateChange(func(state webrtc.ICEGathererState) {
			log.Printf("[DEBUG] WebRTC: ICE Gathering State changed to: %s", state.String())
		})
		
		// ICE candidate handling
		peerConnection.OnICECandidate(func(candidate *webrtc.ICECandidate) {
			if candidate == nil {
				log.Printf("[DEBUG] WebRTC: ICE gathering completed (nil candidate)")
				debugInfo("WEBRTC", "ice_gathering_complete", "ICE gathering completed (nil candidate received)")
				return
			}
			log.Printf("[DEBUG] WebRTC: Generated ICE candidate: %s", candidate.String())
			log.Printf("[DEBUG] WebRTC: ICE candidate details - Type: %s, Protocol: %s, Address: %s, Port: %d", 
				candidate.Typ.String(), candidate.Protocol.String(), candidate.Address, candidate.Port)
			
			debugInfo("WEBRTC", "ice_candidate_generated", "Generated ICE candidate", map[string]interface{}{
				"type": candidate.Typ.String(),
				"protocol": candidate.Protocol.String(),
				"address": candidate.Address,
				"port": candidate.Port,
				"priority": candidate.Priority,
				"sessionID": sessionID,
			})
			
			candidateMsg, _ := json.Marshal(map[string]interface{}{
				"type": "ice-candidate",
				"candidate": candidate.ToJSON(),
			})
			if err := safeWriteWebSocket(conn, candidateMsg); err != nil {
				log.Printf("[ERROR] Failed to send ICE candidate: %v", err)
				debugError("WEBRTC", "ice_candidate_send_failed", "Failed to send ICE candidate to client", map[string]interface{}{
					"error": err.Error(),
					"candidateType": candidate.Typ.String(),
				})
			} else {
				debugSuccess("WEBRTC", "ice_candidate_sent", "ICE candidate sent to client", map[string]interface{}{
					"candidateType": candidate.Typ.String(),
				})
			}
		})
		
		// Check if iPhone is ready for reconnection
		if phoneReconnectedAndReady && reconnectedWindowID != "" {
			// Check if WebRTC session is already active (has tracks)
			if len(peerConnection.GetSenders()) > 0 {
				log.Printf("[AUTO-RECONNECT] WebRTC session already active with %d tracks - no reconnection needed", len(peerConnection.GetSenders()))
				// Clear the flags without reconnection
				phoneReconnectedAndReady = false
				reconnectedWindowID = ""
			} else {
				log.Printf("[AUTO-RECONNECT] iPhone ready for reconnection detected, sending reconnection_ready notification")
				notifyWebSocketClient(map[string]interface{}{
					"type": "reconnection_ready",
					"message": "iPhone reconnected - auto-reconnecting in 5 seconds",
					"windowID": reconnectedWindowID,
				})
				
				log.Printf("[AUTO-RECONNECT] Notification sent, waiting for SDP offer to initialize WebRTC session")
				
				// Clear the flags after using them
				phoneReconnectedAndReady = false
				reconnectedWindowID = ""
				
				// Do NOT initialize WebRTC session here - wait for SDP offer
				// Jump to message loop without initializing WebRTC
				goto messageLoop
			}
		} else {
			// Ожидание UxPlay окна с уведомлениями клиента (только если iPhone не готов)
			var windowID string
			var width, height int
			var err error
			windowID, width, height, err = waitForUxPlayWindow(conn, 60*time.Second)
					if err != nil {
			log.Printf("[ERROR] WebRTC: Failed to find UxPlay window within timeout: %v", err)
			// Clear reserved session on error
			sessionMutex.Lock()
			activeSession = nil
			sessionMutex.Unlock()
			conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","message":"AirPlay window not available - please connect your device"}`))
			return
		}
			
			log.Printf("[INFO] WebRTC: Window validation passed - ID: %s, Size: %dx%d", windowID, width, height)
			log.Printf("[INFO] WebRTC: Waiting for SDP offer to initialize WebRTC session")
		}

		log.Printf("[INFO] WebRTC: PeerConnection ready, waiting for signaling messages")

	messageLoop:
		// WebSocket message handling loop - keep connection open after WebRTC handshake
	for {
		_, message, err := conn.ReadMessage()
		if err != nil {
			// Don't close WebSocket on normal read timeout - just log and continue monitoring  
			if websocket.IsCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("[INFO] WebSocket closed normally by client")
				break
			} else {
				log.Printf("[DEBUG] WebSocket read error (keeping connection alive): %v", err)
				// Keep WebSocket alive after WebRTC handshake - don't break the loop
				time.Sleep(5 * time.Second)
				continue
			}
		}
			
			log.Printf("[DEBUG] WebRTC: Received signaling message: %s", string(message))

			var msg map[string]interface{}
			if err := json.Unmarshal(message, &msg); err != nil {
				log.Printf("[ERROR] Failed to parse signaling message: %v", err)
				continue
			}

			switch msg["type"] {
			case "offer":
				log.Printf("[DEBUG] WebRTC: Processing SDP offer")
				debugInfo("WEBRTC", "sdp_offer_received", "Processing SDP offer from client")
				
				sdpStr, ok := msg["sdp"].(string)
				if !ok {
					log.Printf("[ERROR] Invalid SDP in offer")
					debugError("WEBRTC", "sdp_offer_invalid", "Invalid SDP in offer - not a string")
					continue
				}
				
				offer := webrtc.SessionDescription{
					Type: webrtc.SDPTypeOffer,
					SDP:  sdpStr,
				}
				
				if err := peerConnection.SetRemoteDescription(offer); err != nil {
					log.Printf("[ERROR] Failed to set remote description: %v", err)
					debugError("WEBRTC", "sdp_offer_set_failed", "Failed to set remote description", map[string]interface{}{
						"error": err.Error(),
					})
					conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","message":"Failed to set remote description"}`))
					continue
				}
				log.Printf("[INFO] WebRTC: Remote description set successfully")
				debugSuccess("WEBRTC", "sdp_offer_set_success", "Remote description set successfully")

				// Check if this is the first SDP offer for this PeerConnection (no tracks yet)
				hasNoTracks := len(peerConnection.GetSenders()) == 0
				log.Printf("[DEBUG] WebRTC: First SDP offer for this PeerConnection: %v (senders count: %d)", hasNoTracks, len(peerConnection.GetSenders()))

				// Initialize WebRTC session (tracks, FFmpeg, RTP forwarding) for first SDP offer
				if hasNoTracks {
					log.Printf("[WebRTC] Initializing WebRTC session for SDP offer")
					
					// Get current UxPlay window
					currentWindow, err := waitForUxPlayWindowSimple(5 * time.Second)
					if err != nil {
						log.Printf("[ERROR] Failed to find UxPlay window: %v", err)
						conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","message":"UxPlay window not available"}`))
						continue
					}
					
					// Initialize WebRTC session with current window
					if err := initializeWebRTCSession(peerConnection, currentWindow.ID, currentWindow.Width, currentWindow.Height, sessionCtx, conn); err != nil {
						log.Printf("[ERROR] Failed to initialize WebRTC session: %v", err)
						conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","message":"Failed to initialize WebRTC session"}`))
						continue
					}
					
					log.Printf("[SUCCESS] WebRTC session initialized successfully")
				}

				answer, err := peerConnection.CreateAnswer(nil)
				if err != nil {
					log.Printf("[ERROR] Failed to create answer: %v", err)
					debugError("WEBRTC", "sdp_answer_create_failed", "Failed to create SDP answer", map[string]interface{}{
						"error": err.Error(),
					})
					conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","message":"Failed to create answer"}`))
					continue
				}
				log.Printf("[INFO] WebRTC: Answer created successfully")
				debugSuccess("WEBRTC", "sdp_answer_created", "SDP answer created successfully")

				if err := peerConnection.SetLocalDescription(answer); err != nil {
					log.Printf("[ERROR] Failed to set local description: %v", err)
					debugError("WEBRTC", "sdp_answer_set_failed", "Failed to set local description", map[string]interface{}{
						"error": err.Error(),
					})
					conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"error","message":"Failed to set local description"}`))
					continue
				}
				log.Printf("[INFO] WebRTC: Local description set successfully")
				debugSuccess("WEBRTC", "sdp_answer_set_success", "Local description set successfully")

				answerMsg, _ := json.Marshal(map[string]interface{}{
					"type": "answer",
					"sdp":  answer.SDP,
				})
				if err := safeWriteWebSocket(conn, answerMsg); err != nil {
					log.Printf("[ERROR] Failed to send answer: %v", err)
					debugError("WEBRTC", "sdp_answer_send_failed", "Failed to send SDP answer to client", map[string]interface{}{
						"error": err.Error(),
					})
				} else {
					log.Printf("[INFO] WebRTC: SDP answer sent to client")
					debugSuccess("WEBRTC", "sdp_answer_sent", "SDP answer sent to client successfully")
				}

			case "ice-candidate":
				log.Printf("[DEBUG] WebRTC: Processing ICE candidate")
				debugInfo("WEBRTC", "ice_candidate_received", "Processing ICE candidate from client")
				
				candidateData, ok := msg["candidate"].(map[string]interface{})
				if !ok {
					log.Printf("[ERROR] Invalid ICE candidate format")
					debugError("WEBRTC", "ice_candidate_invalid_format", "Invalid ICE candidate format from client")
					continue
				}
				
				candidateStr, ok := candidateData["candidate"].(string)
				if !ok {
					log.Printf("[ERROR] Missing candidate string")
					debugError("WEBRTC", "ice_candidate_missing_string", "Missing candidate string in ICE candidate")
					continue
				}
				
				sdpMid, _ := candidateData["sdpMid"].(string)
				sdpMLineIndex, _ := candidateData["sdpMLineIndex"].(float64)
				
				candidate := webrtc.ICECandidateInit{
					Candidate:     candidateStr,
					SDPMid:        &sdpMid,
					SDPMLineIndex: (*uint16)(&[]uint16{uint16(sdpMLineIndex)}[0]),
				}
				
				if err := peerConnection.AddICECandidate(candidate); err != nil {
					log.Printf("[ERROR] Failed to add ICE candidate: %v", err)
					debugError("WEBRTC", "ice_candidate_add_failed", "Failed to add ICE candidate from client", map[string]interface{}{
						"error": err.Error(),
						"candidateString": candidateStr,
						"sdpMid": sdpMid,
					})
				} else {
					log.Printf("[DEBUG] WebRTC: ICE candidate added successfully")
					debugSuccess("WEBRTC", "ice_candidate_added", "ICE candidate added successfully", map[string]interface{}{
						"candidateString": candidateStr,
						"sdpMid": sdpMid,
					})
				}

			default:
				log.Printf("[WARNING] WebRTC: Unknown message type: %v", msg["type"])
			}
		}

			log.Printf("[INFO] WebRTC: Signaling loop ended, cleaning up session")
	cleanupWebRTCSession()
	})))

	r.Run(":8080")
}

// Enhanced window monitoring for auto-reconnection system
func getWindowCountAndID() (int, string) {
	windowID, width, height, err := findWindow()
	// Окно считается найденным только если есть ID и размеры больше 100x100
	if err != nil || windowID == "" || width < 100 || height < 100 {
		return 0, ""
	}
	return 1, windowID // Return both count and specific window ID
}

// Backward compatibility function
func getWindowCount() int {
	count, _ := getWindowCountAndID()
	return count
}

// Глобальная функция для поиска window_id и размера окна с расширенной диагностикой
func findWindow() (string, int, int, error) {
	// Проверяем X11 соединение
	displayCmd := exec.Command("xset", "q")
	displayCmd.Env = append(os.Environ(), "DISPLAY=:0", "XAUTHORITY=/root/.Xauthority")
	displayErr := displayCmd.Run()
	if displayErr != nil {
		log.Printf("[ERROR] X11 connection failed: %v", displayErr)
		return "", 0, 0, displayErr
	}
	
	winInfoCmd := exec.Command("xwininfo", "-root", "-tree")
	winInfoCmd.Env = append(os.Environ(), "DISPLAY=:0", "XAUTHORITY=/root/.Xauthority")
	winInfoOut, err := winInfoCmd.Output()
	if err != nil {
		log.Printf("[ERROR] xwininfo failed: %v", err)
		return "", 0, 0, err
	}
	
	// Подсчитываем общее количество окон для диагностики
	allWindows := strings.Split(string(winInfoOut), "\n")
	windowCount := 0
	openglWindows := 0
	potentialVideoWindows := []map[string]interface{}{}
	
	for _, line := range allWindows {
		if strings.Contains(line, "0x") && strings.Contains(line, "x") {
			windowCount++
			// Парсим размеры окон
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				id := fields[0]
				var w, h int
				for _, f := range fields {
					if strings.Contains(f, "x") && strings.Contains(f, "+") {
						size := strings.Split(f, "x")
						if len(size) > 1 {
							w, _ = strconv.Atoi(size[0])
							rest := strings.Split(size[1], "+")
							if len(rest) > 0 {
								h, _ = strconv.Atoi(rest[0])
							}
						}
					}
				}
				
				// Ищем окна с видео-пропорциями
				if w > 100 && h > 100 {
					aspectRatio := float64(w) / float64(h)
					// Проверяем видео пропорции: 16:9, 4:3, или вертикальные
					isVideoAspect := (aspectRatio >= 1.7 && aspectRatio <= 1.8) || // 16:9
						(aspectRatio >= 1.3 && aspectRatio <= 1.4) || // 4:3  
						(aspectRatio >= 0.45 && aspectRatio <= 0.6) // вертикальное видео (9:16)
					
					if isVideoAspect {
						potentialVideoWindows = append(potentialVideoWindows, map[string]interface{}{
							"id":     id,
							"width":  w,
							"height": h,
							"aspect": aspectRatio,
							"line":   strings.TrimSpace(line),
						})
					}
				}
			}
		}
		if strings.Contains(line, "OpenGL") || strings.Contains(line, "renderer") {
			openglWindows++
			log.Printf("[DEBUG] OpenGL-related window: %s", strings.TrimSpace(line))
		}
	}
	
	log.Printf("[DEBUG] Total windows: %d, OpenGL-related: %d, Potential video windows: %d", 
		windowCount, openglWindows, len(potentialVideoWindows))
	
	// Логируем все потенциальные видео окна
	for i, win := range potentialVideoWindows {
		log.Printf("[DEBUG] Video window %d: ID=%s, Size=%dx%d, Aspect=%.2f", 
			i+1, win["id"], win["width"], win["height"], win["aspect"])
	}
	
	// Приоритет 1: Ищем окна с именем UxPlay или AppleTV-Backend
	log.Printf("[DEBUG] Priority 1: Searching for UxPlay/AppleTV/AirPlay window names...")
	debugInfo("AIRPLAY", "window_search_priority1", "Searching for UxPlay/AppleTV/AirPlay window names")
	
	for _, line := range strings.Split(string(winInfoOut), "\n") {
		if strings.Contains(strings.ToLower(line), "uxplay") || 
		   strings.Contains(strings.ToLower(line), "appletv") ||
		   strings.Contains(strings.ToLower(line), "airplay") {
			fields := strings.Fields(line)
			if len(fields) < 2 {
				continue
			}
			id := fields[0]
			var w, h int
			for _, f := range fields {
				if strings.Contains(f, "x") && strings.Contains(f, "+") {
					size := strings.Split(f, "x")
					if len(size) > 1 {
						w, _ = strconv.Atoi(size[0])
						rest := strings.Split(size[1], "+")
						if len(rest) > 0 {
							h, _ = strconv.Atoi(rest[0])
						}
					}
				}
			}
			log.Printf("[INFO] Found UxPlay/AirPlay window: id=%s size=%dx%d", id, w, h)
			
			// Дополнительная диагностика окна
			getWindowInfo(id)
			
			if w > 100 && h > 100 { // Проверяем минимальный размер
				debugSuccess("AIRPLAY", "window_found_priority1", "Found UxPlay/AirPlay window by name", map[string]interface{}{
					"windowID": id,
					"width": w,
					"height": h,
					"priority": "name_match",
				})
				return id, w, h, nil
			}
		}
	}
	
	// Приоритет 2: Ищем окна с размером iPhone (обычно вертикальные ~9:16)
	log.Printf("[DEBUG] Priority 2: Checking %d potential video windows for iPhone-like aspect...", len(potentialVideoWindows))
	for _, win := range potentialVideoWindows {
		w := win["width"].(int)
		h := win["height"].(int)
		aspect := win["aspect"].(float64)
		id := win["id"].(string)
		
		// iPhone обычно передает вертикальное видео с пропорциями близко к 9:16 (0.5625)
		log.Printf("[DEBUG] Priority 2: Checking window %s: %dx%d aspect=%.3f (need: aspect=[0.45,0.6], size>=[400,700])", id, w, h, aspect)
		if aspect >= 0.45 && aspect <= 0.6 && w >= 400 && h >= 700 {
			log.Printf("[SUCCESS] Priority 2: Found iPhone-like window: id=%s size=%dx%d aspect=%.2f", id, w, h, aspect)
			getWindowInfo(id)
			return id, w, h, nil
		} else {
			log.Printf("[DEBUG] Priority 2: Window %s rejected: aspect_ok=%v, size_ok=%v", id, (aspect >= 0.45 && aspect <= 0.6), (w >= 400 && h >= 700))
		}
	}
	
	// Приоритет 3: Ищем по OpenGL renderer
	log.Printf("[DEBUG] Priority 3: Searching for OpenGL renderer windows...")
	for _, line := range strings.Split(string(winInfoOut), "\n") {
		if strings.Contains(line, "OpenGL renderer") {
			fields := strings.Fields(line)
			if len(fields) < 2 {
				continue
			}
			id := fields[0]
			var w, h int
			for _, f := range fields {
				if strings.Contains(f, "x") && strings.Contains(f, "+") {
					size := strings.Split(f, "x")
					if len(size) > 1 {
						w, _ = strconv.Atoi(size[0])
						rest := strings.Split(size[1], "+")
						if len(rest) > 0 {
							h, _ = strconv.Atoi(rest[0])
						}
					}
				}
			}
			log.Printf("[INFO] Found OpenGL renderer window: id=%s size=%dx%d", id, w, h)
			
			// Дополнительная диагностика окна
			getWindowInfo(id)
			
			return id, w, h, nil
		}
	}
	
	// Приоритет 4: Берем самое большое видео окно
	log.Printf("[DEBUG] Priority 4: Selecting largest from %d potential video windows...", len(potentialVideoWindows))
	if len(potentialVideoWindows) > 0 {
		// Сортируем по площади (самое большое первым)
		largestWin := potentialVideoWindows[0]
		maxArea := largestWin["width"].(int) * largestWin["height"].(int)
		
		for _, win := range potentialVideoWindows[1:] {
			area := win["width"].(int) * win["height"].(int)
			if area > maxArea {
				largestWin = win
				maxArea = area
			}
		}
		
		id := largestWin["id"].(string)
		w := largestWin["width"].(int)
		h := largestWin["height"].(int)
		
		log.Printf("[SUCCESS] Priority 4: Using largest video window: id=%s size=%dx%d area=%d", id, w, h, maxArea)
		getWindowInfo(id)
		return id, w, h, nil
	}
	
	// Приоритет 5: Любое окно с разумными размерами (fallback)
	log.Printf("[DEBUG] Priority 5: Fallback search for any window >100x100...")
	for _, line := range strings.Split(string(winInfoOut), "\n") {
		if strings.Contains(line, "0x") && strings.Contains(line, "x") {
			fields := strings.Fields(line)
			if len(fields) < 2 {
				continue
			}
			id := fields[0]
			var w, h int
			for _, f := range fields {
				if strings.Contains(f, "x") && strings.Contains(f, "+") {
					size := strings.Split(f, "x")
					if len(size) > 1 {
						w, _ = strconv.Atoi(size[0])
						rest := strings.Split(size[1], "+")
						if len(rest) > 0 {
							h, _ = strconv.Atoi(rest[0])
						}
					}
				}
			}
			
			// Ищем окна с размерами больше чем 100x100
			if w > 100 && h > 100 {
				log.Printf("[INFO] Found fallback window: id=%s size=%dx%d", id, w, h)
				getWindowInfo(id)
				return id, w, h, nil
			}
		}
	}
	
	log.Printf("[ERROR] All priorities failed! No suitable UxPlay window found in %d total windows (potentialVideos: %d)", windowCount, len(potentialVideoWindows))
	debugError("AIRPLAY", "window_not_found", "All priorities failed! No suitable UxPlay window found", map[string]interface{}{
		"totalWindows": windowCount,
		"potentialVideoWindows": len(potentialVideoWindows),
	})
	return "", 0, 0, nil
}

// Дополнительная диагностика конкретного окна
func getWindowInfo(windowId string) {
	if windowId == "" {
		return
	}
	
	// Получаем подробную информацию об окне локально
	winCmd := exec.Command("xwininfo", "-id", windowId)
	winCmd.Env = append(os.Environ(), "DISPLAY=:0", "XAUTHORITY=/root/.Xauthority")
	winOut, winErr := winCmd.Output()
	if winErr != nil {
		log.Printf("[DEBUG] Error getting window info for %s: %v", windowId, winErr)
		return
	}
	
	// Выводим информацию о найденном окне
	log.Printf("[DEBUG] Window %s details:", windowId)
	for _, line := range strings.Split(string(winOut), "\n") {
		if strings.Contains(line, "Width:") || strings.Contains(line, "Height:") || 
		   strings.Contains(line, "Class:") || strings.Contains(line, "Instance:") ||
		   strings.Contains(line, "Window id:") || strings.Contains(line, "Absolute") {
			log.Printf("[DEBUG]   %s", strings.TrimSpace(line))
		}
	}
	
	// Также проверяем имя окна локально
	nameCmd := exec.Command("xwininfo", "-id", windowId, "-name")
	nameCmd.Env = append(os.Environ(), "DISPLAY=:0", "XAUTHORITY=/root/.Xauthority")
	nameOut, nameErr := nameCmd.Output()
	if nameErr == nil {
		log.Printf("[DEBUG] Window %s name: %s", windowId, strings.TrimSpace(string(nameOut)))
	}
	
	if winErr == nil {
		lines := strings.Split(string(winOut), "\n")
		for _, line := range lines {
			if strings.Contains(line, "Width:") || strings.Contains(line, "Height:") || 
			   strings.Contains(line, "Class:") || strings.Contains(line, "Visual") {
				log.Printf("[DEBUG] Window %s: %s", windowId, strings.TrimSpace(line))
			}
		}
	}
}



// Вспомогательная функция для проверки существования файла
func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
} 

// Helper for logging WebRTC events
type logWriter struct {
	level string
	event string
}

func (lw *logWriter) Write(p []byte) (int, error) {
	log.Printf("[DEBUG] WebRTC: %s - %s", lw.level, lw.event)
	return len(p), nil
}

func cleanupWebRTCSession() {
	// Enhanced cleanup with auto-reconnection support
	sessionMutex.Lock()
	defer sessionMutex.Unlock()
	
	if activeSession != nil {
		log.Printf("[CLEANUP] Cleaning up WebRTC session: %s", activeSession.ID)
		activeSession.Cleanup()
		activeSession = nil
		
		// Check if we should auto-reconnect after WebRTC cleanup
		checkAutoReconnectAfterCleanup()
	}
}

// Check for auto-reconnection after WebRTC session cleanup
func checkAutoReconnectAfterCleanup() {
	// Only attempt auto-reconnection if:
	// 1. Auto-reconnect is enabled
	// 2. We have an active WebSocket connection
	// 3. iPhone is still connected to UxPlay (window exists)
	// 4. Cooldown period has passed
	
	if !autoReconnectEnabled || activeWebSocketConn == nil {
		log.Printf("[CLEANUP] Auto-reconnect not enabled or no WebSocket connection")
		return
	}
	
	if time.Since(lastAutoReconnectAttempt) < AUTO_RECONNECT_COOLDOWN {
		log.Printf("[CLEANUP] Auto-reconnect cooldown active, skipping")
		return
	}
	
	// Check if iPhone window still exists
	windowCount, windowID := getWindowCountAndID()
	if windowCount == 0 || windowID == "" {
		log.Printf("[CLEANUP] No iPhone window found, no reconnection needed")
		return
	}
	
	log.Printf("[CLEANUP] iPhone still connected (window %s), system ready for new connection", windowID)
	lastAutoReconnectAttempt = time.Now()
	
	// Update tracked window ID  
	lastWindowID = windowID
	lastWindowState = true
	
	// Notify client that they need to reconnect
	notifyWebSocketClient(map[string]interface{}{
		"type": "reconnection_ready", 
		"message": "iPhone still connected - please restart WebRTC",
		"windowID": windowID,
	})
	
	log.Printf("[CLEANUP] System ready for new WebRTC connection")
} 

type AirPlayState struct {
	Connected       bool      `json:"connected"`
	WindowSize      string    `json:"window_size"`
	LastUpdate      time.Time `json:"last_update"`
	ConnectionStart time.Time `json:"connection_start,omitempty"`
	StreamingActive bool      `json:"streaming_active"`
	LastSizeChange  time.Time `json:"last_size_change,omitempty"`
	SizeHistory     []SizeChangeEvent `json:"size_history"`
}

type SizeChangeEvent struct {
	Timestamp  time.Time `json:"timestamp"`
	OldSize    string    `json:"old_size"`
	NewSize    string    `json:"new_size"`
	Reason     string    `json:"reason"`
	Connected  bool      `json:"connected"`
}

func updateAirPlayState(newSize string, reason string) {
	airPlayStateMutex.Lock()
	defer airPlayStateMutex.Unlock()
	
	oldSize := airPlayState.WindowSize
	now := time.Now()
	
	// Проверяем, изменился ли размер
	if oldSize != newSize {
		// Логируем изменение размера
		log.Printf("🔄 [AIRPLAY STATE] Window size changed: %s -> %s (reason: %s, connected: %v)", 
			oldSize, newSize, reason, airPlayState.Connected)
		
		// Добавляем в историю
		event := SizeChangeEvent{
			Timestamp: now,
			OldSize:   oldSize,
			NewSize:   newSize,
			Reason:    reason,
			Connected: airPlayState.Connected,
		}
		
		airPlayState.SizeHistory = append(airPlayState.SizeHistory, event)
		
		// Оставляем только последние 50 записей
		if len(airPlayState.SizeHistory) > 50 {
			airPlayState.SizeHistory = airPlayState.SizeHistory[len(airPlayState.SizeHistory)-50:]
		}
		
		airPlayState.LastSizeChange = now
		
		// Специальная диагностика для проблемного случая
		if airPlayState.Connected && newSize == "1x1" && oldSize != "" && oldSize != "1x1" {
			log.Printf("⚠️  [CRITICAL] Connected AirPlay window reverted to 1x1! Previous: %s, Connected since: %v", 
				oldSize, now.Sub(airPlayState.ConnectionStart))
		}
		
		if airPlayState.Connected && oldSize == "1x1" && newSize != "1x1" {
			log.Printf("✅ [SUCCESS] AirPlay window expanded from 1x1 to %s after connection (delay: %v)", 
				newSize, now.Sub(airPlayState.ConnectionStart))
		}
	}
	
	airPlayState.WindowSize = newSize
	airPlayState.LastUpdate = now
	
	// Проверяем активность стриминга
	oldStreaming := airPlayState.StreamingActive
	airPlayState.StreamingActive = (newSize != "" && newSize != "1x1")
	
	if oldStreaming != airPlayState.StreamingActive {
		log.Printf("📺 [STREAMING] State changed: %v -> %v (window: %s)", 
			oldStreaming, airPlayState.StreamingActive, newSize)
	}
}

func setAirPlayConnection(connected bool, reason string) {
	airPlayStateMutex.Lock()
	defer airPlayStateMutex.Unlock()
	
	oldConnected := airPlayState.Connected
	now := time.Now()
	
	if oldConnected != connected {
		log.Printf("🔌 [CONNECTION] AirPlay connection changed: %v -> %v (reason: %s, current window: %s)", 
			oldConnected, connected, reason, airPlayState.WindowSize)
		
		airPlayState.Connected = connected
		
		if connected {
			airPlayState.ConnectionStart = now
			log.Printf("📱 [CONNECT START] AirPlay connected at %s with window size: %s", 
				now.Format("15:04:05.000"), airPlayState.WindowSize)
				
			// Запускаем мониторинг состояния после подключения
			go monitorPostConnectionState(now)
		} else {
			if !airPlayState.ConnectionStart.IsZero() {
				duration := now.Sub(airPlayState.ConnectionStart)
				log.Printf("📱 [DISCONNECT] AirPlay disconnected after %v, final window: %s", 
					duration, airPlayState.WindowSize)
			}
			airPlayState.ConnectionStart = time.Time{}
		}
	}
}

func monitorPostConnectionState(connectTime time.Time) {
	// Мониторим первые 30 секунд после подключения
	for i := 0; i < 30; i++ {
		time.Sleep(1 * time.Second)
		
		airPlayStateMutex.RLock()
		if !airPlayState.Connected {
			airPlayStateMutex.RUnlock()
			return // Соединение разорвано
		}
		
		elapsed := time.Since(connectTime)
		windowSize := airPlayState.WindowSize
		streaming := airPlayState.StreamingActive
		airPlayStateMutex.RUnlock()
		
		// Логируем состояние каждые 5 секунд или при важных моментах
		if i%5 == 0 || (i < 10 && windowSize == "1x1") {
			log.Printf("⏱️  [POST-CONNECT] T+%ds: window=%s, streaming=%v", 
				int(elapsed.Seconds()), windowSize, streaming)
		}
		
		// Критическое предупреждение если окно не изменилось через 10 секунд
		if i == 10 && windowSize == "1x1" {
			log.Printf("🚨 [ALERT] AirPlay connected for 10s but window still 1x1! This is the target issue!")
		}
		
		// Остановка мониторинга если стрим начался
		if streaming && windowSize != "1x1" {
			log.Printf("✅ [POST-CONNECT] Stream started successfully after %ds (window: %s)", 
				int(elapsed.Seconds()), windowSize)
			return
		}
	}
	
	// Финальная проверка через 30 секунд
	airPlayStateMutex.RLock()
	finalWindow := airPlayState.WindowSize
	finalStreaming := airPlayState.StreamingActive
	stillConnected := airPlayState.Connected
	airPlayStateMutex.RUnlock()
	
	if stillConnected {
		log.Printf("📊 [POST-CONNECT FINAL] After 30s: connected=%v, window=%s, streaming=%v", 
			stillConnected, finalWindow, finalStreaming)
			
		if finalWindow == "1x1" {
			log.Printf("🚨 [ISSUE DETECTED] AirPlay stayed connected for 30s but window remained 1x1!")
		}
	}
}

func checkAirPlayStatus() {
	for {
		// ИСПРАВЛЕНО: Используем findWindow() для диагностики
		windowID, width, height, err := findWindow()
		
		if err != nil || windowID == "" {
			// Нет окон UxPlay
			updateAirPlayState("", "no_windows")
			setAirPlayConnection(false, "no_windows")
		} else {
			// Есть окно UxPlay
			windowSizeStr := fmt.Sprintf("%dx%d", width, height)
			
			updateAirPlayState(windowSizeStr, "window_detected")
			
			// Определяем статус подключения
			setAirPlayConnection(true, "window_exists")
			
			log.Printf("🔍 [WINDOWS] Found UxPlay window: %s (%s)", windowID, windowSizeStr)
		}
		
		time.Sleep(1 * time.Second)
	}
}

func airplayStatusHandler(w http.ResponseWriter, r *http.Request) {
	airPlayStateMutex.RLock()
	defer airPlayStateMutex.RUnlock()
	
	// Добавляем дополнительную диагностическую информацию
	response := map[string]interface{}{
		"state": airPlayState,
		"diagnostics": map[string]interface{}{
			"uptime_seconds": time.Since(startTime).Seconds(),
			"windows_count": getWindowCount(),
			"last_check": time.Now(),
		},
	}
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

// Новый эндпоинт для детальной диагностики
func airplayDiagnosticsHandler(w http.ResponseWriter, r *http.Request) {
	// ИСПРАВЛЕНО: Используем findWindow() для диагностики
	var windowInfo interface{}
	windowID, width, height, err := findWindow()
	if err != nil {
		windowInfo = nil
	} else {
		windowInfo = map[string]interface{}{
			"id": windowID,
			"width": width,
			"height": height,
		}
	}
	
	airPlayStateMutex.RLock()
	state := *airPlayState // копия
	airPlayStateMutex.RUnlock()
	
	processes := getUxPlayProcesses()
	
	diagnostics := map[string]interface{}{
		"timestamp": time.Now(),
		"current_state": state,
		"live_window": windowInfo,
		"processes": processes,
		"system_info": map[string]interface{}{
			"uptime": time.Since(startTime),
			"goroutines": runtime.NumGoroutine(),
		},
	}
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(diagnostics)
}

// Новый эндпоинт для получения логов UxPlay
func airplayLogsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	
	// Читаем логи UxPlay
	uxplayLogs, err := readUxPlayLogs()
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to read UxPlay logs: %v", err), http.StatusInternalServerError)
		return
	}
	
	// Дополнительная диагностика Docker контейнеров
	dockerInfo := getDockerInfo()
	
	response := map[string]interface{}{
		"timestamp": time.Now(),
		"logs": uxplayLogs,
		"logs_file": "/var/log/appletv/uxplay.log",
		"docker_info": dockerInfo,
	}
	
	json.NewEncoder(w).Encode(response)
}

// Debug API handlers
func debugStreamHandler(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("Failed to upgrade debug WebSocket: %v", err)
		return
	}
	defer conn.Close()
	
	debugInfo("DEBUG", "websocket_connect", "Debug WebSocket client connected")
	
	// Add connection to debug logger
	debugLogger.AddConnection(conn)
	defer debugLogger.RemoveConnection(conn)
	
	// Keep connection alive
	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			debugInfo("DEBUG", "websocket_disconnect", "Debug WebSocket client disconnected")
			break
		}
	}
}

func debugSaveHandler(w http.ResponseWriter, r *http.Request) {
	if debugLogger == nil {
		http.Error(w, "Debug logger not initialized", http.StatusInternalServerError)
		return
	}
	
	err := debugLogger.SaveToFile()
	if err != nil {
		debugError("DEBUG", "save_failed", "Failed to save debug log to file", map[string]interface{}{
			"error": err.Error(),
		})
		http.Error(w, fmt.Sprintf("Failed to save debug log: %v", err), http.StatusInternalServerError)
		return
	}
	
	debugSuccess("DEBUG", "save_success", "Debug log saved to /var/log/appletv/debug.txt")
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "success",
		"message": "Debug log saved to debug.txt",
		"file": "/var/log/appletv/debug.txt",
		"timestamp": time.Now(),
	})
}

func debugStartHandler(w http.ResponseWriter, r *http.Request) {
	debugLoggingEnabled = true
	
	// Send initial message
	debugInfo("DEBUG", "logging_started", "Debug logging started by user")
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "success",
		"message": "Debug logging started",
		"enabled": debugLoggingEnabled,
		"timestamp": time.Now(),
	})
}

func debugStopHandler(w http.ResponseWriter, r *http.Request) {
	// Send final message before stopping
	debugInfo("DEBUG", "logging_stopped", "Debug logging stopped by user")
	
	debugLoggingEnabled = false
	
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "success",
		"message": "Debug logging stopped",
		"enabled": debugLoggingEnabled,
		"timestamp": time.Now(),
	})
}

// Функция для получения информации о Docker контейнерах
func getDockerInfo() map[string]interface{} {
	result := map[string]interface{}{
		"containers": []string{},
		"airplay_running": false,
		"error": "",
	}
	
	// Проверяем запущенные контейнеры
	cmd := exec.Command("docker", "ps", "--format", "table {{.Names}}\t{{.Status}}\t{{.Image}}")
	output, err := cmd.Output()
	if err != nil {
		result["error"] = fmt.Sprintf("Failed to get docker info: %v", err)
		return result
	}
	
	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		if strings.Contains(line, "airplay") {
			result["airplay_running"] = true
		}
		if strings.TrimSpace(line) != "" {
			result["containers"] = append(result["containers"].([]string), line)
		}
	}
	
	return result
}

// Функция для чтения логов UxPlay из контейнера
func readUxPlayLogs() ([]string, error) {
	// Читаем логи из shared volume
	logPaths := []string{
		"/var/log/appletv/uxplay.log",  // Основной путь в shared volume
		"/tmp/uxplay.log",             // Резервный путь
	}
	
	var output []byte
	var err error
	
	for _, path := range logPaths {
		output, err = os.ReadFile(path)
		if err == nil {
			break
		}
	}
	
	if err != nil {
		// Если файл не найден, попробуем через docker exec
		cmd := exec.Command("docker", "exec", "airplay-1", "cat", "/tmp/uxplay.log")
		output, err = cmd.Output()
		if err != nil {
			return nil, fmt.Errorf("failed to read UxPlay logs from any location: %v", err)
		}
	}
	
	lines := strings.Split(string(output), "\n")
	// Возвращаем последние 100 строк
	if len(lines) > 100 {
		lines = lines[len(lines)-100:]
	}
	
	return lines, nil
}

type WindowInfo struct {
	ID     string
	Name   string
	Width  int
	Height int
	Type   string
}

func parseInt(s string) int {
	i, err := strconv.Atoi(s)
	if err != nil {
		log.Printf("Failed to parse int from string: %s", s)
		return 0
	}
	return i
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// Проверяет, является ли окно потенциальным видеоокном по размеру (гибкая проверка)
func isVideoSizedWindow(width, height int) bool {
	// More flexible video window detection
	// Check for reasonable video dimensions
	minDimension := 200   // Minimum width or height
	maxDimension := 2560  // Maximum reasonable dimension
	
	// Both dimensions should be within reasonable range
	if width < minDimension || height < minDimension {
		return false
	}
	if width > maxDimension || height > maxDimension {
		return false
	}
	
	// Check aspect ratios common for video (very flexible)
	aspectRatio := float64(width) / float64(height)
	
	// Common video aspect ratios (with tolerance)
	// 16:9 = 1.78, 4:3 = 1.33, 16:10 = 1.6, 21:9 = 2.33, 9:16 = 0.56 (vertical), etc.
	validAspectRatios := [][]float64{
		{0.5, 0.8},   // Vertical (mobile) - 9:16 to 4:5
		{1.2, 2.5},   // Horizontal - 6:5 to 21:9
	}
	
	for _, ratioRange := range validAspectRatios {
		if aspectRatio >= ratioRange[0] && aspectRatio <= ratioRange[1] {
			return true
		}
	}
	
	return false
}

// Проверяет, является ли окно потенциальным видеоокном по размеру (точное соответствие)
func isVideoWindow(width, height int) bool {
	// Обычные видеоразрешения
	commonResolutions := [][]int{
		{1920, 1080}, {1920, 1200}, {1680, 1050}, {1600, 900}, {1440, 900},
		{1366, 768}, {1280, 720}, {1024, 768}, {800, 600},
		// Вертикальные (для мобильных)
		{1080, 1920}, {1200, 1920}, {1050, 1680}, {900, 1600}, {900, 1440},
		{768, 1366}, {720, 1280}, {768, 1024}, {600, 800},
		// Другие распространенные размеры
		{498, 1080}, {540, 960}, {414, 736}, {375, 667},
	}
	
	for _, res := range commonResolutions {
		if width == res[0] && height == res[1] {
			return true
		}
	}
	
	// Дополнительная проверка: окно имеет видеопропорции и разумный размер
	if width >= 320 && height >= 240 {
		aspectRatio := float64(width) / float64(height)
		// Обычные видеопропорции: 16:9, 4:3, 9:16 (вертикальное)
		if (aspectRatio >= 1.7 && aspectRatio <= 1.8) || // 16:9
		   (aspectRatio >= 1.3 && aspectRatio <= 1.4) || // 4:3
		   (aspectRatio >= 0.55 && aspectRatio <= 0.6) { // 9:16 (вертикальное)
			return true
		}
	}
	
	return false
}

// Улучшенная функция для получения окон UxPlay
func getUxPlayWindows() []WindowInfo {
	// Используем тот же дисплей, что и во всех остальных командах
	display := ":0"
	
	log.Printf("Getting UxPlay windows for DISPLAY=%s", display)
	
	// Тестируем различные дисплеи
	displays := []string{display, ":0", ":1"}
	for _, testDisplay := range displays {
		if testDisplay == display {
			continue // Уже будем тестировать основной дисплей
		}
		
		cmd := exec.Command("xdpyinfo", "-display", testDisplay)
		if err := cmd.Run(); err == nil {
			log.Printf("Alternative display %s is available", testDisplay)
		}
	}
	
	// Выполняем команду xwininfo локально в backend контейнере
	cmd := exec.Command("xwininfo", "-root", "-tree")
	cmd.Env = append(os.Environ(), "DISPLAY=:0", "XAUTHORITY=/root/.Xauthority")
	output, err := cmd.Output()
	if err != nil {
		log.Printf("ERROR: Failed to run xwininfo: %v", err)
		return []WindowInfo{}
	}
	
	outputStr := string(output)
	log.Printf("xwininfo output length: %d bytes", len(outputStr))
	
	// Логируем первые 15 строк вывода для диагностики
	lines := strings.Split(outputStr, "\n")
	log.Printf("First %d lines of xwininfo output:", min(15, len(lines)))
	for i, line := range lines {
		if i >= 15 {
			break
		}
		log.Printf("  %d: %s", i+1, line)
	}
	
	// Улучшенный регулярный выражение для парсинга окон
	// Поддерживаем различные форматы вывода xwininfo
	patterns := []string{
		`\s+(0x[0-9a-fA-F]+)\s+"([^"]+)"\s+\(([^)]+)\):\s+\(\+?(-?\d+)\+?(-?\d+)\)\s+(\d+)x(\d+)`,
		`\s+(0x[0-9a-fA-F]+)\s+"([^"]+)":\s+\(\+?(-?\d+)\+?(-?\d+)\)\s+(\d+)x(\d+)`,
		`\s+(0x[0-9a-fA-F]+)\s+\(([^)]+)\):\s+\(\+?(-?\d+)\+?(-?\d+)\)\s+(\d+)x(\d+)`,
	}
	
	var windows []WindowInfo
	
	for _, pattern := range patterns {
		re := regexp.MustCompile(pattern)
		matches := re.FindAllStringSubmatch(outputStr, -1)
		
		if len(matches) > 0 {
			log.Printf("Pattern matched %d windows with regex: %s", len(matches), pattern)
		}
		
		for _, match := range matches {
			if len(match) >= 7 {
				window := WindowInfo{
					ID:     match[1],
					Name:   match[2],
					Width:  parseInt(match[len(match)-2]),
					Height: parseInt(match[len(match)-1]),
				}
				
				// Определяем тип окна
				windowName := strings.ToLower(window.Name)
				if strings.Contains(windowName, "uxplay") {
					window.Type = "UxPlay"
				} else if strings.Contains(windowName, "airplay") {
					window.Type = "AirPlay"
				} else if strings.Contains(windowName, "opengl") || strings.Contains(windowName, "gl") {
					window.Type = "OpenGL"
				} else if strings.Contains(windowName, "gstreamer") || strings.Contains(windowName, "gst") {
					window.Type = "GStreamer"
				} else if isVideoWindow(window.Width, window.Height) {
					window.Type = "Video"  // Потенциальное видеоокно
				} else if window.Width > 100 && window.Height > 100 {
					window.Type = "Large"
				} else {
					window.Type = "Small"
				}
				
				windows = append(windows, window)
				log.Printf("Found window: ID=%s, Name=%s, Type=%s, Size=%dx%d", 
					window.ID, window.Name, window.Type, window.Width, window.Height)
			}
		}
	}
	
	log.Printf("Total windows found: %d", len(windows))
	
	// Если не найдено окон, выводим дополнительную диагностику
	if len(windows) == 0 {
		log.Printf("No windows found! Attempting additional diagnostics...")
		
		// Пытаемся использовать wmctrl как альтернативу
		cmd := exec.Command("wmctrl", "-l")
		if output, err := cmd.Output(); err == nil {
			log.Printf("wmctrl output: %s", string(output))
		} else {
			log.Printf("wmctrl not available or failed: %v", err)
		}
		
		// Проверяем процессы UxPlay в airplay контейнере
		cmd = exec.Command("docker", "exec", "airplay-1", "ps", "aux")
		if output, err := cmd.Output(); err == nil {
			outputStr := string(output)
			if strings.Contains(outputStr, "uxplay") {
				log.Printf("UxPlay process is running in container:")
				lines := strings.Split(outputStr, "\n")
				for _, line := range lines {
					if strings.Contains(strings.ToLower(line), "uxplay") {
						log.Printf("  %s", line)
					}
				}
			} else {
				log.Printf("No UxPlay process found in airplay container")
			}
		} else {
			log.Printf("Failed to check UxPlay processes in container: %v", err)
		}
	}
	
	// Сортируем окна по приоритету
	sort.Slice(windows, func(i, j int) bool {
		priority := map[string]int{
			"UxPlay":    6,
			"AirPlay":   5,
			"Video":     4,  // Высокий приоритет для видеоокон
			"OpenGL":    3,
			"GStreamer": 2,
			"Large":     1,
			"Small":     0,
		}
		
		pi, pj := priority[windows[i].Type], priority[windows[j].Type]
		if pi != pj {
			return pi > pj
		}
		
		// Если приоритет одинаковый, сортируем по размеру
		return windows[i].Width*windows[i].Height > windows[j].Width*windows[j].Height
	})
	
	return windows
}

func findLargestWindow(windows []WindowInfo) WindowInfo {
	if len(windows) == 0 {
		return WindowInfo{ID: "", Width: 0, Height: 0}
	}
	
	largest := windows[0]
	maxArea := largest.Width * largest.Height
	
	for _, window := range windows[1:] {
		area := window.Width * window.Height
		if area > maxArea {
			largest = window
			maxArea = area
		}
	}
	
	return largest
}

func getUxPlayProcesses() []map[string]interface{} {
	cmd := exec.Command("ps", "aux")
	output, err := cmd.Output()
	if err != nil {
		return nil
	}
	
	var processes []map[string]interface{}
	lines := strings.Split(string(output), "\n")
	
	for _, line := range lines {
		if strings.Contains(line, "uxplay") {
			fields := strings.Fields(line)
			if len(fields) >= 11 {
				processes = append(processes, map[string]interface{}{
					"pid":     fields[1],
					"cpu":     fields[2],
					"mem":     fields[3],
					"started": strings.Join(fields[8:10], " "),
					"command": strings.Join(fields[10:], " "),
				})
			}
		}
	}
	
	return processes
} 

// Enhanced auto-reconnection window state change handler
func handleWindowStateChange(hasWindow bool) {
	// Get current window details
	windowCount, currentWindowID := getWindowCountAndID()
	hasWindowByCount := windowCount > 0
	
	log.Printf("[AUTO-RECONNECT] Checking window state: hasWindow=%v->%v, windowID=%s->%s, checkCount=%d", 
		lastWindowState, hasWindowByCount, lastWindowID, currentWindowID, windowStateCheckCount)
	
	// ИСПРАВЛЕНИЕ: Проверяем смену window ID ПЕРЕД обновлением состояния
	// Случай: iPhone отключился и переподключился с новым window ID
	if hasWindowByCount && !lastWindowState && lastWindowID != "" && currentWindowID != "" && lastWindowID != currentWindowID {
		log.Printf("[AUTO-RECONNECT] WINDOW ID CHANGED after reconnection: %s -> %s (iPhone reconnected!)", lastWindowID, currentWindowID)
		
		// Update state immediately
		lastWindowID = currentWindowID
		lastWindowState = true
		windowStateCheckCount = 0
		
		// Trigger reconnection for window ID change
		handleWindowIDChanged(currentWindowID)
		return
	}
	
	// Проверяем смену window ID при активном соединении
	if hasWindowByCount && lastWindowState && lastWindowID != "" && currentWindowID != "" && lastWindowID != currentWindowID {
		log.Printf("[AUTO-RECONNECT] WINDOW ID CHANGED during active connection: %s -> %s (iPhone reconnected!)", lastWindowID, currentWindowID)
		
		// Update state immediately
		lastWindowID = currentWindowID
		lastWindowState = true
		windowStateCheckCount = 0
		
		// Trigger reconnection for window ID change
		handleWindowIDChanged(currentWindowID)
		return
	}
	
	// Additional check: If this is the first time we see a window, store its ID
	if hasWindowByCount && !lastWindowState && currentWindowID != "" && lastWindowID == "" {
		log.Printf("[AUTO-RECONNECT] First window detected: %s", currentWindowID)
		lastWindowID = currentWindowID
	}
		
	// Standard window presence change detection
	if hasWindowByCount == lastWindowState {
		windowStateCheckCount = 0
		log.Printf("[AUTO-RECONNECT] Window state unchanged, resetting check count")
		// DO NOT update lastWindowID here - it prevents window ID change detection!
		return
	}
	
	windowStateCheckCount++
	log.Printf("[AUTO-RECONNECT] Window state change detected, check count: %d/%d", 
		windowStateCheckCount, WINDOW_STATE_CONFIRMATION_CHECKS)
		
	if windowStateCheckCount < WINDOW_STATE_CONFIRMATION_CHECKS {
		log.Printf("[AUTO-RECONNECT] Waiting for more confirmations")
		return
	}
	
	// State change confirmed
	log.Printf("[AUTO-RECONNECT] Window state change CONFIRMED: %v -> %v", lastWindowState, hasWindowByCount)
	lastWindowState = hasWindowByCount
	
	// ИСПРАВЛЕНИЕ: Сохраняем lastWindowID только при появлении окна, 
	// НЕ очищаем при исчезновении для обнаружения смены window ID
	if hasWindowByCount && currentWindowID != "" {
		lastWindowID = currentWindowID
	}
	windowStateCheckCount = 0
	
	if hasWindowByCount {
		handleWindowAppeared()
	} else {
		handleWindowDisappeared()
	}
}

// Handle UxPlay window disappeared (iPhone disconnected)
func handleWindowDisappeared() {
	sessionMutex.Lock()
	defer sessionMutex.Unlock()
	
	log.Printf("[AUTO-RECONNECT] UxPlay window disappeared - iPhone disconnected")
	debugWarning("AUTO_RECONNECT", "window_disappeared", "UxPlay window disappeared - iPhone disconnected")
	
	// Clear reconnection readiness flags
	phoneReconnectedAndReady = false
	reconnectedWindowID = ""
	log.Printf("[AUTO-RECONNECT] Cleared reconnection readiness flags")
	debugInfo("AUTO_RECONNECT", "flags_cleared", "Cleared reconnection readiness flags")
	
	// Notify client about disconnection
	if activeWebSocketConn != nil {
		notifyWebSocketClient(map[string]interface{}{
			"type": "airplay_disconnected",
			"message": "iPhone disconnected from AppleTV",
		})
	}
	
	// Preserve WebSocket and clean up active session  
	if activeSession != nil {
		log.Printf("[AUTO-RECONNECT] Preserving WebSocket and cleaning up WebRTC session due to window disappearance")
		
		// Сохраняем WebSocket для auto-reconnection
		preservedWebSocket = activeSession.WebSocket
		log.Printf("[AUTO-RECONNECT] WebSocket preserved for auto-reconnection")
		
		// Полная очистка сессии
		activeSession.Cleanup()
		activeSession = nil
		log.Printf("[AUTO-RECONNECT] Session cleaned up, WebSocket preserved separately")
	}
	
	// Reset window ID tracking when iPhone disconnects
	lastWindowID = ""
	log.Printf("[AUTO-RECONNECT] Reset window ID tracking for clean reconnection detection")
	
	// ИСПРАВЛЕНО: Убран блокирующий вызов ensureUxPlayRunning()
	// Если iPhone переподключается, система автоматически это детектирует
	// Нет необходимости "проверять" или "перезапускать" UxPlay
	log.Printf("[AUTO-RECONNECT] Ready for iPhone reconnection detection")
}

// Handle UxPlay window appeared (iPhone reconnected)
func handleWindowAppeared() {
	sessionMutex.Lock()
	defer sessionMutex.Unlock()
	
	log.Printf("[AUTO-RECONNECT] UxPlay window appeared - iPhone reconnected")
	debugSuccess("AUTO_RECONNECT", "window_appeared", "UxPlay window appeared - iPhone reconnected")
	
	// Ignore window appearance during first 30 seconds after startup (initial UxPlay startup)
	if time.Since(startTime) < 30*time.Second {
		log.Printf("[AUTO-RECONNECT] Ignoring window appearance during startup period (uptime: %.1fs)", time.Since(startTime).Seconds())
		debugInfo("AUTO_RECONNECT", "startup_ignore", "Ignoring window appearance during startup period", map[string]interface{}{
			"uptime_seconds": time.Since(startTime).Seconds(),
		})
		return
	}
	
	// Check cooldown period
	if time.Since(lastAutoReconnectAttempt) < AUTO_RECONNECT_COOLDOWN {
		log.Printf("[AUTO-RECONNECT] Cooldown period active, skipping auto-reconnect")
		return
	}
	
	// Set reconnection readiness flags
	phoneReconnectedAndReady = true
	reconnectedWindowID = lastWindowID
	lastAutoReconnectAttempt = time.Now()
	
	log.Printf("[AUTO-RECONNECT] iPhone reconnected with window %s, marking as ready", lastWindowID)
	
	// Use preserved WebSocket or active WebSocket for notification
	var targetWebSocket *websocket.Conn
	if preservedWebSocket != nil {
		log.Printf("[AUTO-RECONNECT] Using preserved WebSocket for reconnection_ready notification")
		targetWebSocket = preservedWebSocket
		preservedWebSocket = nil // Clear after use
	} else if activeWebSocketConn != nil {
		log.Printf("[AUTO-RECONNECT] Using active WebSocket for reconnection_ready notification")
		targetWebSocket = activeWebSocketConn
	}
	
	// Check if WebRTC session is already active before sending reconnection notification
	if activeSession != nil && activeSession.PeerConn != nil && len(activeSession.PeerConn.GetSenders()) > 0 {
		log.Printf("[AUTO-RECONNECT] WebRTC session already active with %d tracks - no reconnection needed", len(activeSession.PeerConn.GetSenders()))
		// Clear flags since reconnection is not needed
		phoneReconnectedAndReady = false
		reconnectedWindowID = ""
		return
	}
	
	if targetWebSocket != nil {
		log.Printf("[AUTO-RECONNECT] Sending immediate reconnection_ready notification")
		
		// Use direct WebSocket write with mutex protection
		websocketWriteMutex.Lock()
		err := targetWebSocket.WriteMessage(websocket.TextMessage, []byte(`{
			"type": "reconnection_ready", 
			"message": "iPhone reconnected - auto-reconnecting in 5 seconds",
			"windowID": "`+lastWindowID+`"
		}`))
		websocketWriteMutex.Unlock()
		
		if err != nil {
			log.Printf("[ERROR] Failed to send reconnection_ready: %v", err)
		} else {
			log.Printf("[SUCCESS] reconnection_ready notification sent successfully")
		}
		
		// DO NOT clear flags here - let WebSocket handler check them first
		log.Printf("[AUTO-RECONNECT] Flags preserved for WebSocket handler to check")
	} else {
		log.Printf("[AUTO-RECONNECT] No WebSocket available, reconnection readiness saved for next connection")
	}
	
	log.Printf("[AUTO-RECONNECT] System ready for new WebSocket connection from client")
}

// Handle window ID change (iPhone reconnected with new window)
func handleWindowIDChanged(newWindowID string) {
	sessionMutex.Lock()
	defer sessionMutex.Unlock()
	
	log.Printf("[AUTO-RECONNECT] Window ID changed to %s - iPhone reconnected with new window", newWindowID)
	
	// Ignore window ID changes during first 30 seconds after startup (initial UxPlay startup)
	if time.Since(startTime) < 30*time.Second {
		log.Printf("[AUTO-RECONNECT] Ignoring window ID change during startup period (uptime: %.1fs)", time.Since(startTime).Seconds())
		return
	}
	
	// Check cooldown period
	if time.Since(lastAutoReconnectAttempt) < AUTO_RECONNECT_COOLDOWN {
		log.Printf("[AUTO-RECONNECT] Cooldown period active, skipping auto-reconnect")
		return
	}
	
	// Set reconnection readiness flags for window ID change
	phoneReconnectedAndReady = true
	reconnectedWindowID = newWindowID
	lastAutoReconnectAttempt = time.Now()
	
	log.Printf("[AUTO-RECONNECT] iPhone reconnected with new window %s, marking as ready", newWindowID)
	
	// Handle window ID change - clean up and prepare for new connection
	if autoReconnectEnabled {
		// Clean up existing session if any
		if activeSession != nil {
			log.Printf("[AUTO-RECONNECT] Cleaning up existing session before window ID change")
			log.Printf("[AUTO-RECONNECT] Old session ID: %s", activeSession.ID)
			activeSession.Cleanup()
			activeSession = nil
			log.Printf("[AUTO-RECONNECT] Old session cleanup completed")
		} else {
			log.Printf("[AUTO-RECONNECT] No active session to clean up")
		}
		
		// Check if WebRTC session is already active before sending reconnection notification
		if activeSession != nil && activeSession.PeerConn != nil && len(activeSession.PeerConn.GetSenders()) > 0 {
			log.Printf("[AUTO-RECONNECT] WebRTC session already active with %d tracks - no window change reconnection needed", len(activeSession.PeerConn.GetSenders()))
			// Clear flags since reconnection is not needed
			phoneReconnectedAndReady = false
			reconnectedWindowID = ""
			return
		}
		
		// Notify client about window change if WebSocket active
		if activeWebSocketConn != nil {
			log.Printf("[AUTO-RECONNECT] WebSocket active, sending immediate reconnection_ready notification for window change")
			notifyWebSocketClient(map[string]interface{}{
				"type": "reconnection_ready", 
				"message": "iPhone reconnected with new window - auto-reconnecting in 5 seconds",
				"windowID": newWindowID,
			})
			// DO NOT clear flags here - let WebSocket handler check them first
			log.Printf("[AUTO-RECONNECT] Flags preserved for WebSocket handler to check")
		} else {
			log.Printf("[AUTO-RECONNECT] WebSocket closed, window change readiness saved for next connection")
		}
		
		log.Printf("[AUTO-RECONNECT] System ready for new WebRTC connection with window %s", newWindowID)
	}
}

// Ensure UxPlay is running - restart if necessary
func ensureUxPlayRunning() {
	log.Printf("[AUTO-RECONNECT] Checking if UxPlay is running...")
	
	// Check if UxPlay process exists in container
	cmd := exec.Command("docker", "exec", "airplay-1", "pgrep", "uxplay")
	if err := cmd.Run(); err != nil {
		log.Printf("[AUTO-RECONNECT] UxPlay not running, attempting restart...")
		
		// Restart UxPlay container
		restartCmd := exec.Command("docker", "restart", "airplay-1")
		if err := restartCmd.Run(); err != nil {
			log.Printf("[AUTO-RECONNECT] Failed to restart airplay container: %v", err)
			return
		}
		
		log.Printf("[AUTO-RECONNECT] AirPlay container restarted, waiting for UxPlay...")
		
		// Wait a bit for the container to start
		time.Sleep(5 * time.Second)
		
		// Verify UxPlay is now running
		verifyCmd := exec.Command("docker", "exec", "airplay-1", "pgrep", "uxplay")
		if err := verifyCmd.Run(); err != nil {
			log.Printf("[AUTO-RECONNECT] UxPlay still not running after restart")
		} else {
			log.Printf("[AUTO-RECONNECT] UxPlay is now running after restart")
		}
	} else {
		log.Printf("[AUTO-RECONNECT] UxPlay is already running")
	}
}



// Initialize WebRTC session with tracks, FFmpeg capture, and RTP forwarding
func initializeWebRTCSession(peerConnection *webrtc.PeerConnection, windowID string, width, height int, sessionCtx context.Context, conn *websocket.Conn) error {
	log.Printf("[INFO] WebRTC: Starting session initialization for window %s (%dx%d)", windowID, width, height)
	
	// Allocate RTP ports
	videoPort, err := findFreePortWithRetry(3)
	if err != nil {
		return fmt.Errorf("failed to allocate video port: %v", err)
	}
	
	audioPort, err := findFreePortWithRetry(3)
	if err != nil {
		return fmt.Errorf("failed to allocate audio port: %v", err)
	}
	
	log.Printf("[INFO] WebRTC: Allocated ports - Video: %d, Audio: %d", videoPort, audioPort)
	
	// Create video track
	log.Printf("[DEBUG] WebRTC: Creating video track")
	videoTrack, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypeH264,
		ClockRate: 90000,
	}, "video", "pion-video")
	if err != nil {
		return fmt.Errorf("failed to create video track: %v", err)
	}
	
	rtpSender, err := peerConnection.AddTrack(videoTrack)
	if err != nil {
		return fmt.Errorf("failed to add video track: %v", err)
	}
	log.Printf("[INFO] WebRTC: Video track added successfully")
	
	// Create audio track
	log.Printf("[DEBUG] WebRTC: Creating audio track")
	audioTrack, err := webrtc.NewTrackLocalStaticRTP(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus}, "audio", "pion-audio")
	if err != nil {
		return fmt.Errorf("failed to create audio track: %v", err)
	}
	
	_, err = peerConnection.AddTrack(audioTrack)
	if err != nil {
		return fmt.Errorf("failed to add audio track: %v", err)
	}
	log.Printf("[INFO] WebRTC: Audio track added successfully")
	
	// Calculate safe RTP ports
	videoRTPPort := 50000 + (videoPort % 1000)
	audioRTPPort := 50000 + (audioPort % 1000)
	
	// Start FFmpeg capture
	log.Printf("[DEBUG] WebRTC: Starting FFmpeg capture process")
	ffmpegCmd, err := startFFmpegRTP(windowID, width, height, videoRTPPort, audioRTPPort)
	if err != nil {
		return fmt.Errorf("failed to start FFmpeg: %v", err)
	}
	log.Printf("[INFO] WebRTC: FFmpeg capture started successfully")
	
	// Start RTP listeners
	videoConn, err := net.ListenPacket("udp", fmt.Sprintf(":%d", videoRTPPort))
	if err != nil {
		if ffmpegCmd != nil && ffmpegCmd.Process != nil {
			ffmpegCmd.Process.Kill()
		}
		return fmt.Errorf("failed to listen on video RTP port %d: %v", videoRTPPort, err)
	}
	log.Printf("[INFO] WebRTC: Video RTP listener started on port %d", videoRTPPort)
	
	audioConn, err := net.ListenPacket("udp", fmt.Sprintf(":%d", audioRTPPort))
	if err != nil {
		videoConn.Close()
		if ffmpegCmd != nil && ffmpegCmd.Process != nil {
			ffmpegCmd.Process.Kill()
		}
		return fmt.Errorf("failed to listen on audio RTP port %d: %v", audioRTPPort, err)
	}
	log.Printf("[INFO] WebRTC: Audio RTP listener started on port %d", audioRTPPort)
	
	// Save session data
	sessionMutex.Lock()
	if activeSession != nil {
		activeSession.FFmpegCmd = ffmpegCmd
		activeSession.VideoPort = videoRTPPort
		activeSession.AudioPort = audioRTPPort
		activeSession.VideoConn = videoConn.(*net.UDPConn)
		activeSession.AudioConn = audioConn.(*net.UDPConn)
	}
	sessionMutex.Unlock()
	
	log.Printf("[INFO] WebRTC: Session initialized, starting packet forwarding")
	
	// Start video packet forwarding goroutine
	go func() {
		log.Printf("[DEBUG] WebRTC: Starting video packet forwarding goroutine")
		buffer := make([]byte, 65536)
		var packetsRead, packetsSent int64
		var lastLog time.Time
		
		for {
			select {
			case <-sessionCtx.Done():
				log.Printf("[DEBUG] WebRTC: Video forwarding goroutine stopping")
				log.Printf("[INFO] WebRTC Video Stats FINAL: Read=%d, Sent=%d packets", packetsRead, packetsSent)
				return
			default:
				videoConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
				n, _, err := videoConn.ReadFrom(buffer)
				if err != nil {
					if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
						continue
					}
					log.Printf("[ERROR] Video packet read error: %v", err)
					continue
				}
				if n > 0 {
					packetsRead++
					
					var rtpPacket rtp.Packet
					if err := rtpPacket.Unmarshal(buffer[:n]); err != nil {
						log.Printf("[ERROR] Failed to unmarshal RTP packet: %v", err)
						continue
					}
					
					if err := videoTrack.WriteRTP(&rtpPacket); err != nil {
						log.Printf("[ERROR] Failed to write video RTP packet: %v", err)
					} else {
						packetsSent++
					}
					
					now := time.Now()
					if now.Sub(lastLog) > 5*time.Second {
						log.Printf("[INFO] WebRTC Video Stats: Read=%d, Sent=%d packets (success rate: %.1f%%)", 
							packetsRead, packetsSent, float64(packetsSent)/float64(packetsRead)*100)
						lastLog = now
					}
				}
			}
		}
	}()
	
	// Start audio packet forwarding goroutine
	go func() {
		log.Printf("[DEBUG] WebRTC: Starting audio packet forwarding goroutine")
		buffer := make([]byte, 65536)
		var packetsRead, packetsSent int64
		var lastLog time.Time
		
		for {
			select {
			case <-sessionCtx.Done():
				log.Printf("[DEBUG] WebRTC: Audio forwarding goroutine stopping")
				log.Printf("[INFO] WebRTC Audio Stats FINAL: Read=%d, Sent=%d packets", packetsRead, packetsSent)
				return
			default:
				audioConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
				n, _, err := audioConn.ReadFrom(buffer)
				if err != nil {
					if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
						continue
					}
					log.Printf("[ERROR] Audio packet read error: %v", err)
					continue
				}
				if n > 0 {
					packetsRead++
					
					var rtpPacket rtp.Packet
					if err := rtpPacket.Unmarshal(buffer[:n]); err != nil {
						log.Printf("[ERROR] Failed to unmarshal RTP packet: %v", err)
						continue
					}
					
					if err := audioTrack.WriteRTP(&rtpPacket); err != nil {
						log.Printf("[ERROR] Failed to write audio RTP packet: %v", err)
					} else {
						packetsSent++
					}
					
					now := time.Now()
					if now.Sub(lastLog) > 5*time.Second {
						log.Printf("[INFO] WebRTC Audio Stats: Read=%d, Sent=%d packets (success rate: %.1f%%)", 
							packetsRead, packetsSent, float64(packetsSent)/float64(packetsRead)*100)
						lastLog = now
					}
				}
			}
		}
	}()
	
	// Start statistics monitoring
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			if rtpSender != nil {
				log.Printf("[DEBUG] WebRTC: Video track is active and sending data")
			}
			connState := peerConnection.ConnectionState()
			iceState := peerConnection.ICEConnectionState()
			log.Printf("[DEBUG] WebRTC: Connection State: %s, ICE State: %s", connState.String(), iceState.String())
			
			if connState == webrtc.PeerConnectionStateClosed || connState == webrtc.PeerConnectionStateFailed {
				log.Printf("[DEBUG] WebRTC: Stopping statistics monitoring due to connection state: %s", connState.String())
				return
			}
		}
	}()
	
	log.Printf("[SUCCESS] WebRTC: Session initialization completed successfully")
	return nil
}

// Send notification to WebSocket client with enhanced logging
func notifyWebSocketClient(message map[string]interface{}) {
	if activeWebSocketConn == nil {
		log.Printf("[AUTO-RECONNECT] No active WebSocket connection for notification: %s", message["type"])
		return
	}
	
	messageBytes, err := json.Marshal(message)
	if err != nil {
		log.Printf("[AUTO-RECONNECT] Failed to marshal notification: %v", err)
		return
	}
	
	log.Printf("[AUTO-RECONNECT] Sending notification to client: %s", message["type"])
	
	if err := safeWriteWebSocket(activeWebSocketConn, messageBytes); err != nil {
		log.Printf("[AUTO-RECONNECT] Failed to send notification to client: %v", err)
		// WebSocket is probably closed, clear reference
		activeWebSocketConn = nil
		log.Printf("[AUTO-RECONNECT] WebSocket connection cleared due to write error")
	} else {
		log.Printf("[AUTO-RECONNECT] Notification sent successfully: %s", message["type"])
	}
}

// Start FFmpeg capture for a session
func startFFmpegCapture(session *WebRTCSession, window *AirPlayWindow) error {
	log.Printf("[DEBUG] WebRTC: Pre-capture diagnostics for window %s", window.ID)
	
	// Pre-capture window diagnostics
	currentSize := fmt.Sprintf("%dx%d", window.Width, window.Height)
	log.Printf("[INFO] WebRTC: Window %s current size: %s (expected: %s)", window.ID, currentSize, currentSize)
	
	// Check audio devices
	log.Printf("[DEBUG] WebRTC: Checking available audio devices...")
	if _, err := exec.LookPath("aplay"); err != nil {
		log.Printf("[DEBUG] ALSA not available: %v", err)
	}
	if _, err := exec.LookPath("pactl"); err != nil {
		log.Printf("[DEBUG] PulseAudio not available: %v", err)
	}
	
	log.Printf("[INFO] WebRTC: Starting optimized video capture from AirPlay window")
	
	// Build FFmpeg command for optimized screen capture
	ffmpegArgs := []string{
		"-f", "x11grab",
		"-draw_mouse", "0",
		"-window_id", window.ID,
		"-video_size", currentSize,
		"-framerate", "30",
		"-probesize", "10M",
		"-i", ":0",
		"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p",
		"-c:v", "libx264",
		"-preset", "ultrafast",
		"-tune", "zerolatency",
		"-profile:v", "baseline",
		"-level", "3.1",
		"-pix_fmt", "yuv420p",
		"-g", "30",
		"-keyint_min", "30",
		"-sc_threshold", "0",
		"-b:v", "2M",
		"-maxrate", "2.5M",
		"-bufsize", "5M",
		"-crf", "28",
		"-f", "rtp",
		"-payload_type", "103",
		fmt.Sprintf("rtp://127.0.0.1:%d", session.VideoPort),
	}
	
	log.Printf("[INFO] WebRTC: Starting FFmpeg with command:")
	log.Printf("[INFO]   ffmpeg %s", strings.Join(ffmpegArgs, " "))
	log.Printf("[INFO] WebRTC: Video capture: window %s (%s) -> RTP port %d", window.ID, currentSize, session.VideoPort)
	
	// ИСПРАВЛЕНО: Start FFmpeg process локально в backend контейнере
	cmd := exec.CommandContext(session.Context, "ffmpeg", ffmpegArgs...)
	cmd.Env = append(os.Environ(),
		"DISPLAY=:0",
		"XAUTHORITY=/root/.Xauthority", 
		"LIBVA_DRIVER_NAME=i965",
	)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("failed to start FFmpeg: %v", err)
	}
	
	session.FFmpegCmd = cmd
	log.Printf("[INFO] WebRTC: FFmpeg capture started successfully")
	
	return nil
}

// Start RTP listeners for a session
func startRTPListeners(session *WebRTCSession) error {
	log.Printf("[DEBUG] WebRTC: Starting RTP listeners")
	
	// Video listener
	videoAddr, err := net.ResolveUDPAddr("udp", fmt.Sprintf("127.0.0.1:%d", session.VideoPort))
	if err != nil {
		return fmt.Errorf("failed to resolve video address: %v", err)
	}
	
	videoConn, err := net.ListenUDP("udp", videoAddr)
	if err != nil {
		return fmt.Errorf("failed to create video listener: %v", err)
	}
	
	session.VideoConn = videoConn
	log.Printf("[INFO] WebRTC: Video listener started on port %d", session.VideoPort)
	
	// Audio listener
	audioAddr, err := net.ResolveUDPAddr("udp", fmt.Sprintf("127.0.0.1:%d", session.AudioPort))
	if err != nil {
		return fmt.Errorf("failed to resolve audio address: %v", err)
	}
	
	audioConn, err := net.ListenUDP("udp", audioAddr)
	if err != nil {
		return fmt.Errorf("failed to create audio listener: %v", err)
	}
	
	session.AudioConn = audioConn
	log.Printf("[INFO] WebRTC: Audio listener started on port %d", session.AudioPort)
	
	log.Printf("[INFO] WebRTC: Session initialized, starting packet forwarding")
	
	// Start packet forwarding goroutines
	go func() {
		log.Printf("[DEBUG] WebRTC: Starting video packet forwarding goroutine")
		buffer := make([]byte, 1600)
		packetsRead := 0
		packetsSent := 0
		
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		
		for {
			select {
			case <-session.Context.Done():
				log.Printf("[INFO] WebRTC: Video packet forwarding stopped")
				return
			case <-ticker.C:
				if packetsRead > 0 {
					successRate := float64(packetsSent) / float64(packetsRead) * 100
					log.Printf("[INFO] WebRTC Video Stats: Read=%d, Sent=%d packets (success rate: %.1f%%)", 
						packetsRead, packetsSent, successRate)
				}
			default:
				session.VideoConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
				_, err := session.VideoConn.Read(buffer)
				if err != nil {
					if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
						continue
					}
					log.Printf("[WARNING] WebRTC: Video read error: %v", err)
					continue
				}
				
				packetsRead++
				
				// Forward to WebRTC (simplified - in real implementation would need proper RTP handling)
				packetsSent++
			}
		}
	}()
	
	go func() {
		log.Printf("[DEBUG] WebRTC: Starting audio packet forwarding goroutine")
		buffer := make([]byte, 1600)
		
		for {
			select {
			case <-session.Context.Done():
				log.Printf("[INFO] WebRTC: Audio packet forwarding stopped")
				return
			default:
				session.AudioConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
				_, err := session.AudioConn.Read(buffer)
				if err != nil {
					if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
						continue
					}
					log.Printf("[WARNING] WebRTC: Audio read error: %v", err)
					continue
				}
				
				// Forward to WebRTC (simplified - in real implementation would need proper RTP handling)
			}
		}
	}()
	
	return nil
}

// Get window dimensions for existing window
func getWindowDimensions(windowID string) (int, int, error) {
	cmd := exec.Command("xwininfo", "-id", windowID)
	cmd.Env = append(os.Environ(), "DISPLAY=:0")
	output, err := cmd.Output()
	if err != nil {
		return 0, 0, fmt.Errorf("failed to get window info: %v", err)
	}

	var width, height int
	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Width:") {
			fmt.Sscanf(line, "Width: %d", &width)
		} else if strings.HasPrefix(line, "Height:") {
			fmt.Sscanf(line, "Height: %d", &height)
		}
	}

	if width == 0 || height == 0 {
		return 0, 0, fmt.Errorf("failed to parse window dimensions")
	}

	return width, height, nil
}

// Wait for UxPlay window with client notifications