# ──────────────────────────────────────────────────────────────────────────
# Self-contained 12-experiment harness for UserLayerDesktop's PreToolUse
# enforcement PoC. No bind-mounts required: source code is COPY'd in,
# Go binaries are baked at build time, and harness scripts run against
# the pre-built artifacts.
#
# Build + run from the host:
#
#     ./run.sh                 # wraps docker build + docker run
#
# Or manually:
#
#     docker build -t ul-experiments .
#     docker run --rm -it \
#         --env-file .env \
#         -v $PWD/results:/home/tester/harness/results \
#         ul-experiments
#
# Results (logs per experiment + summary) land in ./results/ on the host.
# ──────────────────────────────────────────────────────────────────────────

# ─── stage 1: build Go binaries ───────────────────────────────────────────
FROM golang:1.22-bullseye AS gobuild

WORKDIR /src

# Round-4 cache-miss mitigation.
#
# Docker Desktop on macOS (VirtioFS + BuildKit) sometimes fails to invalidate
# COPY layers when the source directory's content changes on disk. Symptom:
# edits to ul-hook/ or mock-enforcer/ don't show up in the rebuilt image,
# producing stale binaries. `./run.sh rebuild` (--no-cache) worked; normal
# builds silently shipped old code.
#
# Fix: accept a content-hash build arg and consume it in a RUN layer before
# each COPY. When run.sh passes a new hash (computed from find|sha256sum),
# that RUN invalidates and everything after it rebuilds. When unchanged,
# the cache hits normally — no perf penalty on no-op builds.
#
# Hash scope: ul-hook/ + mock-enforcer/ + harness/ all roll into one arg.
ARG SRC_HASH=dev
RUN echo "src_hash=${SRC_HASH}" > /tmp/.src_hash

# ul-hook shim (PreToolUse hook → Unix-socket bridge → enforcer)
# Lives at repo root in shim/ (MOVE-INSTRUCTIONS step 4 expected layout).
COPY shim/ /src/shim/
RUN cd /src/shim \
 && go build -trimpath -ldflags="-s -w" -o /out/ul-hook .

# mock-enforcer (reference policy engine mimicking CapEnforcer)
# Lives at repo root in enforcer/ (MOVE-INSTRUCTIONS step 4 expected layout).
COPY enforcer/ /src/enforcer/
RUN cd /src/enforcer \
 && go build -trimpath -ldflags="-s -w" -o /out/mock-enforcer .

# ─── stage 2: runtime (Node + Claude Code CLI + harness) ─────────────────
FROM node:20-bullseye

# ── system packages ──────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates git jq strace sudo uuid-runtime \
        python3 python3-venv procps psmisc \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code CLI (version pinned via build arg for CI matrix) ─────────
# Override with: docker build --build-arg CLAUDE_CODE_VERSION=2.1.0 .
# Accepts: "latest", a specific version ("2.1.0"), or a dist-tag ("2", "1").
#
# Round-4 note: "latest" is convenient but fragile — a CLI release that
# changes hook semantics (e.g. timeout fail-open → fail-closed) can flip
# harness results silently. run-experiments.sh records `claude --version`
# in results/summary.txt; CI matrix pins explicit versions for cross-version
# regression evidence (see .github/workflows/conformance.yml).
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && claude --version || true

# ── test user with passwordless sudo (needed for experiment 08) ──────────
RUN useradd -m -s /bin/bash tester \
 && echo "tester ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/tester

USER tester
WORKDIR /home/tester

# ── pre-built binaries ───────────────────────────────────────────────────
RUN mkdir -p /home/tester/bin
COPY --from=gobuild --chown=tester:tester /out/ul-hook       /home/tester/bin/ul-hook
COPY --from=gobuild --chown=tester:tester /out/mock-enforcer /home/tester/bin/mock-enforcer
RUN chmod +x /home/tester/bin/*

# ── harness scripts ──────────────────────────────────────────────────────
# Re-declare SRC_HASH in this stage so the cache-bust also works here (ARGs
# don't cross stage boundaries by default). Same value, different layer.
ARG SRC_HASH=dev
RUN echo "stage2_src_hash=${SRC_HASH}" > /tmp/.src_hash
COPY --chown=tester:tester harness/ /home/tester/harness/
RUN chmod +x /home/tester/harness/*.sh

# ── runtime env used by the harness ──────────────────────────────────────
ENV PATH=/home/tester/bin:$PATH \
    UL_SOCKET=/home/tester/.userlayer/sockets/enforcer.sock \
    UL_TIMEOUT_MS=9000 \
    UL_ADAPTER=claude-code

WORKDIR /home/tester/harness

# Default entrypoint runs the full harness; override with `bash -l` for
# interactive debugging.
CMD ["./run-experiments.sh"]
