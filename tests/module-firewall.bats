#!/usr/bin/env bats
# 40-firewall — port defaults and the Docker/ufw bypass detection. See tickets/005.

setup() {
  load helpers/common
  require_userns
  setup_stubs
  SCAN="$BATS_TEST_TMPDIR/scan"
  mkdir -p "$SCAN/app" "$SCAN/deep/nested/app"
}

compose_with() { # compose_with <dir> <ports line>
  mkdir -p "$1"
  cat >"$1/docker-compose.yml" <<EOF
services:
  db:
    image: postgres
    ports:
      - "$2"
EOF
}

# --- port defaults ------------------------------------------------------------

@test "only SSH is opened when EXTRA_PORTS is not set" {
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN"
  [ "$status" -eq 0 ]
  assert_output_matches 'ufw allow 22/tcp'
  assert_output_matches 'extra: none'
  refute_output_matches 'ufw allow 80/tcp'
  refute_output_matches 'ufw allow 443/tcp'
}

@test "EXTRA_PORTS opens exactly what the caller asked for" {
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN" 'EXTRA_PORTS=80/tcp 443/tcp'
  [ "$status" -eq 0 ]
  assert_output_matches 'ufw allow 80/tcp'
  assert_output_matches 'ufw allow 443/tcp'
}

@test "SSH_PORT is honored" {
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN" SSH_PORT=2222
  [ "$status" -eq 0 ]
  assert_output_matches 'ufw allow 2222/tcp'
}

# --- compose scan -------------------------------------------------------------

@test "a non-loopback compose publish is reported" {
  compose_with "$SCAN/app" "0.0.0.0:5432:5432"
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN"
  [ "$status" -eq 0 ]
  assert_output_matches 'publishes a non-loopback port'
  assert_output_matches 'ufw is NOT enforcing'
}

@test "a loopback-bound compose publish is not reported" {
  compose_with "$SCAN/app" "127.0.0.1:5432:5432"
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN"
  [ "$status" -eq 0 ]
  refute_output_matches 'publishes a non-loopback port'
  assert_output_matches 'no non-loopback container publish detected'
}

@test "a bare host:container publish counts as non-loopback" {
  compose_with "$SCAN/app" "8080:8080"
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN"
  assert_output_matches 'publishes a non-loopback port'
}

@test "the scan reaches nested directories and compose.yaml, not just /opt/*" {
  mkdir -p "$SCAN/deep/nested/app"
  cat >"$SCAN/deep/nested/app/compose.yaml" <<'EOF'
services:
  web:
    ports:
      - "0.0.0.0:9000:80"
EOF
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN"
  assert_output_matches 'compose\.yaml publishes a non-loopback port'
}

@test "a compose file deeper than COMPOSE_SCAN_DEPTH is out of reach, as documented" {
  mkdir -p "$SCAN/a/b/c/d/e"
  cat >"$SCAN/a/b/c/d/e/compose.yaml" <<'EOF'
services:
  web:
    ports:
      - "0.0.0.0:9000:80"
EOF
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN"
  refute_output_matches 'publishes a non-loopback port'

  # raising the knob finds it — the limit is a bound, not a blind spot
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN" COMPOSE_SCAN_DEPTH=6
  assert_output_matches 'publishes a non-loopback port'
}

@test "a scan directory that does not exist is skipped without error" {
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN /nope/not/here"
  [ "$status" -eq 0 ]
  refute_output_matches 'No such file'
}

# --- running containers -------------------------------------------------------

@test "a container publishing on 0.0.0.0 is reported with no compose file present" {
  cat >"$STUB_BIN/docker" <<'SH'
#!/bin/bash
case "$1" in
  info) exit 0 ;;
  ps) echo 'web 0.0.0.0:9999->80/tcp' ;;
esac
exit 0
SH
  chmod +x "$STUB_BIN/docker"
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN"
  [ "$status" -eq 0 ]
  assert_output_matches 'running container publishes a non-loopback port: web'
  assert_output_matches 'ufw is NOT enforcing'
}

@test "a container published on loopback only is not reported" {
  cat >"$STUB_BIN/docker" <<'SH'
#!/bin/bash
case "$1" in
  info) exit 0 ;;
  ps) echo 'web 127.0.0.1:9999->80/tcp' ;;
esac
exit 0
SH
  chmod +x "$STUB_BIN/docker"
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN"
  [ "$status" -eq 0 ]
  refute_output_matches 'running container publishes'
}

# --- ufw-docker pinning -------------------------------------------------------

@test "UFW_DOCKER=1 under DRY_RUN names the pinned revision and downloads nothing" {
  stub_recording curl 0
  run run_module 40-firewall "COMPOSE_SCAN_DIRS=$SCAN" UFW_DOCKER=1
  [ "$status" -eq 0 ]
  assert_output_matches 'would fetch ufw-docker'
  assert_output_matches 'verify sha256'
  run stub_calls curl
  [ -z "$output" ]
}
