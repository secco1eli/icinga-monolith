//go:build ignore

// check-passive-questdb.go
// TODO: Query QuestDB for check results and submit them as passive checks to Icinga2.
//
// Each Go script owns its own query — define it as a const in this file.
//
// Planned behaviour:
//   1. Query QuestDB REST API with this script's specific query
//   2. For each row, POST a passive check result to the Icinga2 API
//      (POST /v1/actions/process-check-result)
//   3. Mark rows as processed in QuestDB
//
// Connection config (host, port, credentials) is read from ../config.env
//
// Run: go run check-passive-questdb.go
//      or build: go build -o check-passive-questdb check-passive-questdb.go

package main

func main() {
	// TODO: implement
}
