// bsp-poll.go
//
// Polls QuestDB for BSP timestamps and submits passive check results to Icinga2.
//
// Config is read from bsp-poll.toml in the same directory as the binary.
// Credentials and connection settings are injected as environment variables
// by run-bsp-poll.sh (sourced from config.env / secrets.env).
//
// Build:
//   cd scripts/checks && go mod tidy && go build -o bsp-poll bsp-poll.go
// Run via wrapper (sets env from config.env/secrets.env):
//   ./run-bsp-poll.sh [--dry-run]
// Print cron schedule (used by setup.sh to install /etc/cron.d/):
//   ./bsp-poll --cron
// Runs one poll cycle and exits — scheduling is handled by cron.

package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/BurntSushi/toml"
)

type Metric struct {
	Name           string  `json:"name"`
	Query          string  `json:"query"`
	Column         string  `json:"column"`
	Warn           float64 `json:"warn"`
	Crit           float64 `json:"crit"`
	Service        string  `json:"service"`
	StateFile      string  `json:"state_file,omitempty"`
	PassiveService string  `json:"passive_service,omitempty"`
	IsTimestamp    bool    `json:"is_timestamp,omitempty"`
}

// StateEntry holds the last known status and timestamp for a host/metric
type StateEntry struct {
	Status    int   `json:"status"`
	Timestamp int64 `json:"ts"`
	PostedAt  int64 `json:"posted_at,omitempty"`
}

// Config holds all settings from the check's TOML config file (<binary>.toml).
// Credentials and connection settings are NOT here — they come from environment
// variables set by run-<check>.sh (sourced from config.env / secrets.env).
type Config struct {
	Schedule struct {
		Cron string `toml:"cron"`
	} `toml:"schedule"`

	Icinga struct {
		ServiceName       string `toml:"service_name"`
		MissingHostStatus int    `toml:"missing_host_status"`
	} `toml:"icinga"`

	QuestDB struct {
		Query           string `toml:"query"`
		TimestampColumn string `toml:"timestamp_column"`
	} `toml:"questdb"`

	Thresholds struct {
		CritMinutes   int64 `toml:"crit_minutes"`
		WarnMinutes   int64 `toml:"warn_minutes"`   // 0 = no warning level, jump straight to CRITICAL
		ResyncSeconds int64 `toml:"resync_seconds"`
		HostOverrides []struct {
			Pattern     string `toml:"pattern"`
			CritMinutes int    `toml:"crit_minutes"`
			WarnMinutes int    `toml:"warn_minutes"` // 0 = inherit global warn_minutes
		} `toml:"host_overrides"`
	} `toml:"thresholds"`

	State struct {
		Dir string `toml:"dir"`
	} `toml:"state"`

	Reliability struct {
		PostRetries int     `toml:"post_retries"`
		PostBackoff float64 `toml:"post_backoff"`
		MaxWorkers  int     `toml:"max_workers"`
	} `toml:"reliability"`
}

// loadConfig loads <binary-name>.toml from the same directory as the running binary.
func loadConfig() Config {
	exe, err := os.Executable()
	if err != nil {
		logger.Fatalf("Cannot determine executable path: %v", err)
	}
	exe, err = filepath.EvalSymlinks(exe)
	if err != nil {
		logger.Fatalf("Cannot resolve executable symlinks: %v", err)
	}
	exeDir := filepath.Dir(exe)
	exeName := strings.TrimSuffix(filepath.Base(exe), filepath.Ext(filepath.Base(exe)))
	configPath := filepath.Join(exeDir, exeName+".toml")

	var cfg Config
	if _, err := toml.DecodeFile(configPath, &cfg); err != nil {
		logger.Fatalf("Cannot load config %s: %v", configPath, err)
	}
	logger.Printf("Loaded config from %s", configPath)
	return cfg
}

var (
	// ── Credentials & connection — set by run-<check>.sh from config.env / secrets.env ──
	QUESTDB_URL         = getenv("QUESTDB_URL", "")
	QUESTDB_USER        = getenv("QUESTDB_USER", "")
	QUESTDB_PASS        = getenv("QUESTDB_PASS", "")
	ICINGA_API_BASE     = getenv("ICINGA_API_BASE", "https://localhost:5665/")
	ICINGA_API_ACTION   = getenv("ICINGA_API_ACTION", "v1/actions/process-check-result")
	ICINGA_API_USER     = getenv("ICINGA_API_USER", "")
	ICINGA_API_PASS     = getenv("ICINGA_API_PASS", "")
	ICINGA_VERIFY_TLS   = getenvBool("ICINGA_VERIFY_TLS", false)
	COMBINED_STATE_FILE = getenv("COMBINED_STATE_FILE", "") // optional: override state file path

	// ── Behavioral settings — loaded from bsp-poll.toml in main() ────────────
	PASSIVE_SERVICE_NAME    string
	CRIT_THRESHOLD_SECONDS  int64
	WARN_THRESHOLD_SECONDS  int64 // 0 = no warning level
	RESYNC_INTERVAL_SECONDS int64
	MISSING_HOST_STATUS     int
	STATE_DIR               string
	POST_RETRIES            int
	POST_BACKOFF            float64
	MAX_WORKERS_DEFAULT     int
	thresholdRules          []thresholdRule
	METRICS                 []Metric

	logger     = log.New(os.Stdout, "", log.LstdFlags)
	httpClient *http.Client
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getenvInt(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

// formatAge returns a human-readable duration string for a number of seconds.
func formatAge(seconds int64) string {
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	if seconds < 3600 {
		m := seconds / 60
		s := seconds % 60
		if s == 0 {
			return fmt.Sprintf("%dm", m)
		}
		return fmt.Sprintf("%dm %ds", m, s)
	}
	h := seconds / 3600
	m := (seconds % 3600) / 60
	if m == 0 {
		return fmt.Sprintf("%dh", h)
	}
	return fmt.Sprintf("%dh %dm", h, m)
}

func getenvBool(key string, def bool) bool {
	v := strings.ToLower(os.Getenv(key))
	if v == "" {
		return def
	}
	return v == "1" || v == "true" || v == "yes"
}

// thresholdRule maps a host glob pattern to warn/crit thresholds in seconds.
// WarnSeconds == 0 means no warning level — go straight to CRITICAL.
type thresholdRule struct {
	Pattern     string
	CritSeconds int64
	WarnSeconds int64
}

type hostThresholds struct {
	CritSeconds int64
	WarnSeconds int64 // 0 = no warning level
}

// hostThreshold returns the warn/crit thresholds in seconds for host.
// Uses the first matching rule from rules; falls back to global defaults.
func hostThreshold(host string, rules []thresholdRule) hostThresholds {
	for _, r := range rules {
		if matched, err := filepath.Match(r.Pattern, host); err == nil && matched {
			return hostThresholds{CritSeconds: r.CritSeconds, WarnSeconds: r.WarnSeconds}
		}
	}
	return hostThresholds{CritSeconds: CRIT_THRESHOLD_SECONDS, WarnSeconds: WARN_THRESHOLD_SECONDS}
}

func initHTTPClient() {
	// seed jitter source once
	rand.Seed(time.Now().UnixNano())

	tr := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   30 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          200,
		MaxIdleConnsPerHost:   100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}
	if !ICINGA_VERIFY_TLS {
		tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	}
	httpClient = &http.Client{
		Transport: tr,
		Timeout:   15 * time.Second,
	}
}

func main() {
	printCron := flag.Bool("cron", false, "Print cron schedule from config and exit (used by setup.sh)")
	dryRun := flag.Bool("dry-run", false, "Parse and show changes but don't contact Icinga")
	flag.Parse()

	cfg := loadConfig()

	if *printCron {
		fmt.Println(cfg.Schedule.Cron)
		return
	}

	// Apply behavioral settings from TOML config
	PASSIVE_SERVICE_NAME    = cfg.Icinga.ServiceName
	CRIT_THRESHOLD_SECONDS  = cfg.Thresholds.CritMinutes * 60
	WARN_THRESHOLD_SECONDS  = cfg.Thresholds.WarnMinutes * 60
	RESYNC_INTERVAL_SECONDS = cfg.Thresholds.ResyncSeconds
	MISSING_HOST_STATUS     = cfg.Icinga.MissingHostStatus
	STATE_DIR               = cfg.State.Dir
	POST_RETRIES            = cfg.Reliability.PostRetries
	POST_BACKOFF            = cfg.Reliability.PostBackoff
	MAX_WORKERS_DEFAULT     = cfg.Reliability.MaxWorkers

	// Build per-host threshold rules from config (ordered, first match wins)
	for _, h := range cfg.Thresholds.HostOverrides {
		thresholdRules = append(thresholdRules, thresholdRule{
			Pattern:     h.Pattern,
			CritSeconds: int64(h.CritMinutes) * 60,
			WarnSeconds: int64(h.WarnMinutes) * 60,
		})
	}
	if len(thresholdRules) > 0 {
		logger.Printf("Loaded %d host threshold rules from config", len(thresholdRules))
	}

	// Build metric from TOML config
	METRICS = []Metric{{
		Name:        "bsp",
		Query:       strings.TrimSpace(cfg.QuestDB.Query),
		Column:      cfg.QuestDB.TimestampColumn,
		Service:     cfg.Icinga.ServiceName,
		IsTimestamp: true,
	}}

	if QUESTDB_URL == "" {
		logger.Fatal("QUESTDB_URL is not set — run via run-bsp-poll.sh or set environment variables")
	}
	if ICINGA_API_USER == "" || ICINGA_API_PASS == "" {
		logger.Fatal("ICINGA_API_USER / ICINGA_API_PASS not set — run via run-bsp-poll.sh")
	}

	initHTTPClient()

	logger.Printf("Starting poll cycle; metrics=%d", len(METRICS))

	changedAny := false
	for _, metric := range METRICS {
		changed, err := runMetricOnce(metric, *dryRun)
		if err != nil {
			logger.Printf("Metric %s failed: %v", metric.Name, err)
			continue
		}
		if changed {
			changedAny = true
		}
	}

	if changedAny {
		logger.Printf("Changes applied this cycle")
	}

	logger.Printf("Shutdown complete")
}

func _statePathForMetric(m Metric) string {
	if m.StateFile != "" {
		return m.StateFile
	}
	if COMBINED_STATE_FILE != "" {
		return COMBINED_STATE_FILE
	}
	fname := fmt.Sprintf("%s.state.json", m.Name)
	return filepath.Join(STATE_DIR, fname)
}

// loadState now returns map[string]StateEntry and handles legacy simple int values
func loadState(path string) (map[string]StateEntry, error) {
	out := map[string]StateEntry{}
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return out, nil
		}
		logger.Printf("Load state failed (%s): %v", path, err)
		return out, err
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(b, &raw); err != nil {
		logger.Printf("Load state failed (%s) JSON: %v", path, err)
		return out, err
	}
	for k, v := range raw {
		// support multiple shapes: object {status,ts}, number, string
		switch vt := v.(type) {
		case map[string]interface{}:
			se := StateEntry{}
			if s, ok := vt["status"]; ok {
				switch s2 := s.(type) {
				case float64:
					se.Status = int(s2)
				case string:
					if n, err := strconv.Atoi(s2); err == nil {
						se.Status = n
					}
				}
			}
			if ts, ok := vt["ts"]; ok {
				switch t2 := ts.(type) {
				case float64:
					se.Timestamp = int64(t2)
				case string:
					if n, err := strconv.ParseInt(t2, 10, 64); err == nil {
						se.Timestamp = n
					}
				}
			}
			out[k] = se
		case float64:
			out[k] = StateEntry{Status: int(vt), Timestamp: 0}
		case string:
			if n, err := strconv.Atoi(vt); err == nil {
				out[k] = StateEntry{Status: n, Timestamp: 0}
			}
		default:
			// ignore unknown shapes
		}
	}
	return out, nil
}

// saveState writes map[string]StateEntry to disk
func saveState(path string, state map[string]StateEntry) error {
	tmp := path + ".tmp"
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		logger.Printf("Save state failed mkdir (%s): %v", path, err)
		return err
	}
	b, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		logger.Printf("Save state failed marshal (%s): %v", path, err)
		return err
	}
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		logger.Printf("Save state failed write (%s): %v", tmp, err)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		logger.Printf("Save state failed rename (%s->%s): %v", tmp, path, err)
		return err
	}
	logger.Printf("Saved state to %s (entries=%d)", path, len(state))
	return nil
}

func icingaHealth() bool {
	u, err := url.Parse(ICINGA_API_BASE)
	if err != nil {
		logger.Printf("Icinga health: bad base URL: %v", err)
		return false
	}
	u.Path = strings.TrimSuffix(u.Path, "/") + "/v1/status"
	req, err := http.NewRequest("GET", u.String(), nil)
	if err != nil {
		logger.Printf("Icinga health: new request failed: %v", err)
		return false
	}
	req.SetBasicAuth(ICINGA_API_USER, ICINGA_API_PASS)
	resp, err := httpClient.Do(req)
	if err != nil {
		logger.Printf("Icinga health check failed: %v", err)
		return false
	}
	defer resp.Body.Close()
	// Any HTTP response means the API is up; only network errors or 5xx indicate a real outage.
	// A 401/403 means the API is responding but this user lacks status/query permission — still healthy.
	return resp.StatusCode < 500
}

func postResult(host, service string, exitStatus int, output string, ts int64, dryRun bool) bool {
	if dryRun {
		logger.Printf("[DRYRUN] %s %s -> %s (ts=%d)", host, service, output, ts)
		return true
	}
	// guard rails
	if POST_RETRIES < 1 {
		POST_RETRIES = 1
	}
	if httpClient == nil {
		initHTTPClient()
	}

	u, err := url.Parse(ICINGA_API_BASE)
	if err != nil {
		logger.Printf("postResult: invalid icinga base: %v", err)
		return false
	}
	u.Path = strings.TrimSuffix(u.Path, "/") + "/" + strings.TrimPrefix(ICINGA_API_ACTION, "/")

	// include timestamp in payload and append to plugin_output for visibility
	payload := map[string]interface{}{
		"type":          "Service",
		"filter":        fmt.Sprintf("host.name==\"%s\" && service.name==\"%s\"", host, service),
		"exit_status":   exitStatus,
		"plugin_output": output,
		"timestamp":     ts,
	}
	// append age as numeric performance data (graphable by Icinga)
	if ts != 0 {
		age := time.Now().Unix() - ts
		payload["plugin_output"] = fmt.Sprintf("%s | age=%ds", output, age)
	}

	b, _ := json.Marshal(payload)

	var lastErr error
	// use a root context with default httpClient timeout
	ctx := context.Background()

	for attempt := 1; attempt <= POST_RETRIES; attempt++ {
		req, err := http.NewRequestWithContext(ctx, "POST", u.String(), bytes.NewBuffer(b))
		if err != nil {
			lastErr = err
			logger.Printf("postResult: build req failed: %v", err)
		} else {
			req.Header.Set("Accept", "application/json")
			req.Header.Set("Content-Type", "application/json")
			req.SetBasicAuth(ICINGA_API_USER, ICINGA_API_PASS)

			resp, err := httpClient.Do(req)
			if err != nil {
				lastErr = err
				logger.Printf("Post attempt %d exception for %s: %v", attempt, host, err)
			} else {
				bodyBytes, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
				resp.Body.Close()
				if resp.StatusCode >= 200 && resp.StatusCode < 300 {
					logger.Printf("Posted: host=%s service=%s status=%d ts=%d", host, service, exitStatus, ts)
					return true
				}
				lastErr = fmt.Errorf("status %d body %s", resp.StatusCode, strings.TrimSpace(string(bodyBytes)))
				logger.Printf("Icinga API %d for %s: %s", resp.StatusCode, host, strings.TrimSpace(string(bodyBytes)))
			}
		}

		// exponential backoff with jitter
		mult := math.Pow(2, float64(attempt-1))
		sleepSec := POST_BACKOFF * mult
		jitter := 0.1 * sleepSec * (rand.Float64()*2 - 1)
		total := sleepSec + jitter
		if total < 0.1 {
			total = 0.1
		}
		time.Sleep(time.Duration(total * float64(time.Second)))
	}
	logger.Printf("Giving up posting for %s after %d attempts: last error: %v", host, POST_RETRIES, lastErr)
	return false
}

// fetchIcingaHostNames fetches all hosts from the Icinga API and returns a set of host names.
func fetchIcingaHostNames() (map[string]bool, error) {
	out := make(map[string]bool)

	u, err := url.Parse(ICINGA_API_BASE)
	if err != nil {
		return out, fmt.Errorf("bad ICINGA_API_BASE: %v", err)
	}
	u.Path = strings.TrimSuffix(u.Path, "/") + "/v1/objects/hosts"

	req, err := http.NewRequest("GET", u.String(), nil)
	if err != nil {
		return out, err
	}
	req.SetBasicAuth(ICINGA_API_USER, ICINGA_API_PASS)
	req.Header.Set("Accept", "application/json")

	resp, err := httpClient.Do(req)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return out, fmt.Errorf("icinga returned %d: %s", resp.StatusCode, string(body))
	}

	var parsed interface{}
	dec := json.NewDecoder(resp.Body)
	dec.UseNumber()
	if err := dec.Decode(&parsed); err != nil {
		return out, fmt.Errorf("json decode icinga hosts: %v", err)
	}

	switch v := parsed.(type) {
	case map[string]interface{}:
		if res, ok := v["results"]; ok {
			if arr, ok := res.([]interface{}); ok {
				for _, it := range arr {
					if m, ok := it.(map[string]interface{}); ok {
						if name, ok := m["name"].(string); ok && name != "" {
							out[name] = true
							continue
						}
						if attrs, ok := m["attrs"].(map[string]interface{}); ok {
							if name, ok := attrs["name"].(string); ok && name != "" {
								out[name] = true
								continue
							}
							if dn, ok := attrs["display_name"].(string); ok && dn != "" {
								out[dn] = true
								continue
							}
							if hn, ok := attrs["host_name"].(string); ok && hn != "" {
								out[hn] = true
								continue
							}
						}
					}
				}
				return out, nil
			}
		}
		for _, vv := range v {
			if objm, ok := vv.(map[string]interface{}); ok {
				if name, ok := objm["name"].(string); ok && name != "" {
					out[name] = true
				} else if attrs, ok := objm["attrs"].(map[string]interface{}); ok {
					if name, ok := attrs["name"].(string); ok && name != "" {
						out[name] = true
					}
				}
			}
		}
	case []interface{}:
		for _, item := range v {
			if obj, ok := item.(map[string]interface{}); ok {
				if name, ok := obj["name"].(string); ok && name != "" {
					out[name] = true
				} else if attrs, ok := obj["attrs"].(map[string]interface{}); ok {
					if name, ok := attrs["name"].(string); ok && name != "" {
						out[name] = true
					}
				}
			}
		}
	}

	return out, nil
}

// extractTimestamp attempts to parse common timestamp shapes returned by QuestDB
// returns unix seconds and true if parsed
func extractTimestamp(val interface{}) (int64, bool) {
	if val == nil {
		return 0, false
	}
	switch tv := val.(type) {
	case float64:
		// could be milliseconds or seconds; assume seconds if reasonable
		if tv > 1e12 { // probably micro/nanoseconds, convert to seconds
			return int64(tv / 1e3), true
		}
		if tv > 1e9 { // milliseconds
			return int64(tv / 1e3), true
		}
		if tv > 1e7 { // seconds
			return int64(tv), true
		}
		return int64(tv), true
	case json.Number:
		if i, err := tv.Int64(); err == nil {
			return i, true
		}
		if f, err := tv.Float64(); err == nil {
			return int64(f), true
		}
	case string:
		// try parse as int
		if i, err := strconv.ParseInt(tv, 10, 64); err == nil {
			return i, true
		}
		// try parse as RFC3339
		if t, err := time.Parse(time.RFC3339, tv); err == nil {
			return t.Unix(), true
		}
		// try common layout
		if t, err := time.Parse("2006-01-02 15:04:05", tv); err == nil {
			return t.Unix(), true
		}
	default:
		// fallback to stringified
		s := fmt.Sprintf("%v", val)
		if i, err := strconv.ParseInt(s, 10, 64); err == nil {
			return i, true
		}
	}
	return 0, false
}

// runMetricOnce posts all hosts on the metric's first run, posts missing hosts present in Icinga,
// and marks datapoints older than STALE_THRESHOLD_SECONDS as UNKNOWN or CRITICAL depending on metric type.
func runMetricOnce(metric Metric, dryRun bool) (bool, error) {
	threshRules := thresholdRules

	statePath := _statePathForMetric(metric)
	prevState, _ := loadState(statePath)

	if prevState == nil {
		prevState = make(map[string]StateEntry)
	}

	// Determine whether this is the first run for this metric.
	firstRun := true
	prefix := metric.Name + ":"
	for k := range prevState {
		if strings.HasPrefix(k, prefix) {
			firstRun = false
			break
		}
	}

	data, err := fetchQuestDBJSON(metric.Query)
	if err != nil {
		logger.Printf("Skipping %s due to fetch error: %v", metric.Name, err)
		return false, nil
	}
	rows := rowsFromQuestDB(data)
	logger.Printf("Metric %s: fetched %d hosts", metric.Name, len(rows))

	type task struct {
		host   string
		svc    string
		status int
		output string
		key    string
		ts     int64
	}

	type result struct {
		key    string
		status int
		ok     bool
		host   string
		ts     int64
	}

	// preallocate tasks slice
	tasks := make([]task, 0, len(rows))

	// Build tasks for hosts present in QuestDB (all on first run, otherwise only changed)
	for host, row := range rows {
		// If metric is timestamp-based, compute status by age
		if metric.IsTimestamp {
			var ts int64
			if tval, ok := row[metric.Column]; ok {
				if tv, parsed := extractTimestamp(tval); parsed {
					ts = tv
				}
			} else if tval, ok := row["timestamp"]; ok {
				if tv, parsed := extractTimestamp(tval); parsed {
					ts = tv
				}
			}
			now := time.Now().Unix()
			thresh := hostThreshold(host, threshRules)
			status := 3
			output := ""
			if ts == 0 {
				status = 3
				output = "UNKNOWN: no timestamp value"
			} else {
				age := now - ts
				humanTs := time.Unix(ts, 0).Local().Format("2006-01-02 15:04:05 MST")
				if age > thresh.CritSeconds {
					status = 2
					output = fmt.Sprintf("CRITICAL: last poll %s ago (%s)", formatAge(age), humanTs)
				} else if thresh.WarnSeconds > 0 && age > thresh.WarnSeconds {
					status = 1
					output = fmt.Sprintf("WARNING: last poll %s ago (%s)", formatAge(age), humanTs)
				} else {
					status = 0
					output = fmt.Sprintf("OK: last poll %s ago (%s)", formatAge(age), humanTs)
				}
			}
			key := fmt.Sprintf("%s:%s", metric.Name, host)
			// determine service name for passive posting: metric.PassiveService -> metric.Service -> global default
			svc := metric.PassiveService
			if svc == "" {
				if metric.Service != "" {
					svc = metric.Service
				} else {
					svc = PASSIVE_SERVICE_NAME
				}
			}
			if firstRun {
				tasks = append(tasks, task{host: host, svc: svc, status: status, output: output, key: key, ts: ts})
			} else {
				prev, ok := prevState[key]
				stale := RESYNC_INTERVAL_SECONDS > 0 && (prev.PostedAt == 0 || now-prev.PostedAt > RESYNC_INTERVAL_SECONDS)
				if !ok || prev.Status != status || stale {
					tasks = append(tasks, task{host: host, svc: svc, status: status, output: output, key: key, ts: ts})
				}
			}
			continue
		}

		// legacy numeric evaluation path (unchanged)
		val := row[metric.Column]
		status, out := evaluateThreshold(val, metric.Warn, metric.Crit)

		// attempt to extract timestamp from common fields
		var ts int64
		if tval, ok := row["timestamp"]; ok {
			if tv, parsed := extractTimestamp(tval); parsed {
				ts = tv
			}
		} else if tval, ok := row["ts"]; ok {
			if tv, parsed := extractTimestamp(tval); parsed {
				ts = tv
			}
		}

		// If datapoint is stale, override status and output (legacy behavior: UNKNOWN)
		now := time.Now().Unix()
		if ts != 0 && now-ts > hostThreshold(host, threshRules).CritSeconds {
			status = 3
			humanTs := time.Unix(ts, 0).Format(time.RFC3339)
			out = fmt.Sprintf("UNKNOWN: stale datapoint (%s) - %s", humanTs, out)
		}

		key := fmt.Sprintf("%s:%s", metric.Name, host)
		// determine service name
		svc := metric.PassiveService
		if svc == "" {
			if metric.Service != "" {
				svc = metric.Service
			} else {
				svc = PASSIVE_SERVICE_NAME
			}
		}

		if firstRun {
			tasks = append(tasks, task{host: host, svc: svc, status: status, output: out, key: key, ts: ts})
		} else {
			prev, ok := prevState[key]
			stale := RESYNC_INTERVAL_SECONDS > 0 && (prev.PostedAt == 0 || now-prev.PostedAt > RESYNC_INTERVAL_SECONDS)
			if !ok || prev.Status != status || stale {
				tasks = append(tasks, task{host: host, svc: svc, status: status, output: out, key: key, ts: ts})
			}
		}
	}
	logger.Printf("Metric %s: %d changed/queued from QuestDB", metric.Name, len(tasks))

	// Build a set of quest hosts for comparison
	questHosts := make(map[string]bool, len(rows))
	for h := range rows {
		questHosts[h] = true
	}

	// Fetch hosts from Icinga and add missing-host tasks (icinga \\ questdb)
	icingaHosts, err := fetchIcingaHostNames()
	if err != nil {
		logger.Printf("Warning: cannot fetch Icinga hosts: %v", err)
	} else {
		missingCount := 0
		for ih := range icingaHosts {
			if _, ok := questHosts[ih]; !ok {
				key := fmt.Sprintf("%s:%s", metric.Name, ih)
				prev, ok := prevState[key]
				missingStatus := MISSING_HOST_STATUS
				if !ok || prev.Status != missingStatus {
					out := fmt.Sprintf("UNKNOWN: host missing from QuestDB for metric %s", metric.Name)
					// use current time for missing-host timestamp
					ts := time.Now().Unix()
					svc := metric.PassiveService
					if svc == "" {
						if metric.Service != "" {
							svc = metric.Service
						} else {
							svc = PASSIVE_SERVICE_NAME
						}
					}
					tasks = append(tasks, task{host: ih, svc: svc, status: missingStatus, output: out, key: key, ts: ts})
					missingCount++
				}
			}
		}
		if missingCount > 0 {
			logger.Printf("Metric %s: %d hosts present in Icinga but missing in QuestDB", metric.Name, missingCount)
		}
	}

	if len(tasks) > 0 && !dryRun && !icingaHealth() {
		logger.Printf("Icinga API unhealthy; skipping posts for %s", metric.Name)
		return false, nil
	}

	if len(tasks) == 0 {
		if firstRun {
			if err := saveState(statePath, prevState); err != nil {
				logger.Printf("Warning: saving state failed: %v", err)
			}
		}
		return false, nil
	}

	// compute workers: scale with tasks but cap at MAX_WORKERS_DEFAULT
	workerFromTasks := len(tasks) / 10
	if workerFromTasks < 1 {
		workerFromTasks = 1
	}
	workerCount := workerFromTasks
	if workerCount > MAX_WORKERS_DEFAULT {
		workerCount = MAX_WORKERS_DEFAULT
	}
	if workerCount > len(tasks) {
		workerCount = len(tasks)
	}
	if workerCount < 1 {
		workerCount = 1
	}
	logger.Printf("Posting %d results with up to %d workers", len(tasks), workerCount)

	var success, failure int32
	var wg sync.WaitGroup

	taskCh := make(chan task, len(tasks))        // buffered to avoid blocking dispatcher
	resultsCh := make(chan result, len(tasks)+1) // buffered so workers never block on send

	// worker pool
	for i := 0; i < workerCount; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for t := range taskCh {
				ok := postResult(t.host, t.svc, t.status, t.output, t.ts, dryRun)
				if ok {
					atomic.AddInt32(&success, 1)
				} else {
					atomic.AddInt32(&failure, 1)
					logger.Printf("Failed to post for %s (left state unchanged)", t.host)
				}
				// send result for single-threaded state update
				resultsCh <- result{key: t.key, status: t.status, ok: ok, host: t.host, ts: t.ts}
			}
		}()
	}

	// dispatch tasks
	for _, t := range tasks {
		taskCh <- t
	}
	close(taskCh)

	// close resultsCh after workers finish
	go func() {
		wg.Wait()
		close(resultsCh)
	}()

	// collect results and update prevState in this goroutine only
	now := time.Now().Unix()
	for res := range resultsCh {
		if res.ok {
			prevState[res.key] = StateEntry{Status: res.status, Timestamp: res.ts, PostedAt: now}
		}
	}

	if err := saveState(statePath, prevState); err != nil {
		logger.Printf("Warning: saving state failed: %v", err)
	}

	logger.Printf("Posting summary for %s: attempted=%d succeeded=%d failed=%d", metric.Name, len(tasks), atomic.LoadInt32(&success), atomic.LoadInt32(&failure))
	return true, nil
}

func fetchQuestDBJSON(query string) (interface{}, error) {
	u, err := url.Parse(QUESTDB_URL)
	if err != nil {
		return nil, fmt.Errorf("bad QUESTDB_URL: %v", err)
	}
	params := url.Values{}
	params.Set("query", query)
	u.RawQuery = params.Encode()
	req, err := http.NewRequest("GET", u.String(), nil)
	if err != nil {
		return nil, err
	}
	if QUESTDB_USER != "" || QUESTDB_PASS != "" {
		req.SetBasicAuth(QUESTDB_USER, QUESTDB_PASS)
	}
	req.Header.Set("Accept", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, fmt.Errorf("questdb returned %d: %s", resp.StatusCode, string(body))
	}
	var parsed interface{}
	dec := json.NewDecoder(resp.Body)
	dec.UseNumber()
	if err := dec.Decode(&parsed); err != nil {
		return nil, fmt.Errorf("json decode: %v", err)
	}
	return parsed, nil
}

func rowsFromQuestDB(raw interface{}) map[string]map[string]interface{} {
	out := map[string]map[string]interface{}{}
	switch v := raw.(type) {
	case map[string]interface{}:
		if colsIface, ok := v["columns"]; ok {
			colsArr, ok := colsIface.([]interface{})
			if !ok {
				break
			}
			cols := []string{}
			for _, ci := range colsArr {
				if cim, ok := ci.(map[string]interface{}); ok {
					if name, ok := cim["name"].(string); ok {
						cols = append(cols, name)
					}
				}
			}
			dsIface, ok := v["dataset"]
			if ok {
				if dsArr, ok := dsIface.([]interface{}); ok {
					for _, rowIface := range dsArr {
						rowArr, ok := rowIface.([]interface{})
						if !ok {
							continue
						}
						obj := map[string]interface{}{}
						for i := 0; i < len(cols) && i < len(rowArr); i++ {
							obj[cols[i]] = rowArr[i]
						}
						hostVal := fmt.Sprintf("%v", obj["host"])
						if hostVal != "" && hostVal != "<nil>" && hostVal != "nil" {
							out[hostVal] = obj
						}
					}
					return out
				}
			}
		}
		for _, vv := range v {
			if objm, ok := vv.(map[string]interface{}); ok {
				if hostKey := objm["host"]; hostKey != nil {
					hostStr := fmt.Sprintf("%v", hostKey)
					out[hostStr] = objm
				}
			}
		}
	case []interface{}:
		for _, item := range v {
			if obj, ok := item.(map[string]interface{}); ok {
				if hostVal, ok := obj["host"]; ok {
					hostStr := fmt.Sprintf("%v", hostVal)
					out[hostStr] = obj
				}
			}
		}
	default:
		logger.Printf("Unknown QuestDB JSON shape")
	}
	return out
}

func evaluateThreshold(val interface{}, warn, crit float64) (int, string) {
	if val == nil {
		return 3, "UNKNOWN: no value"
	}
	var f float64
	switch tv := val.(type) {
	case float64:
		f = tv
	case json.Number:
		if fv, err := tv.Float64(); err == nil {
			f = fv
		} else {
			return 3, fmt.Sprintf("UNKNOWN: bad value %v", val)
		}
	case string:
		if tv == "" {
			return 3, "UNKNOWN: no value"
		}
		if fv, err := strconv.ParseFloat(tv, 64); err == nil {
			f = fv
		} else {
			return 3, fmt.Sprintf("UNKNOWN: bad value %v", val)
		}
	default:
		s := fmt.Sprintf("%v", val)
		if s == "" {
			return 3, "UNKNOWN: no value"
		}
		if fv, err := strconv.ParseFloat(s, 64); err == nil {
			f = fv
		} else {
			return 3, fmt.Sprintf("UNKNOWN: bad value %v", val)
		}
	}
	if f > crit {
		return 2, fmt.Sprintf("CRITICAL: value=%v", f)
	}
	if f > warn {
		return 1, fmt.Sprintf("WARNING: value=%v", f)
	}
	return 0, fmt.Sprintf("OK: value=%v", f)
}
