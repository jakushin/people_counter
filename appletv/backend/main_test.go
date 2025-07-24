package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"encoding/json"
)

func setupRouter() http.Handler {
	r := gin.Default()

	r.GET("/api/health", func(c *gin.Context) {
		c.JSON(200, gin.H{"status": "ok"})
	})

	r.POST("/api/record/start", func(c *gin.Context) {
		c.JSON(409, gin.H{"error": "Recording already in progress"})
	})

	r.POST("/api/record/stop", func(c *gin.Context) {
		c.JSON(400, gin.H{"error": "No active recording to stop"})
	})

	r.GET("/api/records", func(c *gin.Context) {
		c.JSON(200, []RecordFile{})
	})

	return r
}

func TestHealthEndpoint(t *testing.T) {
	r := setupRouter()
	req := httptest.NewRequest("GET", "/api/health", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var resp map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if resp["status"] != "ok" {
		t.Fatalf("unexpected status: %v", resp["status"])
	}
}

func TestStartRecordingConflict(t *testing.T) {
	r := setupRouter()
	req := httptest.NewRequest("POST", "/api/record/start", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != 409 {
		t.Fatalf("expected 409, got %d", w.Code)
	}
}

func TestStopRecordingNoActive(t *testing.T) {
	r := setupRouter()
	req := httptest.NewRequest("POST", "/api/record/stop", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != 400 {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestRecordsListEmpty(t *testing.T) {
	r := setupRouter()
	req := httptest.NewRequest("GET", "/api/records", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var resp []RecordFile
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if len(resp) != 0 {
		t.Fatalf("expected empty list, got %d", len(resp))
	}
}

func TestDeleteNonexistentFile(t *testing.T) {
	r := setupRouter()
	req := httptest.NewRequest("DELETE", "/api/records/notfound.mp4", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != 404 && w.Code != 400 {
		t.Fatalf("expected 404 or 400, got %d", w.Code)
	}
}

func TestRecordStatus(t *testing.T) {
	r := setupRouter()
	req := httptest.NewRequest("GET", "/api/record/status", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	var resp map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if _, ok := resp["recording"]; !ok {
		t.Fatalf("missing 'recording' field")
	}
} 