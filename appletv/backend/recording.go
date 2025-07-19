package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
	"encoding/json"
	"log"
	"strconv"
)

var (
	recordingMu    sync.Mutex
	recordingCmd   *exec.Cmd
	recordingFile  string
	recordingStart time.Time
)

const recordsDir = "/var/airplay-records"

func logEvent(event string, fields map[string]interface{}) {
	fields["timestamp"] = time.Now().UTC().Format(time.RFC3339)
	fields["event"] = event
	b, _ := json.Marshal(fields)
	log.Println(string(b))
}

func StartRecording(filename string) error {
	recordingMu.Lock()
	defer recordingMu.Unlock()
	if recordingCmd != nil {
		logEvent("recording_start_failed", map[string]interface{}{"reason": "already_in_progress"})
		return errors.New("Recording already in progress")
	}
	if filename == "" {
		filename = "airplay-" + time.Now().Format("20060102-150405") + ".mp4"
	}
	if err := os.MkdirAll(recordsDir, 0755); err != nil {
		logEvent("recording_start_failed", map[string]interface{}{"reason": "mkdir_failed", "error": err.Error()})
		return fmt.Errorf("failed to create records dir: %w", err)
	}
	outPath := filepath.Join(recordsDir, filename)
	cmd := exec.Command(
		"ffmpeg",
		// Было: "-f", "fbdev", "-framerate", "30", "-i", "/dev/fb0",
		"-f", "x11grab", "-video_size", "1920x1080", "-framerate", "30", "-i", ":0",
		"-f", "alsa", "-i", "hw:Loopback,1",
		"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
		"-c:v", "libx264", "-preset", "ultrafast",
		"-c:a", "aac", "-strict", "-2",
		outPath,
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		logEvent("recording_start_failed", map[string]interface{}{"reason": "ffmpeg_failed", "error": err.Error(), "file": filename})
		return fmt.Errorf("failed to start ffmpeg: %w", err)
	}
	recordingCmd = cmd
	recordingFile = filename
	recordingStart = time.Now()
	logEvent("recording_started", map[string]interface{}{"file": filename})
	return nil
}

func StopRecording() (string, float64, error) {
	recordingMu.Lock()
	defer recordingMu.Unlock()
	if recordingCmd == nil {
		logEvent("recording_stop_failed", map[string]interface{}{"reason": "no_active_recording"})
		return "", 0, errors.New("No active recording to stop")
	}
	dur := time.Since(recordingStart).Seconds()
	err := recordingCmd.Process.Kill()
	file := recordingFile
	logEvent("recording_stopped", map[string]interface{}{"file": file, "duration": dur})
	recordingCmd = nil
	recordingFile = ""
	return file, dur, err
}

func getFileDuration(path string) float64 {
	cmd := exec.Command("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path)
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	var result struct {
		Format struct {
			Duration string `json:"duration"`
		} `json:"format"`
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return 0
	}
	dur, err := time.ParseDuration(result.Format.Duration + "s")
	if err == nil {
		return dur.Seconds()
	}
	// fallback: try to parse as float
	f, err := strconv.ParseFloat(result.Format.Duration, 64)
	if err == nil {
		return f
	}
	return 0
}

func ListRecordFiles() ([]RecordFile, error) {
	files := []RecordFile{}
	entries, err := os.ReadDir(recordsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return files, nil
		}
		return nil, err
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".mp4" {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		fullPath := filepath.Join(recordsDir, entry.Name())
		duration := getFileDuration(fullPath)
		files = append(files, RecordFile{
			Filename:  entry.Name(),
			Size:      info.Size(),
			Duration:  duration,
			CreatedAt: info.ModTime().UTC(),
		})
	}
	return files, nil
} 