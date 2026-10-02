// teilen – Ausgaben in einer Gruppe teilen (Spliit-Nachbau für den Heimserver).
//
// Unterbefehle:
//
//	teilen [serve]      startet den Server (Standard)
//	teilen healthcheck  prüft GET /healthz des laufenden Servers (Exit-Code 0/1)
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
	_ "time/tzdata" // Zeitzonen im scratch-Image

	"teilen/internal/config"
	"teilen/internal/export"
	"teilen/internal/fx"
	"teilen/internal/mcp"
	"teilen/internal/recurring"
	"teilen/internal/store"
	"teilen/internal/web"
	"teilen/internal/ynab"
)

// backupKeep ist die Anzahl der aufbewahrten nächtlichen Backups.
const backupKeep = 7

func main() {
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve()
	case "healthcheck":
		err = healthcheck(os.Getenv("TEILEN_ADDR"))
	default:
		fmt.Fprintf(os.Stderr, "unbekannter Befehl %q\nBenutzung: teilen [serve|healthcheck]\n", cmd)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "teilen:", err)
		os.Exit(1)
	}
}

// app ist die fertig verdrahtete Anwendung.
type app struct {
	handler   http.Handler
	fx        *fx.Service
	recurring *recurring.Service
	ynab      *ynab.Service
}

// newApp baut Deps, alle Services und den Mux.
func newApp(cfg config.Config, st *store.Store, log *slog.Logger) (*app, error) {
	render, err := web.NewRenderer(st, cfg.Location, log)
	if err != nil {
		return nil, err
	}
	d := web.Deps{Config: cfg, Store: st, Render: render, Log: log}

	fxSvc, err := fx.New(d)
	if err != nil {
		return nil, fmt.Errorf("fx: %w", err)
	}
	d.FX = fxSvc // ab hier sehen alle Pakete den Kursdienst

	rec, err := recurring.New(d)
	if err != nil {
		return nil, fmt.Errorf("recurring: %w", err)
	}
	yn, err := ynab.New(d)
	if err != nil {
		return nil, fmt.Errorf("ynab: %w", err)
	}

	mux := http.NewServeMux()
	web.Register(mux, d)
	fxSvc.Register(mux)
	rec.Register(mux)
	yn.Register(mux)
	if err := export.Register(mux, d); err != nil {
		return nil, fmt.Errorf("export: %w", err)
	}
	if err := mcp.Register(mux, d); err != nil {
		return nil, fmt.Errorf("mcp: %w", err)
	}
	return &app{handler: web.Wrap(d, mux), fx: fxSvc, recurring: rec, ynab: yn}, nil
}

func serve() error {
	cfg, err := config.FromEnv(os.Getenv)
	if err != nil {
		return err
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	st, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("datenbank %s: %w", cfg.DBPath, err)
	}
	defer st.Close()
	a, err := newApp(cfg, st, log)
	if err != nil {
		return err
	}

	ln, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var wg sync.WaitGroup
	wg.Go(func() { a.fx.Run(ctx) })
	wg.Go(func() { a.recurring.Run(ctx) })
	wg.Go(func() { a.ynab.Run(ctx) })
	wg.Go(func() { backupLoop(ctx, st, cfg, log) })

	srv := &http.Server{
		Handler:           a.handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	log.Info("teilen läuft", "addr", cfg.Addr, "db", cfg.DBPath, "tz", cfg.Location.String())

	select {
	case err = <-errc:
	case <-ctx.Done():
		log.Info("fahre herunter")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err = srv.Shutdown(shutdownCtx)
		cancel()
	}
	stop()
	wg.Wait()
	if errors.Is(err, http.ErrServerClosed) {
		err = nil
	}
	return err
}

// backupLoop schreibt jede Nacht um 03:00 (Ortszeit) ein Backup und behält
// die letzten backupKeep.
func backupLoop(ctx context.Context, st *store.Store, cfg config.Config, log *slog.Logger) {
	for {
		next := nextBackup(time.Now().In(cfg.Location))
		timer := time.NewTimer(time.Until(next))
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		path, err := st.Backup(ctx, cfg.BackupDir, backupKeep)
		if err != nil {
			log.Error("backup fehlgeschlagen", "err", err)
			continue
		}
		log.Info("backup geschrieben", "pfad", path)
	}
}

// nextBackup liefert den nächsten 03:00-Zeitpunkt nach now (in now's Zone).
func nextBackup(now time.Time) time.Time {
	t := time.Date(now.Year(), now.Month(), now.Day(), 3, 0, 0, 0, now.Location())
	if !t.After(now) {
		t = time.Date(now.Year(), now.Month(), now.Day()+1, 3, 0, 0, 0, now.Location())
	}
	return t
}

// healthcheck ruft GET /healthz auf dem lokalen Port auf.
func healthcheck(addr string) error {
	u, err := healthURL(addr)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 3 * time.Second}
	res, err := client.Get(u)
	if err != nil {
		return err
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("healthz: status %d", res.StatusCode)
	}
	return nil
}

func healthURL(addr string) (string, error) {
	if addr == "" {
		addr = ":8080"
	}
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return "", fmt.Errorf("TEILEN_ADDR %q: %w", addr, err)
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	return "http://" + net.JoinHostPort(host, port) + "/healthz", nil
}
