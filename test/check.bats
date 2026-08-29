#!/usr/bin/env bats

setup() {
  export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
  export FIXTURES_DIR="$BATS_TEST_DIRNAME/fixtures"
  export CHART_PATH="unused"
  export NAMESPACE="testns"
  export KUBECTL_APPLY_INPUT_FILE="$BATS_TEST_TMPDIR/kubectl-apply-input.yaml"
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
