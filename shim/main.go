// ul-hook — UserLayerDesktop guardrail shim for Claude Code's PreToolUse hook.
//
// Registered in ~/.claude/settings.json (or managed-settings.json) as a command-type
// hook. Claude Code invokes it per tool call, passing a JSON payload on stdin.
//
// The shim:
//   1. Reads the PreToolUse payload from stdin.
//   2. Translates it into the canonical HookRequest schema.
//   3. Opens a connection to the enforcer (Unix socket by default, XPC via
//      sidecar when UL_XPC=1 on Darwin).
//   4. Sends the request, reads the HookVerdict.
//   5. Translates the verdict into the hook-output format:
//         - decision=allow  → exit 0 with JSON on stdout
//         - decision=deny   → exit 2 with reason on stderr
//         - decision=ask    → exit 0 with ask JSON on stdout
//         - decision=defer  → exit 0 with defer JSON on stdout
//
// Fails closed on any error path (exit 2). Never exits 1 — Claude Code treats
// exit 1 as non-blocking, which would silently allow calls when the shim
// can't reach the enforcer.
//
// Wire protocol: see docs/specs/enforcer-ipc-protocol-spec.md (proto=1).
// Shim contract:  see docs/specs/ul-hook-shim-spec.md.
//
// License: MIT. Copyright (c) 2026 UserLayer.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	protoVersion   = 1
	defaultTimeout = 9 * time.Second
	maxPayloadSize = 1 << 20 // 1 MiB
	shimVersion    = "1.0.0"
)

// ──────────────────────────────────────────────────────────────────────────
//  Wire types — must stay in sync with enforcer-ipc-protocol-spec.md
// ──────────────────────────────────────────────────────────────────────────

type hookRequest struct {
	Proto          int            `json:"proto"`
	Origin         string         `json:"origin"`
	OriginVersion  string         `json:"originVersion,omitempty"`
	Event          string         `json:"event"`
	SessionID      string         `json:"sessionID"`
	ToolUseID      string         `json:"toolUseID,omitempty"`
	Cwd            string         `json:"cwd"`
	PermissionMode string         `json:"permissionMode,omitempty"`
	ProjectDir     string         `json:"projectDir,omitempty"`
	TranscriptPath string         `json:"transcriptPath,omitempty"`
	CapHint        string         `json:"capHint,omitempty"`
	ToolName       string         `json:"toolName"`
	ToolInput      map[string]any `json:"toolInput"`
	UserID         int            `json:"userID,omitempty"`
	AgentID        string         `json:"agentID,omitempty"`
	AgentType      string         `json:"agentType,omitempty"`
	ShimVersion    string         `json:"shimVersion,omitempty"`
}

type hookVerdict struct {
	Proto             int             `json:"proto"`
	Decision          string          `json:"decision"`
	Reason            string          `json:"reason"`
	UpdatedInput      json.RawMessage `json:"updatedInput,omitempty"`
	AdditionalContext string          `json:"additionalContext,omitempty"`
	ApprovalSessionID string          `json:"approvalSessionID,omitempty"`
	CapID             string          `json:"capID,omitempty"`
	RuleID            string          `json:"ruleID,omitempty"`
	LatencyMS         int             `json:"latencyMS,omitempty"`
	AuditID           string          `json:"auditID,omitempty"`
	TTLSeconds        int             `json:"ttlSeconds,omitempty"`
}

// Claude Code's PreToolUse hook input shape (adapter input).
type ccHookInput struct {
	SessionID      string         `json:"session_id"`
	TranscriptPath string         `json:"transcript_path"`
	Cwd            string         `json:"cwd"`
	PermissionMode string         `json:"permission_mode"`
	HookEventName  string         `json:"hook_event_name"`
	ToolName       string         `json:"tool_name"`
	ToolInput      map[string]any `json:"tool_input"`
	ToolUseID      string         `json:"tool_use_id"`
	AgentID        string         `json:"agent_id,omitempty"`
	AgentType      string         `json:"agent_type,omitempty"`
}

// Claude Code's hook-output JSON (response to stdout on allow/ask/defer).
type ccHookOutput struct {
	HookSpecificOutput struct {
		HookEventName            string          `json:"hookEventName"`
		PermissionDecision       string          `json:"permissionDecision"`
		PermissionDecisionReason string          `json:"permissionDecisionReason,omitempty"`
		UpdatedInput             json.RawMessage `json:"updatedInput,omitempty"`
		AdditionalContext        string          `json:"additionalContext,omitempty"`
	} `json:"hookSpecificOutput"`
	Continue       bool `json:"continue"`
	SuppressOutput bool `json:"suppressOutput,omitempty"`
}

// ──────────────────────────────────────────────────────────────────────────
//  CLI
// ──────────────────────────────────────────────────────────────────────────

func main() {
	var (
		version    bool
		dryRun     bool
		socketPath string
		xpcService string
		adapter    string
		timeoutMS  int
	)

	flag.BoolVar(&version, "version", false, "print version and exit")
	flag.BoolVar(&dryRun, "dry-run", false, "print the HookRequest JSON and exit 0")
	flag.StringVar(&socketPath, "socket", "", "override Unix socket path (default UL_SOCKET or ~/.userlayer/sockets/enforcer.sock)")
	flag.StringVar(&xpcService, "xpc", "", "use XPC transport via sidecar with given Mach service name (Darwin only)")
	flag.StringVar(&adapter, "adapter", "claude-code", "upstream payload adapter")
	flag.IntVar(&timeoutMS, "timeout", 0, "override IPC timeout in ms (default 9000 or UL_TIMEOUT_MS)")
	flag.Parse()

	if version {
		fmt.Printf("ul-hook %s (proto=%d)\n", shimVersion, protoVersion)
		os.Exit(0)
	}

	timeout := defaultTimeout
	if timeoutMS > 0 {
		timeout = time.Duration(timeoutMS) * time.Millisecond
	} else if env := os.Getenv("UL_TIMEOUT_MS"); env != "" {
		if ms, err := parseInt(env); err == nil && ms > 0 {
			timeout = time.Duration(ms) * time.Millisecond
		}
	}

	payload, err := readStdinCapped(maxPayloadSize)
	if err != nil {
		die("stdin read: " + err.Error())
	}
	if len(payload) == 0 {
		die("empty stdin")
	}

	req, err := adapt(adapter, payload)
	if err != nil {
		die("adapter: " + err.Error())
	}

	if dryRun {
		out, _ := json.MarshalIndent(req, "", "  ")
		fmt.Println(string(out))
		os.Exit(0)
	}

	verdict, err := send(req, socketPath, xpcService, timeout)
	if err != nil {
		die("ipc: " + err.Error())
	}

	emit(verdict)
}

// ──────────────────────────────────────────────────────────────────────────
//  Adapters
// ──────────────────────────────────────────────────────────────────────────

func adapt(name string, raw []byte) (hookRequest, error) {
	switch name {
	case "claude-code":
		return adaptClaudeCode(raw)
	case "codex":
		return adaptCodex(raw)
	case "aider":
		return adaptAider(raw)
	default:
		return hookRequest{}, fmt.Errorf("unknown adapter %q", name)
	}
}

func adaptClaudeCode(raw []byte) (hookRequest, error) {
	var in ccHookInput
	if err := json.Unmarshal(raw, &in); err != nil {
		return hookRequest{}, fmt.Errorf("claude-code decode: %w", err)
	}
	if in.ToolName == "" {
		return hookRequest{}, errors.New("claude-code: missing tool_name")
	}
	return hookRequest{
		Proto:          protoVersion,
		Origin:         "claude-code",
		Event:          nonempty(in.HookEventName, "PreToolUse"),
		SessionID:      in.SessionID,
		ToolUseID:      in.ToolUseID,
		Cwd:            in.Cwd,
		PermissionMode: in.PermissionMode,
		ProjectDir:     os.Getenv("CLAUDE_PROJECT_DIR"),
		TranscriptPath: in.TranscriptPath,
		CapHint:        os.Getenv("UL_ACTIVE_CAP"),
		ToolName:       in.ToolName,
		ToolInput:      in.ToolInput,
		UserID:         os.Getuid(),
		AgentID:        in.AgentID,
		AgentType:      in.AgentType,
		ShimVersion:    shimVersion,
	}, nil
}

func adaptCodex(raw []byte) (hookRequest, error) {
	return hookRequest{}, errors.New("codex adapter not yet implemented")
}

func adaptAider(raw []byte) (hookRequest, error) {
	return hookRequest{}, errors.New("aider adapter not yet implemented")
}

// ──────────────────────────────────────────────────────────────────────────
//  Transport
// ──────────────────────────────────────────────────────────────────────────

func send(req hookRequest, socketPath, xpcService string, timeout time.Duration) (hookVerdict, error) {
	if xpcService != "" || os.Getenv("UL_XPC") == "1" {
		if runtime.GOOS != "darwin" {
			return hookVerdict{}, errors.New("XPC transport requires macOS")
		}
		return sendXPC(req, resolveXPCService(xpcService), timeout)
	}
	return sendUnix(req, resolveSocketPath(socketPath), timeout)
}

func resolveSocketPath(override string) string {
	if override != "" {
		return override
	}
	if env := os.Getenv("UL_SOCKET"); env != "" {
		return env
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".userlayer", "sockets", "enforcer.sock")
}

func resolveXPCService(override string) string {
	if override != "" {
		return override
	}
	if env := os.Getenv("UL_XPC_SERVICE"); env != "" {
		return env
	}
	return "ai.userlayer.enforcer"
}

func sendUnix(req hookRequest, path string, timeout time.Duration) (hookVerdict, error) {
	if err := checkSocketPerms(path); err != nil {
		return hookVerdict{}, err
	}

	conn, err := net.DialTimeout("unix", path, 500*time.Millisecond)
	if err != nil {
		return hookVerdict{}, fmt.Errorf("dial %s: %w", path, err)
	}
	defer conn.Close()

	deadline := time.Now().Add(timeout)
	_ = conn.SetDeadline(deadline)

	reqBytes, err := json.Marshal(req)
	if err != nil {
		return hookVerdict{}, fmt.Errorf("encode request: %w", err)
	}
	reqBytes = append(reqBytes, '\n')

	if _, err := conn.Write(reqBytes); err != nil {
		return hookVerdict{}, fmt.Errorf("write: %w", err)
	}

	br := bufio.NewReaderSize(conn, 256<<10)
	line, err := br.ReadBytes('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return hookVerdict{}, fmt.Errorf("read: %w", err)
	}
	if len(line) == 0 {
		return hookVerdict{}, errors.New("empty verdict from enforcer")
	}

	var v hookVerdict
	if err := json.Unmarshal(line, &v); err != nil {
		return hookVerdict{}, fmt.Errorf("decode verdict: %w", err)
	}
	if v.Proto != protoVersion && v.Proto != 0 {
		return hookVerdict{}, fmt.Errorf("enforcer proto %d unsupported (shim expects %d)", v.Proto, protoVersion)
	}
	return v, nil
}

func sendXPC(req hookRequest, service string, timeout time.Duration) (hookVerdict, error) {
	bridge := findBridge()
	if bridge == "" {
		return hookVerdict{}, errors.New("ul-xpc-bridge not found alongside ul-hook")
	}

	reqBytes, err := json.Marshal(req)
	if err != nil {
		return hookVerdict{}, fmt.Errorf("encode: %w", err)
	}

	cmd := exec.Command(bridge, "--service", service, "--timeout-ms", fmt.Sprintf("%d", timeout.Milliseconds()))
	cmd.Stdin = strings.NewReader(string(reqBytes) + "\n")
	var out strings.Builder
	var errBuf strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		return hookVerdict{}, fmt.Errorf("bridge failed: %s: %w", strings.TrimSpace(errBuf.String()), err)
	}
	var v hookVerdict
	if err := json.Unmarshal([]byte(strings.TrimSpace(out.String())), &v); err != nil {
		return hookVerdict{}, fmt.Errorf("decode bridge output: %w", err)
	}
	return v, nil
}

func findBridge() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	dir := filepath.Dir(exe)
	candidate := filepath.Join(dir, "ul-xpc-bridge")
	if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
		return candidate
	}
	if p, err := exec.LookPath("ul-xpc-bridge"); err == nil {
		return p
	}
	return ""
}

// ──────────────────────────────────────────────────────────────────────────
//  Output
// ──────────────────────────────────────────────────────────────────────────

func emit(v hookVerdict) {
	switch v.Decision {
	case "allow":
		writeStdout(buildHookOutput("allow", v))
		os.Exit(0)
	case "deny":
		if v.Reason != "" {
			fmt.Fprintln(os.Stderr, v.Reason)
		} else {
			fmt.Fprintln(os.Stderr, "blocked by UserLayerDesktop")
		}
		os.Exit(2)
	case "ask":
		writeStdout(buildHookOutput("ask", v))
		os.Exit(0)
	case "defer":
		out := buildHookOutput("defer", v)
		out.Continue = false
		writeStdout(out)
		os.Exit(0)
	default:
		die("unknown decision: " + v.Decision)
	}
}

func buildHookOutput(decision string, v hookVerdict) ccHookOutput {
	var out ccHookOutput
	out.HookSpecificOutput.HookEventName = "PreToolUse"
	out.HookSpecificOutput.PermissionDecision = decision
	out.HookSpecificOutput.PermissionDecisionReason = v.Reason
	if len(v.UpdatedInput) > 0 {
		out.HookSpecificOutput.UpdatedInput = v.UpdatedInput
	}
	out.HookSpecificOutput.AdditionalContext = v.AdditionalContext
	out.Continue = true
	return out
}

func writeStdout(out ccHookOutput) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(out); err != nil {
		die("emit output: " + err.Error())
	}
}

// ──────────────────────────────────────────────────────────────────────────
//  Helpers
// ──────────────────────────────────────────────────────────────────────────

func readStdinCapped(max int) ([]byte, error) {
	lr := io.LimitReader(os.Stdin, int64(max+1))
	data, err := io.ReadAll(lr)
	if err != nil {
		return nil, err
	}
	if len(data) > max {
		return nil, fmt.Errorf("payload exceeds %d bytes", max)
	}
	return data, nil
}

func parseInt(s string) (int, error) {
	var n int
	_, err := fmt.Sscanf(s, "%d", &n)
	return n, err
}

func nonempty(a, fallback string) string {
	if a == "" {
		return fallback
	}
	return a
}

func die(msg string) {
	fmt.Fprintln(os.Stderr, "ul-hook: "+msg)
	os.Exit(2)
}
