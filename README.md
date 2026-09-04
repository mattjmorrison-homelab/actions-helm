# actions-helm

A single reusable GitHub Actions composite action, shared by every
`k8s-` repo in this org: `helm dependency build`, `helm lint`, `helm template`, and (unless
disabled) a server-side `kubectl apply --dry-run=server` against the
real cluster. See `naming.md` in the `.github` repo for the `actions-`
prefix: destination is other repos' CI, not the cluster itself.

Named for the tool it wraps (Helm — `kubectl` is only used internally
for the dry-run step, not the thing being validated), same reasoning as
`admin-openbao` over `admin-vault` and `actions-tofu` over
`actions-terraform`.

## Why server-side, not client-side, dry-run

`kubectl apply --dry-run=client` only checks that a manifest is
well-formed against the generic Kubernetes schema — entirely local, no
cluster involved. It can't catch anything a CRD's own validating/
mutating webhook would reject (e.g. `external-secrets`' webhook
rejecting a malformed `ExternalSecret`), because it never reaches the
API server's admission chain at all. `--dry-run=server` does reach that
chain — it's the only version that actually exercises the CRDs/webhooks
a chart depends on. The tradeoff: `--dry-run=server` still goes through
full RBAC authorization (only the final etcd write is skipped), so the
identity running it needs real create/patch permissions, not just read
access.

## What it needs to already exist

The dry-run step mints a short-lived (10-minute) token for a
ServiceAccount named `<namespace>-ci`, using this pod's own
`github-runner-workload` identity (only permitted to mint a token for
that one specific ServiceAccount, nothing else). That ServiceAccount and
its RBAC (Role/RoleBinding granting it real write access, scoped to just
that one namespace) come from a separate repo,
[`k8s-ci-rbac`](https://github.com/mattjmorrison-homelab/k8s-ci-rbac) —
adding a new namespace there is what makes a new `k8s-` repo's dry-run
step here actually work. RBAC = Role-Based Access Control, Kubernetes'
own permission system (who/what can do which actions on which
resources) — that's what `k8s-ci-rbac` generates.

## Inputs

| Input | Type | Default | Notes |
| --- | --- | --- | --- |
| `chart-path` | string | `manifests` | Path to the Helm chart. |
| `namespace` | string | *(required)* | Used as the `helm template` release name always. When `dry-run` is `true`, also the dry-run target and the source of the `<namespace>-ci` ServiceAccount name. |
| `dry-run` | string | `"true"` | Set to `"false"` to stop after lint/template — e.g. `k8s-ci-rbac`'s own CI, which has no RBAC target of its own to validate against. |
| `service-account` | string | *(empty)* | Override the CI ServiceAccount name used for dry-run. Defaults to `<namespace>-ci` if unset. Use this when your namespace's CI ServiceAccount has a different name (e.g. `prometheus-ci`). |

## Using it from another repo

```yaml
name: Check

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

jobs:
  check:
    if: github.event.action != 'closed'
    runs-on: k8s-amd64
    steps:
      - uses: actions/checkout@<sha> # v4.2.2
      - uses: mattjmorrison-homelab/actions-helm@<commit-sha>
        with:
          namespace: garage
```

The caller's own workflow `name:`/job id don't matter to this action
(unlike `actions-tofu`, there's no cross-run artifact lookup here) — just
follow the same `check` convention as everything else in this org so
required-status-check naming stays consistent.

**Pin to a commit SHA, not a branch** — this org requires
`sha_pinning_required` on every `uses:` reference, including cross-repo
calls to this one. Get the current SHA with:

```sh
gh api repos/mattjmorrison-homelab/actions-helm/commits/main --jq '.sha'
```

Update every caller's pin after any change here that should actually
take effect — an unpinned or stale-pinned caller keeps running whatever
this repo looked like at that commit, not the latest version. No
automation keeps these pins current today; it's a manual step.

## Permissions needed to call this from another repo

Checked directly against this org's current settings (2026-08-25) — as
things stand today, **nothing extra needs enabling**, since both the org
and every repo checked are on the permissive defaults (same conclusion
already documented in `actions-tofu`'s README, which check exactly which
settings this depends on and what to do if that policy ever tightens).
