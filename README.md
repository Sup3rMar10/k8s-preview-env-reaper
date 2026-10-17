# k8s-preview-env-reaper

![ci](https://github.com/Sup3rMar10/k8s-preview-env-reaper/actions/workflows/ci.yml/badge.svg)

One namespace per pull request, locked down with a quota and strict Pod Security, plus a **reaper** that deletes expired previews, as a script and as an in-cluster CronJob. The part that matters is that the reaper is hard to point at something it should not delete.

> **What is verified.** On 2026-10-17 the pipeline ran green on GitHub Actions against a kind cluster: **20 of 20 checks**, including the CronJob doing the reaping. It never ran against a real cluster, and nothing here is wired to real pull-request events (see limits).

## The pieces

- `preview/preview.yaml.tmpl` (rendered by `scripts/preview.sh create <pr> <ttl-seconds>`): a `pr-<n>` namespace labelled `preview=true` with an expiry annotation, a **ResourceQuota** (6 pods, 500m CPU, 512Mi memory), a LimitRange, a default-deny **NetworkPolicy** that allows only same-namespace traffic, `pod-security.kubernetes.io/enforce: restricted`, and a small app.
- `scripts/reaper.sh [--dry-run]`: deletes namespaces whose `preview-expires-at` (epoch seconds) has passed. POSIX `sh`, so it runs in a minimal image.
- `deploy/reaper/reaper.yaml`: the same script as a CronJob (every 10 minutes), with a ServiceAccount that can only get, list and delete namespaces. The script is supplied as a ConfigMap built from `scripts/reaper.sh`, so there is one copy of the logic.

## Three guards on the deletion

1. It only looks at namespaces labelled `preview=true`.
2. It only touches names matching `pr-<number>`.
3. A missing or unparseable expiry means **skip**, never delete.

## What `scripts/e2e.sh` checks (20 checks)

- The live preview deploys and answers. Asking for 20 replicas is capped at **6 pods** by the quota, with an "exceeded quota" event. A **privileged pod is refused** by Pod Security.
- `--dry-run` names the expired preview and deletes nothing.
- The real run deletes only the expired preview `pr-2`. Everything else survives: a live preview, one with the junk expiry `soon`, one labelled but with **no** expiry, an **expired but unlabelled** namespace named `pr-77`, an expired and unlabelled namespace called `precious`, and an expired and labelled namespace called `staging` (name is not `pr-<n>`). Summary line: `reaped=1 kept=1 skipped=3`.
- A second run reaps nothing (idempotent).
- A Job started from the CronJob (`kubectl create job --from=cronjob/...`) reaps an expired `pr-4` and leaves the others alone.
- Closing a PR (`preview.sh delete`) removes its namespace.
- Informational: a cross-namespace request to a preview timed out (`curl` exit code 28), which is consistent with NetworkPolicy being enforced on kind. A timeout is also what other network faults look like, so I call it "consistent with", not proof.

## Honest limits

- **Not connected to real pull requests.** There is no GitHub workflow that runs `preview.sh create` on a PR event against a real cluster, because there is no real cluster or kubeconfig here. The CI only tests the tooling on a throwaway kind cluster. Wiring it up is a kubeconfig secret (or OIDC to a cloud cluster) plus a `pull_request: opened/closed` workflow.
- **The CronJob's schedule never fired by the clock.** The test triggers a Job from it by hand, which tests the image, RBAC, script and mounting, but not the `*/10 * * * *` trigger.
- The preview app is stock nginx, not a build of the PR. No image per PR, ingress, DNS or TLS.
- The reaper is **destructive by design**. The guards above are what stop mistakes; a namespace named `pr-5` that someone labelled `preview=true` with a past expiry will be deleted. Review and test before pointing it at a shared cluster.
- An `NOW` environment variable can override the clock, but the tests use real timestamps instead.
- A `--wait=false` delete means the namespace may still be terminating when the script ends.
- The CronJob image is `alpine/k8s:1.33.1`, pinned by tag, not digest.
- PR numbers are reused across forks and rebases in some setups; a recreated PR resets the preview.

## Run it locally

Needs a cluster (kind is fine), `kubectl`, `envsubst` and bash:

```
scripts/e2e.sh
```

I did not run it locally (Docker was not running on my machine); the CI runs are the evidence.
