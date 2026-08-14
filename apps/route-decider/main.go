package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// defaultCell is the value returned by /get-cell until /set changes it.
// "A" routes to service-a at the api-gateway and to service-d via service-e's router.
const defaultCell = "A"

// state holds the current x-cell value. Simple and stupid: one value,
// guarded by a mutex, kept in memory.
var state = struct {
	sync.RWMutex
	cell string
}{cell: defaultCell}

func getCell() string {
	state.RLock()
	defer state.RUnlock()
	return state.cell
}

func setCell(c string) {
	state.Lock()
	defer state.Unlock()
	state.cell = c
}

// cellTarget is the JSON body shape for both /get-cell and /set.
type cellTarget struct {
	XCell string `json:"x-cell"`
}

// formatHeaders renders all HTTP headers as a sorted, single-line string for
// extensive request/response logging.
func formatHeaders(h http.Header) string {
	if len(h) == 0 {
		return "(none)"
	}
	keys := make([]string, 0, len(h))
	for k := range h {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for i, k := range keys {
		if i > 0 {
			b.WriteString(" ")
		}
		b.WriteString(fmt.Sprintf("%s=%q", k, strings.Join(h[k], ",")))
	}
	return b.String()
}

// readAndRestoreBody reads the full request body for logging and restores it so
// downstream handlers can read it again.
func readAndRestoreBody(r *http.Request) []byte {
	if r.Body == nil {
		return nil
	}
	data, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("route-decider failed to read request body: %v", err)
		return nil
	}
	r.Body = io.NopCloser(bytes.NewReader(data))
	return data
}

func writeJSON(w http.ResponseWriter, cell string) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(cellTarget{XCell: cell})
}

// getCell returns the current x-cell as JSON. No query parameters.
func getcell(w http.ResponseWriter, r *http.Request) {
	startedAt := time.Now()
	reqBody := readAndRestoreBody(r)
	log.Printf(
		"route-decider REQUEST method=%s url=%q proto=%s host=%s remote=%s headers=[%s] body=%q",
		r.Method, r.URL.String(), r.Proto, r.Host, r.RemoteAddr,
		formatHeaders(r.Header), string(reqBody),
	)

	cell := getCell()
	log.Printf("route-decider decision x-cell=%q user_agent=%q", cell, r.UserAgent())

	writeJSON(w, cell)
	log.Printf(
		"route-decider RESPONSE status=%d resp_headers=[%s] x-cell=%q duration=%s",
		http.StatusOK, formatHeaders(w.Header()), cell, time.Since(startedAt),
	)
}

// set updates the stored x-cell from a JSON body:
//
//	{"x-cell": "B"}
func set(w http.ResponseWriter, r *http.Request) {
	startedAt := time.Now()
	reqBody := readAndRestoreBody(r)
	log.Printf(
		"route-decider SET REQUEST method=%s url=%q remote=%s headers=[%s] body=%q",
		r.Method, r.URL.String(), r.RemoteAddr, formatHeaders(r.Header), string(reqBody),
	)

	var in cellTarget
	if err := json.Unmarshal(reqBody, &in); err != nil || strings.TrimSpace(in.XCell) == "" {
		log.Printf("route-decider SET rejected: invalid body err=%v", err)
		http.Error(w, `{"error":"body must be {\"x-cell\":\"<A|B>\"}"}`, http.StatusBadRequest)
		return
	}

	setCell(in.XCell)
	log.Printf("route-decider SET applied x-cell=%q", in.XCell)

	writeJSON(w, in.XCell)
	log.Printf(
		"route-decider SET RESPONSE status=%d x-cell=%q duration=%s",
		http.StatusOK, in.XCell, time.Since(startedAt),
	)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/get-cell", getcell)
	mux.HandleFunc("/set", set)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("route-decider health method=%s remote=%s user_agent=%q", r.Method, r.RemoteAddr, r.UserAgent())
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	addr := ":8080"
	log.Printf("route-decider http server listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		panic(fmt.Errorf("route-decider failed: %w", err))
	}
}
