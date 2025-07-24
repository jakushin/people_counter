package main

import "time"

type StartRecordRequest struct {
	Filename string `json:"filename"`
}

type StartRecordResponse struct {
	Status    string    `json:"status"`
	File      string    `json:"file"`
	StartedAt time.Time `json:"startedAt"`
}

type StopRecordResponse struct {
	Status   string  `json:"status"`
	File     string  `json:"file"`
	Duration float64 `json:"duration"`
}

type RecordFile struct {
	Filename  string    `json:"filename"`
	Size      int64     `json:"size"`
	Duration  float64   `json:"duration"`
	CreatedAt time.Time `json:"createdAt"`
}

type AirPlayWindow struct {
	ID     string
	Name   string  
	Width  int
	Height int
	X      int
	Y      int
} 