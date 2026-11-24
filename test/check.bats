#!/usr/bin/env bats

setup() {
  export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
  export FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures"
  export CHART_PATH="unused"
  export NAMESPACE="testns"
  export KUBECTL_APPLY_INPUT_FILE="$BATS_TEST_TMPDIR/kubectl-apply-input.yaml"
  cd "$BATS_TEST_TMPDIR"
}

@test "dry-run disabled stops after lint/template, never calls kubectl" {
  export DRY_RUN=false
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run disabled"* ]]
  [ ! -f "$KUBECTL_APPLY_INPUT_FILE" ]
}

@test "filters the cluster-scoped Namespace object out before the dry-run" {
  export DRY_RUN=true
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [ -f "$KUBECTL_APPLY_INPUT_FILE" ]
  ! grep -q '^kind: Namespace$' "$KUBECTL_APPLY_INPUT_FILE"
}

@test "keeps non-Namespace resources in the dry-run input" {
  export DRY_RUN=true
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  grep -q '^kind: ServiceAccount$' "$KUBECTL_APPLY_INPUT_FILE"
  grep -q '^kind: Deployment$' "$KUBECTL_APPLY_INPUT_FILE"
}

@test "filters cluster-scoped ClusterRole and ClusterRoleBinding objects out before the dry-run" {
  export DRY_RUN=true
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [ -f "$KUBECTL_APPLY_INPUT_FILE" ]
  ! grep -q '^kind: ClusterRole$' "$KUBECTL_APPLY_INPUT_FILE"
  ! grep -q '^kind: ClusterRoleBinding$' "$KUBECTL_APPLY_INPUT_FILE"
}

@test "filters Role and RoleBinding objects out before the dry-run (RBAC escalation check would always reject them)" {
  export DRY_RUN=true
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [ -f "$KUBECTL_APPLY_INPUT_FILE" ]
  ! grep -q '^kind: Role$' "$KUBECTL_APPLY_INPUT_FILE"
  ! grep -q '^kind: RoleBinding$' "$KUBECTL_APPLY_INPUT_FILE"
}

@test "filters an ArgoCD-hook-annotated Job out before the dry-run (its live Job's spec.template is immutable, so any real change to it always fails a server dry-run)" {
  export DRY_RUN=true
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [ -f "$KUBECTL_APPLY_INPUT_FILE" ]
  ! grep -q 'name: testapp-bootstrap' "$KUBECTL_APPLY_INPUT_FILE"
}

@test "keeps a plain (non-hook) Job in the dry-run input" {
  export DRY_RUN=true
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  grep -q 'name: testapp-one-shot' "$KUBECTL_APPLY_INPUT_FILE"
}

@test "masks the minted token in output" {
  export DRY_RUN=true
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [[ "$output" == *"::add-mask::fake-token"* ]]
}

@test "mints the token for SERVICE_ACCOUNT when explicitly set, instead of \${NAMESPACE}-ci" {
  export DRY_RUN=true
  export SERVICE_ACCOUNT=custom-ci
  export KUBECTL_TOKEN_SA_LOG="$BATS_TEST_TMPDIR/kubectl-token-sa.log"
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$KUBECTL_TOKEN_SA_LOG")" = "custom-ci" ]
}

@test "runs helm dependency build for CHART_PATH before lint/template" {
  export DRY_RUN=false
  export HELM_CALL_LOG="$BATS_TEST_TMPDIR/helm-calls.log"
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [ -f "$HELM_CALL_LOG" ]
  [ "$(head -n1 "$HELM_CALL_LOG")" = "dependency build unused" ]
}

@test "passes --namespace to helm template, not just the release-name positional" {
  export DRY_RUN=false
  export HELM_CALL_LOG="$BATS_TEST_TMPDIR/helm-calls.log"
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "template testns unused --namespace testns" "$HELM_CALL_LOG"
}

@test "chart with no helm-unittest tests skips the step cleanly" {
  export DRY_RUN=false
  export HELM_CALL_LOG="$BATS_TEST_TMPDIR/helm-calls.log"
  export CHART_PATH="$BATS_TEST_TMPDIR/chart-no-tests"
  mkdir -p "$CHART_PATH"
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no helm-unittest tests found"* ]]
  ! grep -q '^plugin install' "$HELM_CALL_LOG"
  ! grep -q '^unittest' "$HELM_CALL_LOG"
}

@test "chart with helm-unittest tests installs the plugin and runs helm unittest" {
  export DRY_RUN=false
  export HELM_CALL_LOG="$BATS_TEST_TMPDIR/helm-calls.log"
  export CHART_PATH="$BATS_TEST_TMPDIR/chart-with-tests"
  mkdir -p "$CHART_PATH/tests"
  : > "$CHART_PATH/tests/example_test.yaml"
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "plugin install https://github.com/helm-unittest/helm-unittest" "$HELM_CALL_LOG"
  grep -qF -- "unittest $CHART_PATH" "$HELM_CALL_LOG"
}

@test "passes --namespace to the final kubectl apply dry-run" {
  export DRY_RUN=true
  export KUBECTL_CALL_LOG="$BATS_TEST_TMPDIR/kubectl-calls.log"
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  grep -qF -- "--namespace testns" <(grep "apply" "$KUBECTL_CALL_LOG")
}

@test "repo with no .bats files skips bats cleanly" {
  export DRY_RUN=false
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no .bats test files found"* ]]
}

@test "repo with a passing .bats file runs it via bats" {
  export DRY_RUN=false
  mkdir -p manifests/tests
  cat > manifests/tests/example.bats <<'EOF'
#!/usr/bin/env bats

@test "trivial passing test" {
  [ 1 -eq 1 ]
}
EOF
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"found 1 .bats test file(s)"* ]]
  [[ "$output" == *"trivial passing test"* ]]
}

@test "repo with a failing .bats file fails the check" {
  export DRY_RUN=false
  mkdir -p manifests/tests
  cat > manifests/tests/example.bats <<'EOF'
#!/usr/bin/env bats

@test "trivial failing test" {
  [ 1 -eq 2 ]
}
EOF
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"trivial failing test"* ]]
}

@test "repo with no scripts/*.sh files skips shellcheck cleanly" {
  export DRY_RUN=false
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no scripts/*.sh files found"* ]]
}

@test "repo with a clean scripts/*.sh file runs shellcheck" {
  export DRY_RUN=false
  mkdir -p manifests/scripts
  cat > manifests/scripts/example.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "hello"
EOF
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"found 1 script(s) under a scripts/ directory"* ]]
}

@test "repo with a shellcheck violation under scripts/ fails the check" {
  export DRY_RUN=false
  mkdir -p manifests/scripts
  cat > manifests/scripts/example.sh <<'EOF'
#!/usr/bin/env bash
FOO=$(date)
echo $FOO
EOF
  run bash "$BATS_TEST_DIRNAME/../check.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SC2086"* ]]
}
