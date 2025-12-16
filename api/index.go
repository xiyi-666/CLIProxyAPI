package handler

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"sync"

	"github.com/router-for-me/CLIProxyAPI/v6/internal/config"
	"github.com/router-for-me/CLIProxyAPI/v6/sdk/cliproxy"
	log "github.com/sirupsen/logrus"
)

var (
	service *cliproxy.Service
	once    sync.Once
)

// Handler is the entry point for Vercel Serverless Functions.
func Handler(w http.ResponseWriter, r *http.Request) {
	once.Do(func() {
		// Initialize the service only once
		initService()
	})

	if service != nil {
		service.ServeHTTP(w, r)
	} else {
		http.Error(w, "Service initialization failed", http.StatusInternalServerError)
	}
}

func initService() {
	// Set up basic logging
	log.SetFormatter(&log.JSONFormatter{})
	log.SetOutput(os.Stdout)

	// Determine configuration path
	// In Vercel, we might rely on environment variables or a config file included in the build
	wd, _ := os.Getwd()
	configPath := filepath.Join(wd, "config.yaml")
	
	// If config file doesn't exist, try to load from environment variables or use defaults
	// The LoadConfigOptional function handles missing files gracefully if optional is true
	cfg, err := config.LoadConfigOptional(configPath, true)
	if err != nil {
		log.Errorf("Failed to load configuration: %v", err)
		return
	}

	// Ensure we have a valid config object
	if cfg == nil {
		cfg = &config.Config{}
	}

	// Override configuration with environment variables if needed
	// (This is partially handled by LoadConfigOptional but we can add specific overrides here)
	if port := os.Getenv("PORT"); port != "" {
		// Port is usually handled by the platform, but good to have in config
	}

	// Populate config from environment variables if keys are missing
	if key := os.Getenv("GEMINI_API_KEY"); key != "" {
		log.Info("Loading Gemini API Key from environment variable")
		cfg.GeminiKey = append(cfg.GeminiKey, config.GeminiKey{
			APIKey: key,
		})
	}
	if key := os.Getenv("CLAUDE_API_KEY"); key != "" {
		log.Info("Loading Claude API Key from environment variable")
		cfg.ClaudeKey = append(cfg.ClaudeKey, config.ClaudeKey{
			APIKey: key,
		})
	}
	if key := os.Getenv("OPENAI_API_KEY"); key != "" {
		log.Info("Loading OpenAI API Key from environment variable")
		cfg.CodexKey = append(cfg.CodexKey, config.CodexKey{
			APIKey: key,
		})
	}

	// Build the service
	builder := cliproxy.NewBuilder().
		WithConfig(cfg).
		WithConfigPath(configPath)

	svc, err := builder.Build()
	if err != nil {
		log.Errorf("Failed to build service: %v", err)
		return
	}

	// Initialize the service (similar to Run but without blocking server start)
	// We need to manually trigger initialization steps that Run() usually does
	ctx := context.Background()
	
	// Initialize auth directory if needed (might be read-only in serverless)
	// We might need to adjust this for serverless environments where filesystem is read-only
	// For now, we assume /tmp is writable or we use in-memory/env-var based auth
	if cfg.AuthDir == "" {
		cfg.AuthDir = "/tmp/auth"
	}
	
	// Manually initialize components that Run() would handle
	// Note: We can't call Run() because it blocks. We need a way to initialize without blocking.
	// Since cliproxy.Service doesn't expose a non-blocking Init(), we might need to rely on
	// lazy initialization or partial setup.
	// However, looking at cliproxy/service.go, Run() does a lot of setup.
	// For Vercel, we mainly need the server handler.
	
	// We need to perform the setup steps from Run() that are safe for serverless
	// 1. Ensure auth dir
	// 2. Load auth managers
	// 3. Create server instance
	
	if err := svc.Bootstrap(ctx); err != nil {
		log.Errorf("Failed to bootstrap service: %v", err)
		return
	}
	
	service = svc
}