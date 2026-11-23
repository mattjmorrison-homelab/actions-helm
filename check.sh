#!/bin/bash
set -euo pipefail

# Resolve chart dependencies before validating.
helm dependency build "$CHART_PATH"
helm lint "$CHART_PATH"

if find "$CHART_PATH" -name '*_test.yaml' 2>/dev/null | grep -q .; then
  echo "found helm-unittest tests under $CHART_PATH, installing helm-unittest plugin"
  helm plugin install https://github.com/helm-unittest/helm-unittest
  helm unittest "$CHART_PATH"
else
  echo "no helm-unittest tests found under $CHART_PATH, skipping helm unittest"
fi

helm template "$NAMESPACE" "$CHART_PATH" --namespace "$NAMESPACE" > /tmp/rendered.yaml

if ! command -v yq >/dev/null 2>&1; then
  echo "yq not found, installing"
  case "$(uname -m)" in
    x86_64) yq_arch=amd64 ;;
    aarch64|arm64) yq_arch=arm64 ;;
    *) echo "unsupported architecture for yq install: $(uname -m)" >&2; exit 1 ;;
  esac
  yq_install_dir="${RUNNER_TEMP:-/tmp}/actions-helm-bin"
  mkdir -p "$yq_install_dir"
  curl -sfL -o "$yq_install_dir/yq" "https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_${yq_arch}"
  chmod +x "$yq_install_dir/yq"
  export PATH="$yq_install_dir:$PATH"
fi

check_hook_resource_ordering() {
  local resource_kind="$1" job_name="$2" job_hook="$3" job_wave="$4"
  local -n ref_hook_map="$5"
  local -n ref_wave_map="$6"
  shift 6
  local ref_name ref_hook ref_wave
  for ref_name in "$@"; do
    [[ -z "$ref_name" ]] && continue
    ref_hook="${ref_hook_map[$ref_name]:-}"
    ref_wave="${ref_wave_map[$ref_name]:-}"
    [[ -z "$ref_hook" ]] && continue
    if [[ "$ref_hook" != "$job_hook" ]] || (( ref_wave >= job_wave )); then
      echo "ERROR: hook Job '$job_name' (hook=$job_hook, sync-wave=$job_wave) mounts $resource_kind '$ref_name' (hook=$ref_hook, sync-wave=$ref_wave) with no guaranteed ordering within the same hook phase." >&2
      echo "  Fix: give '$ref_name' the same hook phase ($job_hook) and a sync-wave strictly lower than the Job's, e.g. argocd.argoproj.io/sync-wave: \"$((job_wave - 1))\"." >&2
      hook_ordering_failed=1
    fi
  done
}

rendered_docs=()
doc=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == "---" ]]; then
    rendered_docs+=("$doc")
    doc=""
  else
    doc+="$line"$'\n'
  fi
done < /tmp/rendered.yaml
rendered_docs+=("$doc")

declare -A configmap_hook_by_name
declare -A configmap_wave_by_name
declare -A secret_hook_by_name
declare -A secret_wave_by_name

for doc in "${rendered_docs[@]}"; do
  [[ -z "${doc//[[:space:]]/}" ]] && continue
  kind=$(yq eval '.kind // ""' <<< "$doc")
  name=$(yq eval '.metadata.name // ""' <<< "$doc")
  [[ -z "$name" ]] && continue
  hook=$(yq eval '.metadata.annotations["argocd.argoproj.io/hook"] // ""' <<< "$doc")
  wave=$(yq eval '.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0"' <<< "$doc")
  if [[ "$kind" == "ConfigMap" ]]; then
    # shellcheck disable=SC2034 # read via nameref inside check_hook_resource_ordering
    configmap_hook_by_name["$name"]="$hook"
    # shellcheck disable=SC2034 # read via nameref inside check_hook_resource_ordering
    configmap_wave_by_name["$name"]="$wave"
  elif [[ "$kind" == "Secret" ]]; then
    # shellcheck disable=SC2034 # read via nameref inside check_hook_resource_ordering
    secret_hook_by_name["$name"]="$hook"
    # shellcheck disable=SC2034 # read via nameref inside check_hook_resource_ordering
    secret_wave_by_name["$name"]="$wave"
  fi
done

hook_ordering_failed=0
for doc in "${rendered_docs[@]}"; do
  [[ -z "${doc//[[:space:]]/}" ]] && continue
  kind=$(yq eval '.kind // ""' <<< "$doc")
  [[ "$kind" != "Job" ]] && continue
  job_hook=$(yq eval '.metadata.annotations["argocd.argoproj.io/hook"] // ""' <<< "$doc")
  [[ "$job_hook" != "PreSync" && "$job_hook" != "PostSync" ]] && continue
  job_name=$(yq eval '.metadata.name // ""' <<< "$doc")
  job_wave=$(yq eval '.metadata.annotations["argocd.argoproj.io/sync-wave"] // "0"' <<< "$doc")

  mapfile -t job_configmap_names < <(yq eval '.spec.template.spec.volumes // [] | .[] | select(has("configMap")) | .configMap.name' <<< "$doc")
  mapfile -t job_secret_names < <(yq eval '.spec.template.spec.volumes // [] | .[] | select(has("secret")) | .secret.secretName' <<< "$doc")

  check_hook_resource_ordering "ConfigMap" "$job_name" "$job_hook" "$job_wave" configmap_hook_by_name configmap_wave_by_name "${job_configmap_names[@]}"
  check_hook_resource_ordering "Secret" "$job_name" "$job_hook" "$job_wave" secret_hook_by_name secret_wave_by_name "${job_secret_names[@]}"
done

if [[ "$hook_ordering_failed" -ne 0 ]]; then
  echo "hook Job / ConfigMap-or-Secret sync-wave ordering check failed" >&2
  exit 1
fi
echo "hook Job / ConfigMap-or-Secret sync-wave ordering check passed"

if [ "$DRY_RUN" != "true" ]; then
  echo "dry-run disabled, stopping after lint/template"
  exit 0
fi

# Some charts render cluster-scoped objects (Namespace, ClusterRole,
# ClusterRoleBinding), which no namespace-scoped Role can ever grant
# dry-run access to. Role/RoleBinding are excluded for a different but
# equally fundamental reason: Kubernetes' own RBAC privilege-escalation
# check blocks creating/patching a Role or RoleBinding that grants any
# permission the actor doesn't already hold, regardless of namespace --
# no CI identity narrower than the permissions a chart's own shipped
# RBAC grants can ever dry-run-apply that RBAC (confirmed against a
# real chart shipping its own Role/RoleBinding for its controller,
# distinct from any CI RBAC). An ArgoCD-hook-annotated Job is excluded
# for a third, unrelated reason: a Job's spec.template is immutable once
# it exists live, so a server-side dry-run "update" against an
# already-existing hook Job fails on any real change to a field inside
# it, regardless of whether the change is correct -- ArgoCD's own
# hook-delete-policy (BeforeHookCreation) deletes the old Job before
# creating the new one on a real sync, which this dry-run doesn't
# replicate. A plain (non-hook) Job is kept, since nothing here creates
# a same-named Job repeatedly the way a hook does. Split the multi-doc
# render on "---" and drop any document matching one of those. Plain
# bash + grep, matching the filtering approach already established here
# before yq was introduced for the hook sync-wave check above.
: > /tmp/rendered-filtered.yaml
doc=""
first=1
flush() {
  if [[ -n "$doc" ]] \
    && ! grep -qE '^kind: (Namespace|ClusterRole|ClusterRoleBinding|Role|RoleBinding)$' <<< "$doc" \
    && ! { grep -qE '^kind: Job$' <<< "$doc" && grep -q 'argocd.argoproj.io/hook:' <<< "$doc"; }; then
    [[ "$first" -eq 0 ]] && printf -- '---\n' >> /tmp/rendered-filtered.yaml
    printf '%s' "$doc" >> /tmp/rendered-filtered.yaml
    first=0
  fi
}
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == "---" ]]; then
    flush
    doc=""
  else
    doc+="$line"$'\n'
  fi
done < /tmp/rendered.yaml
flush
test -s /tmp/rendered-filtered.yaml

# Mint a short-lived token for <namespace>-ci (created by k8s-ci-rbac)
# using this pod's own github-runner-workload identity, which is only
# permitted to do that one thing for that one namespace.
API=https://kubernetes.default.svc
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
RUNNER_TOKEN=/var/run/secrets/kubernetes.io/serviceaccount/token

service_account="${SERVICE_ACCOUNT:-${NAMESPACE}-ci}"

ci_token=$(kubectl --server="$API" --certificate-authority="$CA" \
  --token="$(cat "$RUNNER_TOKEN")" \
  create token "$service_account" -n "$NAMESPACE" --duration=10m)
echo "::add-mask::$ci_token"

kubectl --server="$API" --certificate-authority="$CA" \
  --token="$ci_token" \
  apply --dry-run=server --namespace "$NAMESPACE" -f /tmp/rendered-filtered.yaml
