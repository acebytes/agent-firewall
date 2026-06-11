// mock-enforcer — minimal reference enforcer for ul-hook PoC testing.
//
// Listens on a Unix socket, reads HookRequest payloads from ul-hook,
// evaluates a hardcoded policy mimicking a "firewall.dev-assistant" cap,
// writes back HookVerdict responses. Logs every decision to stderr AND
// (round 3) emits a structured NDJSON audit event to enforcer.ndjson
// for machine-readable regression diffs across experiment rounds.
//
// Not production. Does NOT implement cap inheritance, approval suspension,
// audit persistence, or the full 6-step CapEnforcer chain. Replaces the
// `CapEnforcer.checkProxyPermission()` call in the real UserLayerDesktop
// pipeline with a simple rule table so the round-trip can be validated
// end-to-end in ~200 LOC.
//
// Run:
//
//   go run . [--socket /tmp/enforcer.sock] [--ndjson /path/to/audit.ndjson] [--hang]
//
// --hang: sleep 30s before responding to every request; used by
// experiment-13 to prove the ul-hook internal timer fires before
// Claude Code's outer hook-timeout.
//
// Stop: Ctrl-C.
//
// License: MIT.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

const protoVersion = 1
const ndjsonSchemaVersion = 1

type hookRequest struct {
	Proto          int            `json:"proto"`
	Origin         string         `json:"origin"`
	Event          string         `json:"event"`
	SessionID      string         `json:"sessionID"`
	Cwd            string         `json:"cwd"`
	PermissionMode string         `json:"permissionMode"`
	CapHint        string         `json:"capHint"`
	ToolName       string         `json:"toolName"`
	ToolInput      map[string]any `json:"toolInput"`
}

type hookVerdict struct {
	Proto             int             `json:"proto"`
	Decision          string          `json:"decision"`
	Reason            string          `json:"reason,omitempty"`
	UpdatedInput      json.RawMessage `json:"updatedInput,omitempty"`
	AdditionalContext string          `json:"additionalContext,omitempty"`
	CapID             string          `json:"capID,omitempty"`
	RuleID            string          `json:"ruleID,omitempty"`
	LatencyMS         int             `json:"latencyMS,omitempty"`
	LatencyUS         int64           `json:"latencyUS,omitempty"`
	AuditID           string          `json:"auditID,omitempty"`
}

// auditEvent is the NDJSON record emitted per request.
// Schema frozen at v=1; add fields with omitempty, never remove.
type auditEvent struct {
	V         int    `json:"v"`
	TS        string `json:"ts"`
	SessionID string `json:"session_id"`
	Tool      string `json:"tool"`
	Mode      string `json:"mode,omitempty"`
	Cap       string `json:"cap,omitempty"`
	Summary   string `json:"summary,omitempty"`
	Decision  string `json:"decision"`
	Rule      string `json:"rule,omitempty"`
	LatencyUS int64  `json:"latency_us"`
	AuditID   string `json:"audit_id,omitempty"`
}

type rule struct {
	id              string
	pattern         *regexp.Regexp
	action          string
	reason          string
	contextTemplate string
}

var bashRules = []rule{
	{
		id:      "fs.rm-rf-root",
		pattern: regexp.MustCompile(`(?:^|\s|;|&&|\|\|)rm\s+-[rR][fF]?\s+/(?:\s|$)`),
		action:  "deny",
		reason:  "fs.rm-rf-root: refused destructive filesystem wipe",
	},
	{
		id:              "git.push-force-main",
		pattern:         regexp.MustCompile(`git\s+push[^|;&]*--force(?:\s|$)[^|;&]*\b(main|master|production|release)\b`),
		action:          "deny",
		reason:          "git.push-force-main: --force to protected branch rejected",
		contextTemplate: "Hint: prefer `git push --force-with-lease` and target a feature branch. This cap permits that form.",
	},
	{
		id:              "netsh.curl-pipe-sh",
		pattern:         regexp.MustCompile(`\bcurl\s+[^|]*\|\s*(?:bash|sh|zsh|ksh)\b`),
		action:          "deny",
		reason:          "netsh.curl-pipe-sh: piping curl to shell is forbidden",
		contextTemplate: "Download to a file first, inspect, then run: `curl -o /tmp/foo.sh URL && cat /tmp/foo.sh && bash /tmp/foo.sh`",
	},
	{
		id:      "denial.fork-bomb",
		pattern: regexp.MustCompile(`:\s*\(\s*\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:`),
		action:  "deny",
		reason:  "denial.fork-bomb: refused",
	},
	{
		id:      "meta.rm-claude-settings",
		pattern: regexp.MustCompile(`(?:rm|mv|>\s*)\s+[^;&|]*\.claude/settings(?:\.local)?\.json`),
		action:  "deny",
		reason:  "meta.rm-claude-settings: will not let you disable your own guardrails",
	},
	{
		id:              "obfuscation.base64-eval",
		pattern:         regexp.MustCompile(`\$\(\s*echo\s+[A-Za-z0-9+/=]{40,}\s*\|\s*base64\s+(?:-d|--decode)\s*\)`),
		action:          "ask",
		reason:          "obfuscation.base64-eval: base64-obfuscated command; please confirm",
		contextTemplate: "For transparency, consider sending the decoded command directly.",
	},
}

var pathDenyRe = regexp.MustCompile(`(?i)\.(ssh|aws|gnupg|env|netrc)(?:/|$)|/wp-config\.php$|/managed-settings\.json$|\.claude/settings(?:\.local)?\.json$`)

var blessedAllowlist = map[string]bool{
	"ls": true, "cat": true, "echo": true, "printf": true,
	"pwd": true, "cd": true, "head": true, "tail": true,
	"grep": true, "git": true, "npm": true, "pnpm": true, "node": true, "python": true, "python3": true,
	"make": true, "cargo": true, "go": true, "swift": true, "xcodebuild": true,
	"touch": true, "mkdir": true,
}

// stamp fills latency fields on a verdict from a fixed start time.
func stamp(v *hookVerdict, start time.Time) {
	elapsed := time.Since(start)
	v.LatencyMS = int(elapsed.Milliseconds())
	v.LatencyUS = elapsed.Microseconds()
}

func evaluate(req hookRequest) hookVerdict {
	start := time.Now()
	capID := req.CapHint
	if capID == "" {
		capID = "firewall.dev-assistant"
	}

	base := hookVerdict{
		Proto:   protoVersion,
		CapID:   capID,
		AuditID: fmt.Sprintf("aud_%d", time.Now().UnixNano()),
	}

	switch req.ToolName {
	case "Bash":
		cmd := asString(req.ToolInput["command"])
		for _, r := range bashRules {
			if r.pattern.MatchString(cmd) {
				v := base
				v.Decision = r.action
				v.Reason = r.reason
				v.RuleID = r.id
				if r.contextTemplate != "" {
					v.AdditionalContext = r.contextTemplate
				}
				stamp(&v, start)
				return v
			}
		}
		first := firstArgv(cmd)
		if blessedAllowlist[first] {
			v := base
			v.Decision = "allow"
			v.RuleID = "blessed." + first
			stamp(&v, start)
			return v
		}
		v := base
		v.RuleID = "bash.unknown-argv"
		if req.PermissionMode == "bypassPermissions" {
			v.Decision = "ask"
			v.Reason = fmt.Sprintf("unknown command `%s`; approval required in bypass mode", first)
		} else {
			v.Decision = "allow"
			v.AdditionalContext = fmt.Sprintf("Note: `%s` is not in the blessed list; consider adding it to your cap.", first)
		}
		stamp(&v, start)
		return v

	case "Write", "Edit":
		path := asString(req.ToolInput["file_path"])
		if pathDenyRe.MatchString(path) {
			v := base
			v.Decision = "deny"
			v.Reason = fmt.Sprintf("cap.path-forbidden: %s is protected", path)
			v.RuleID = "cap.path-denylist"
			v.AdditionalContext = "Sensitive paths (.ssh, .aws, .env, wp-config.php, claude settings) are off-limits."
			stamp(&v, start)
			return v
		}
		v := base
		v.Decision = "allow"
		v.RuleID = "path.allowed"
		stamp(&v, start)
		return v

	case "Read":
		path := asString(req.ToolInput["file_path"])
		if pathDenyRe.MatchString(path) {
			v := base
			v.Decision = "deny"
			v.Reason = fmt.Sprintf("cap.read-forbidden: %s", path)
			v.RuleID = "cap.path-denylist"
			stamp(&v, start)
			return v
		}
		v := base
		v.Decision = "allow"
		stamp(&v, start)
		return v

	case "WebFetch", "WebSearch":
		v := base
		v.Decision = "allow"
		v.RuleID = "network.default-allow"
		stamp(&v, start)
		return v

	case "Agent":
		v := base
		v.Decision = "ask"
		v.Reason = "subagent dispatch requires approval"
		stamp(&v, start)
		return v

	default:
		if strings.HasPrefix(req.ToolName, "mcp__") {
			v := base
			v.Decision = "allow"
			v.RuleID = "mcp.passthrough"
			stamp(&v, start)
			return v
		}
		v := base
		v.Decision = "deny"
		v.Reason = fmt.Sprintf("cap.unknown-tool: %s not registered", req.ToolName)
		v.RuleID = "cap.unknown-tool"
		stamp(&v, start)
		return v
	}
}

func asString(v any) string { s, _ := v.(string); return s }

func firstArgv(cmd string) string {
	trim := strings.TrimLeft(cmd, " \t")
	for {
		sp := strings.IndexAny(trim, " \t")
		if sp < 0 {
			return strings.Trim(trim, "\"'`")
		}
		tok := trim[:sp]
		if strings.Contains(tok, "=") && !strings.HasPrefix(tok, "-") {
			trim = strings.TrimLeft(trim[sp:], " \t")
			continue
		}
		tok = filepath.Base(tok)
		tok = strings.TrimPrefix(tok, "./")
		return strings.Trim(tok, "\"'`")
	}
}

// toolSummary builds a short, per-tool payload summary string for logs.
// Bash → cmd=..., Write/Edit/Read → path=..., WebFetch/WebSearch → url=...,
// MCP + Agent → just the tool name. Truncated to 80 chars.
func toolSummary(req hookRequest) string {
	switch req.ToolName {
	case "Bash":
		return "cmd=" + truncate(asString(req.ToolInput["command"]), 80)
	case "Write", "Edit", "Read":
		return "path=" + truncate(asString(req.ToolInput["file_path"]), 80)
	case "WebFetch":
		return "url=" + truncate(asString(req.ToolInput["url"]), 80)
	case "WebSearch":
		return "query=" + truncate(asString(req.ToolInput["query"]), 80)
	default:
		return ""
	}
}

// --- NDJSON audit sink ---
//
// Round-3 hardening: self-healing sink.
//
//   - Remembers path + inode; reopens on missing file or inode mismatch
//     (logrotate-style file replacement, concurrent harness rerun, etc.).
//   - Write errors are logged (never silently dropped) and trigger reopen.
//   - fsync after every successful write for durability — same-run
//     assertion code reads the NDJSON back seconds later.

type auditSink struct {
	mu   sync.Mutex
	w    *os.File
	path string
	ino  uint64
}

func openAuditSink(path string) (*auditSink, error) {
	if path == "" {
		return nil, nil
	}
	s := &auditSink{path: path}
	if err := s.reopenLocked(); err != nil {
		return nil, err
	}
	return s, nil
}

// reopenLocked (re)opens the NDJSON file and records its inode.
func (s *auditSink) reopenLocked() error {
	if s.w != nil {
		_ = s.w.Close()
		s.w = nil
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(s.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	s.w = f
	if st, err := f.Stat(); err == nil {
		if sys, ok := st.Sys().(*syscall.Stat_t); ok {
			s.ino = uint64(sys.Ino)
		}
	}
	return nil
}

// ensureOpenLocked reopens if the fd is missing or the on-disk inode has
// changed. Caller holds s.mu.
func (s *auditSink) ensureOpenLocked() error {
	if s.w == nil {
		return s.reopenLocked()
	}
	st, err := os.Stat(s.path)
	if err != nil {
		return s.reopenLocked()
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	if uint64(sys.Ino) != s.ino {
		return s.reopenLocked()
	}
	return nil
}

func (s *auditSink) emit(req hookRequest, v hookVerdict) {
	if s == nil {
		return
	}
	ev := auditEvent{
		V:         ndjsonSchemaVersion,
		TS:        time.Now().UTC().Format(time.RFC3339Nano),
		SessionID: req.SessionID,
		Tool:      req.ToolName,
		Mode:      req.PermissionMode,
		Cap:       req.CapHint,
		Summary:   toolSummary(req),
		Decision:  v.Decision,
		Rule:      v.RuleID,
		LatencyUS: v.LatencyUS,
		AuditID:   v.AuditID,
	}
	line, err := json.Marshal(ev)
	if err != nil {
		log.Printf("audit-ndjson: marshal failed: %v", err)
		return
	}
	line = append(line, '\n')

	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.ensureOpenLocked(); err != nil {
		log.Printf("audit-ndjson: ensureOpen failed: %v", err)
		return
	}
	if _, err := s.w.Write(line); err != nil {
		log.Printf("audit-ndjson: write failed on ino=%d: %v — reopening", s.ino, err)
		_ = s.w.Close()
		s.w = nil
		if rerr := s.reopenLocked(); rerr != nil {
			log.Printf("audit-ndjson: reopen after write-fail failed: %v", rerr)
			return
		}
		if _, werr := s.w.Write(line); werr != nil {
			log.Printf("audit-ndjson: retry write failed: %v", werr)
			return
		}
	}
	if err := s.w.Sync(); err != nil {
		log.Printf("audit-ndjson: fsync failed: %v", err)
	}
}

// --- server ---

var (
	hangMode bool
	sink     *auditSink
)

func main() {
	var socketPath, ndjsonPath string
	flag.StringVar(&socketPath, "socket", "", "override socket path (default UL_SOCKET or ~/.userlayer/sockets/enforcer.sock)")
	flag.StringVar(&ndjsonPath, "ndjson", "", "NDJSON audit log path (default UL_NDJSON or enforcer.ndjson next to socket)")
	flag.BoolVar(&hangMode, "hang", false, "sleep 30s before responding (experiment-13 timeout regression test)")
	flag.Parse()

	if socketPath == "" {
		if env := os.Getenv("UL_SOCKET"); env != "" {
			socketPath = env
		} else {
			home, _ := os.UserHomeDir()
			socketPath = filepath.Join(home, ".userlayer", "sockets", "enforcer.sock")
		}
	}
	if ndjsonPath == "" {
		if env := os.Getenv("UL_NDJSON"); env != "" {
			ndjsonPath = env
		} else {
			ndjsonPath = filepath.Join(filepath.Dir(socketPath), "enforcer.ndjson")
		}
	}

	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		log.Fatalf("mkdir: %v", err)
	}
	_ = os.Remove(socketPath)

	var err error
	sink, err = openAuditSink(ndjsonPath)
	if err != nil {
		log.Fatalf("audit-ndjson open: %v", err)
	}
	if sink != nil {
		log.Printf("NDJSON audit → %s", ndjsonPath)
	}

	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	if err := os.Chmod(socketPath, 0o600); err != nil {
		log.Fatalf("chmod: %v", err)
	}
	log.Printf("mock-enforcer listening on %s (hang=%v)", socketPath, hangMode)

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		log.Println("shutting down")
		ln.Close()
		_ = os.Remove(socketPath)
		os.Exit(0)
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if strings.Contains(err.Error(), "use of closed") {
				return
			}
			log.Printf("accept: %v", err)
			continue
		}
		go handle(conn)
	}
}

func handle(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(60 * time.Second))
	br := bufio.NewReaderSize(conn, 1<<20)
	line, err := br.ReadBytes('\n')
	if err != nil {
		log.Printf("read: %v", err)
		return
	}
	var req hookRequest
	if err := json.Unmarshal(line, &req); err != nil {
		log.Printf("decode: %v", err)
		writeDeny(conn, "decode: "+err.Error())
		return
	}

	// experiment-13 support: sleep BEFORE evaluate so the outer
	// Claude Code timer (typically 10s) fires in parallel with the
	// ul-hook internal timer (UL_TIMEOUT_MS=9000 by default).
	if hangMode {
		time.Sleep(30 * time.Second)
	}

	v := evaluate(req)
	out, _ := json.Marshal(v)
	out = append(out, '\n')
	if _, err := conn.Write(out); err != nil {
		log.Printf("write: %v", err)
		return
	}

	log.Printf("[%s] tool=%s mode=%s cap=%s %s → %s (%s, %dµs)",
		req.SessionID, req.ToolName, req.PermissionMode, req.CapHint,
		toolSummary(req), v.Decision, v.RuleID, v.LatencyUS)

	sink.emit(req, v)
}

func writeDeny(conn net.Conn, reason string) {
	v := hookVerdict{Proto: protoVersion, Decision: "deny", Reason: reason, RuleID: "system.protocol"}
	out, _ := json.Marshal(v)
	out = append(out, '\n')
	_, _ = conn.Write(out)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
