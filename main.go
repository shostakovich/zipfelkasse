// Zipfelkasse – share expenses within a group (a Spliit port for the home server).
//
// Subcommands:
//
//	zipfelkasse [serve]      starts the server (default)
//	zipfelkasse healthcheck  checks GET /healthz of the running server (exit code 0/1)
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
	_ "time/tzdata" // time zones in the scratch image

	"github.com/shostakovich/zipfelkasse/internal/config"
	"github.com/shostakovich/zipfelkasse/internal/export"
	"github.com/shostakovich/zipfelkasse/internal/fx"
	"github.com/shostakovich/zipfelkasse/internal/mcp"
	"github.com/shostakovich/zipfelkasse/internal/recurring"
	"github.com/shostakovich/zipfelkasse/internal/store"
	"github.com/shostakovich/zipfelkasse/internal/web"
	"github.com/shostakovich/zipfelkasse/internal/ynab"
)

// backupKeep is the number of nightly backups kept.
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
		err = healthcheck(os.Getenv("ZIPFELKASSE_ADDR"))
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\nusage: zipfelkasse [serve|healthcheck]\n", cmd)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "zipfelkasse:", err)
		os.Exit(1)
	}
}

// app is the fully wired application.
type app struct {
	handler   http.Handler
	fx        *fx.Service
	recurring *recurring.Service
	ynab      *ynab.Service
}

// newApp builds Deps, all services and the handler: the browser app behind
// web.Wrap and, beside it, the MCP endpoint.
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
	d.FX = fxSvc // from here on all packages see the rate service

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

	// MCP stays outside web.Wrap: it is no browser page (no person to pick, no
	// CSRF protection – it rejects any Origin header itself) and checks its own
	// body limit. It keeps only the security headers. Nothing below /mcp/
	// reaches the browser app, so web never logs the secret in the path.
	mcpMux := http.NewServeMux()
	if err := mcp.Register(mcpMux, d); err != nil {
		return nil, fmt.Errorf("mcp: %w", err)
	}
	root := http.NewServeMux()
	root.Handle("/mcp/", web.SecurityHeaders(mcpMux))
	root.Handle("/", web.Wrap(d, mux))
	return &app{handler: root, fx: fxSvc, recurring: rec, ynab: yn}, nil
}

func serve() error {
	cfg, err := config.FromEnv(os.Getenv)
	if err != nil {
		return err
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	st, err := store.Open(cfg.DBPath)
	if err != nil {
		return fmt.Errorf("database %s: %w", cfg.DBPath, err)
	}
	defer st.Close()
	if cfg.Now != nil {
		st.SetClock(cfg.Now)
	}
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
	log.Info("Zipfelkasse running", "addr", cfg.Addr, "db", cfg.DBPath, "tz", cfg.Location.String())

	select {
	case err = <-errc:
	case <-ctx.Done():
		log.Info("shutting down")
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

// backupLoop writes a backup every night at 03:00 (local time) and keeps
// the last backupKeep.
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
			log.Error("backup failed", "err", err)
			continue
		}
		log.Info("backup written", "path", path)
	}
}

// nextBackup returns the next 03:00 after now (in now's zone).
func nextBackup(now time.Time) time.Time {
	t := time.Date(now.Year(), now.Month(), now.Day(), 3, 0, 0, 0, now.Location())
	if !t.After(now) {
		t = time.Date(now.Year(), now.Month(), now.Day()+1, 3, 0, 0, 0, now.Location())
	}
	return t
}

// healthcheck calls GET /healthz on the local port.
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
		return "", fmt.Errorf("ZIPFELKASSE_ADDR %q: %w", addr, err)
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	return "http://" + net.JoinHostPort(host, port) + "/healthz", nil
}
