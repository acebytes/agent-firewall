#!/usr/bin/env bash
# run.sh — one-command bootstrap for the UserLayerDesktop PreToolUse
# enforcement experiment harness.
#
# Prerequisites on the host:
#   • Docker Desktop (or any Docker engine ≥ 20.10)
#   • .env file with ANTHROPIC_API_KEY=... (copy .env.example)
#
# Usage:
#   ./run.sh                 # build image + run all 12 experiments
#   ./run.sh shell           # build image + drop into interactive shell
#   ./run.sh rebuild         # force a no-cache rebuild, then run harness
#   ./run.sh clean           # remove image + results/ contents
#
# Results are written to ./results/ on the host (bind-mounted into the
# container at /home/tester/harness/results). Each experiment produces
# <name>.log; run-experiments.sh also writes summary.txt and
# enforcer.log.

set -euo pipefail

cd "$(dirname "$0")"

IMAGE="ul-experiments"
ENV_FILE=".env"
RESULTS_DIR="$PWD/results"

# ── colours ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'
  YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""
fi

log()  { printf '%s▶%s %s\n' "$BLU" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s✗%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }

# ── preflight ───────────────────────────────────────────────────────────
preflight() {
  command -v docker >/dev/null 2>&1 || die "docker not found — install Docker Desktop first"
  docker info >/dev/null 2>&1       || die "docker daemon not responding — is Docker Desktop running?"

  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f .env.example ]]; then
      warn "no $ENV_FILE found — copying .env.example → $ENV_FILE"
      cp .env.example "$ENV_FILE"
    else
      die "no $ENV_FILE and no .env.example to seed from"
    fi
    die "edit $ENV_FILE and set ANTHROPIC_API_KEY, then re-run ./run.sh"
  fi

  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
  if [[ -z "${ANTHROPIC_API_KEY:-}" ]] || [[ "$ANTHROPIC_API_KEY" == sk-ant-... ]] \
     || [[ "$ANTHROPIC_API_KEY" == your_key_here ]]; then
    die "ANTHROPIC_API_KEY is unset or still a placeholder in $ENV_FILE"
  fi

  mkdir -p "$RESULTS_DIR"
}

# Compute a content hash of all source directories that land in the image
# via COPY. Passed to Dockerfile as --build-arg SRC_HASH=..., where ARG-
# consuming RUN layers force cache invalidation when content changes.
#
# Why: Docker Desktop on macOS (VirtioFS + BuildKit) intermittently fails
# to detect file changes under COPY dirs, so `./run.sh exp16` could start
# a container whose harness/ was missing newly-added files (like
# rerun-exp16.sh) while `./run.sh rebuild` (--no-cache) always worked.
# This hash makes cache invalidation deterministic and cheap: unchanged
# sources hit cache, any edit busts exactly the affected stage.
compute_src_hash() {
  # Include every source dir that the Dockerfile COPYs into the image.
  # -print0 + sort -z keeps ordering stable across filesystems so a clean
  # checkout and a working copy with no edits produce identical hashes.
  find ul-hook mock-enforcer harness -type f \
       \( -name '*.go' -o -name '*.mod' -o -name '*.sum' \
          -o -name '*.sh' -o -name '*.json' -o -name '*.py' \) \
       -print0 2>/dev/null \
    | sort -z \
    | xargs -0 sha256sum 2>/dev/null \
    | sha256sum \
    | cut -c1-16
}

# ── commands ────────────────────────────────────────────────────────────
cmd_build() {
  local args=()
  [[ "${1:-}" == "--no-cache" ]] && args+=(--no-cache)
  local src_hash
  src_hash="$(compute_src_hash)"
  args+=(--build-arg "SRC_HASH=${src_hash}")
  log "docker build ${args[*]} -t $IMAGE ."
  docker build ${args[@]+"${args[@]}"} -t "$IMAGE" .
  ok "image built: $IMAGE (src_hash=${src_hash})"
}

cmd_run_harness() {
  log "docker run → harness (results → $RESULTS_DIR)"
  docker run --rm \
    --env-file "$ENV_FILE" \
    -v "$RESULTS_DIR":/home/tester/harness/results \
    "$IMAGE"
}

cmd_shell() {
  log "docker run → interactive shell"
  docker run --rm -it \
    --env-file "$ENV_FILE" \
    -v "$RESULTS_DIR":/home/tester/harness/results \
    "$IMAGE" \
    /bin/bash -l
}

# Run ONLY experiment-16 (the 500-trial fuzzer). Same image as the full
# harness but entrypoints into rerun-exp16.sh. Useful when iterating on the
# fuzzer or the enforcer NDJSON sink without paying the ~5-minute cost of
# experiments 01–15.
cmd_run_exp16() {
  log "docker run → experiment-16 only (results → $RESULTS_DIR)"
  docker run --rm \
    --env-file "$ENV_FILE" \
    -v "$RESULTS_DIR":/home/tester/harness/results \
    --entrypoint /bin/bash \
    "$IMAGE" \
    -lc 'cd ~/harness && bash harness/rerun-exp16.sh'
}

# Run any ONE experiment by 2-digit number (e.g. 02, 03, 13). Dispatches to
# harness/rerun-exp.sh inside the container. Critical: rerun-exp.sh prints
# `claude --version` so silent CLI bumps (e.g. timeout fail-open vs
# fail-closed in exp-03) can't hide inside a green-looking image.
cmd_run_exp() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]{2}$ ]] || die "usage: ./run.sh exp <NN>  (e.g. ./run.sh exp 02)"
  log "docker run → experiment-$n only (results → $RESULTS_DIR)"
  docker run --rm \
    --env-file "$ENV_FILE" \
    -v "$RESULTS_DIR":/home/tester/harness/results \
    --entrypoint /bin/bash \
    "$IMAGE" \
    -lc "cd ~/harness && bash harness/rerun-exp.sh $n"
}

cmd_clean() {
  log "removing image $IMAGE (if present)"
  docker image rm "$IMAGE" 2>/dev/null || true
  log "wiping $RESULTS_DIR/*"
  rm -rf "$RESULTS_DIR"/*
  ok "clean"
}

# Doctor — pre-flight diagnostic that fails LOUD and EARLY when something
# would otherwise manifest as an opaque "No such file" inside the
# container after a successful build.
#
# This OSS copy uses the NESTED harness layout (Dockerfile does
# `COPY harness/ /home/tester/harness/` where the host `harness/`
# directory itself contains a `harness/` subdirectory). So a reference
# to `~/harness/harness/rerun-exp.sh` inside the container corresponds
# to `harness/harness/rerun-exp.sh` on the host, and that's what the
# lint below checks.
cmd_doctor() {
  local issues=0
  log "doctor — pre-flight diagnostics"

  # 1. Docker daemon
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "docker daemon responsive"
  else
    warn "docker not found or daemon down"; issues=$((issues+1))
  fi

  # 2. .env exists and has a non-placeholder API key
  if [[ -f "$ENV_FILE" ]]; then
    local key
    key=$(set -a; . "$ENV_FILE" 2>/dev/null; set +a; printf '%s' "${ANTHROPIC_API_KEY:-}")
    if [[ -z "$key" ]] || [[ "$key" == sk-ant-... ]] || [[ "$key" == your_key_here ]]; then
      warn ".env present but ANTHROPIC_API_KEY is unset/placeholder"; issues=$((issues+1))
    else
      ok ".env present, ANTHROPIC_API_KEY non-empty"
    fi
  else
    warn "$ENV_FILE missing (copy from .env.example)"; issues=$((issues+1))
  fi

  # 3. Source dirs — parse Dockerfile's COPY sources so we tolerate
  # the ongoing OSS restructure (ul-hook/ vs shim/ul-hook/, etc.)
  local d
  if [[ -r Dockerfile ]]; then
    # Extract each local COPY source (skip --from=stage lines).
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      local src="${d%/}"
      if [[ -d "$src" ]] && [[ -n "$(find "$src" -type f -print -quit 2>/dev/null)" ]]; then
        ok "source dir present: $src/"
      else
        warn "missing or empty source dir referenced by Dockerfile: $src/"
        issues=$((issues+1))
      fi
    done < <(grep -E '^COPY[[:space:]]+[^-]' Dockerfile | awk '{print $2}')
  fi

  # 4. Required harness scripts (NESTED layout: harness/harness/*)
  local req
  for req in harness/harness/run-experiments.sh \
             harness/harness/rerun-exp.sh \
             harness/harness/rerun-exp16.sh \
             harness/harness/_core.sh; do
    if [[ -r "$req" ]]; then
      ok "harness script present: $req"
    else
      warn "missing harness script: $req"; issues=$((issues+1))
    fi
  done

  # 5. Lint: Dockerfile COPY source vs. run.sh -lc command paths.
  # Nested-layout invariant: `cd ~/harness && bash harness/<X>.sh`
  # (container) should resolve to `harness/harness/<X>.sh` on host.
  if [[ -r Dockerfile ]] && [[ -r run.sh ]]; then
    local bad=0 lc_lines
    lc_lines=$(grep -E '^\s*-lc ' run.sh 2>/dev/null || true)
    while IFS= read -r ln; do
      [[ -z "$ln" ]] && continue
      # Extract the `harness/<name>.sh` fragment from `cd ~/harness && bash harness/<name>.sh...`
      local frag
      frag=$(printf '%s' "$ln" | grep -oE 'harness/[A-Za-z0-9_.-]+\.sh' | head -1)
      [[ -z "$frag" ]] && continue
      local hostp="harness/$frag"   # nested: host sees harness/harness/<name>.sh
      if [[ ! -r "$hostp" ]]; then
        warn "run.sh references container path harness/$frag but host file $hostp missing"
        bad=$((bad+1))
      fi
    done <<< "$lc_lines"
    [[ $bad -eq 0 ]] && ok "Dockerfile COPY ↔ run.sh -lc paths agree (nested layout)"
    issues=$((issues+bad))
  fi

  # 6. _core.sh API surface ↔ experiment imports. Any helper function an
  # experiment calls MUST be defined in _core.sh. Catches signature drift:
  # a renamed helper in _core.sh vs. a stale call in experiment-*.sh.
  # Helpers follow the fixed prefix convention: ndjson_*, check_*, tap_*,
  # since_ts_utc.
  local CORE="harness/harness/_core.sh"
  local EXP_GLOB="harness/harness/experiment-*.sh"
  if [[ -r "$CORE" ]]; then
    local defined_fns used_fns missing=0
    defined_fns=$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$CORE" \
                 | sed 's/()$//' | sort -u)
    # Function CALLS in experiment scripts — not variable refs or
    # assignments. awk filter: emit the identifier only if it appears in
    # command position. We exclude:
    #   1. `local <name>=`, `declare <name>=`, or bare `<name>=` (assignment)
    #   2. `$<name>` or `${<name>` (variable reference)
    #   3. `<name>[` (array indexing)
    # Limited to our prefix convention so common builtins aren't tested.
    # shellcheck disable=SC2086
    used_fns=$(awk '
      {
        # Strip comments starting at # (outside of strings — approximation).
        sub(/[[:space:]]+#.*/, "")
        line = $0
        while (match(line, /(ndjson_[a-z_]+|check_[a-z_]+|tap_[a-z_]+|since_ts_utc)/)) {
          name = substr(line, RSTART, RLENGTH)
          pre  = (RSTART > 1) ? substr(line, RSTART-1, 1) : ""
          post = (RSTART+RLENGTH <= length(line)) ? substr(line, RSTART+RLENGTH, 1) : ""
          # Skip: variable ref ($name, ${name), array (name[), assignment (name=),
          # or embedded inside an identifier continuation (preceded by letter).
          if (pre != "$" && pre != "{" && pre !~ /[A-Za-z0-9_]/ \
              && post != "=" && post != "[" ) {
            print name
          }
          line = substr(line, RSTART+RLENGTH)
        }
      }' $EXP_GLOB 2>/dev/null | sort -u)
    while IFS= read -r fn; do
      [[ -z "$fn" ]] && continue
      if ! grep -qxF "$fn" <<< "$defined_fns"; then
        warn "experiment scripts call '$fn' but it's not defined in $CORE"
        missing=$((missing+1))
      fi
    done <<< "$used_fns"
    [[ $missing -eq 0 ]] && ok "_core.sh API surface matches experiment imports"
    issues=$((issues+missing))
  fi

  echo
  if [[ $issues -eq 0 ]]; then
    ok "doctor: all checks passed — safe to run ./run.sh exp <NN>"
  else
    warn "doctor: $issues issue(s) found — fix before running experiments"
    return 1
  fi
}

# ── dispatch ────────────────────────────────────────────────────────────
mode="${1:-run}"
case "$mode" in
  run)      preflight; cmd_build;             cmd_run_harness ;;
  rebuild)  preflight; cmd_build --no-cache;  cmd_run_harness ;;
  shell)    preflight; cmd_build;             cmd_shell ;;
  exp16)    preflight; cmd_build;             cmd_run_exp16 ;;
  exp)      preflight; cmd_build;             cmd_run_exp "${2:-}" ;;
  build)    preflight; cmd_build ;;
  clean)    cmd_clean ;;
  doctor)   cmd_doctor ;;
  -h|--help|help)
    cat <<EOF
${BOLD}run.sh${RST} — UserLayerDesktop enforcement experiment harness

  ${BOLD}./run.sh${RST}            build + run all 12 experiments
  ${BOLD}./run.sh rebuild${RST}    force no-cache rebuild, then run
  ${BOLD}./run.sh shell${RST}      build + interactive shell in container
  ${BOLD}./run.sh exp16${RST}      build + run ONLY experiment-16 (fuzzer)
  ${BOLD}./run.sh exp <NN>${RST}   build + run ONLY experiment-NN (e.g. ${DIM}exp 02${RST})
  ${BOLD}./run.sh build${RST}      build image only
  ${BOLD}./run.sh clean${RST}      remove image + empty results/
  ${BOLD}./run.sh doctor${RST}     pre-flight diagnostics (paths, .env, Dockerfile lint)

Edit ${BOLD}.env${RST} (copy from ${DIM}.env.example${RST}) to set ANTHROPIC_API_KEY.
Results land in ${BOLD}./results/${RST}.
EOF
    ;;
  *) die "unknown mode: $mode (try: run, rebuild, shell, exp16, exp <NN>, build, clean, doctor, help)" ;;
esac
