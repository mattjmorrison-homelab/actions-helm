#!/bin/bash
set -euo pipefail

# Resolve chart dependencies before validating.
helm dependency build "$CHART_PATH"
helm lint "$CHART_PATH"
helm template "$NAMESPACE" "$CHART_PATH" --namespace "$NAMESPACE" > /tmp/rendered.yaml

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
# bash + grep -- yq isn't installed on this runner image.
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
