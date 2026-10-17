#!/usr/bin/env bash
# End-to-end test of the preview lifecycle and the reaper, against the cluster kubectl points at.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
pass=0
fail=0

step() { echo; echo "== $*"; }
ok() {
  echo "  PASS  $1"
  pass=$((pass + 1))
}
bad() {
  echo "  FAIL  $1"
  fail=$((fail + 1))
}
exists() { kubectl get namespace "$1" >/dev/null 2>&1; }
check_exists() { if exists "$1"; then ok "$1 still exists"; else bad "$1 was deleted but should have been kept"; fi; }
check_gone() { if exists "$1"; then bad "$1 should have been deleted"; else ok "$1 is gone"; fi; }
wait_gone() { # namespaces terminate asynchronously
  for _ in $(seq 1 90); do
    exists "$1" || return 0
    sleep 1
  done
  return 1
}

step "create previews: live, expired, junk expiry, no expiry, and two namespaces that are not previews"
"$here/preview.sh" create 1 3600
"$here/preview.sh" create 2 -60
"$here/preview.sh" create 3 3600
kubectl annotate namespace pr-3 preview-expires-at=soon --overwrite
# labelled as a preview but no expiry annotation at all
kubectl create namespace pr-9
kubectl label namespace pr-9 preview=true
# NOT labelled as a preview, even though it carries an expired timestamp and a preview-like name
kubectl create namespace pr-77
kubectl annotate namespace pr-77 preview-expires-at=1
# a namespace that matters, with an expired preview annotation but no label
kubectl create namespace precious
kubectl annotate namespace precious preview-expires-at=1
# labelled and expired, but the name is not pr-<number>
kubectl create namespace staging
kubectl label namespace staging preview=true
kubectl annotate namespace staging preview-expires-at=1
"$here/preview.sh" list

step "the live preview works"
kubectl -n pr-1 rollout status deployment/app --timeout=180s
kubectl -n pr-1 port-forward svc/app 18080:80 >/dev/null 2>&1 &
pf=$!
body=""
for _ in $(seq 1 30); do
  if body="$(curl -fsS --max-time 2 http://127.0.0.1:18080/ 2>/dev/null)"; then break; fi
  sleep 1
done
kill "$pf" 2>/dev/null || true
if grep -q "Welcome to nginx" <<<"$body"; then ok "preview serves its app"; else bad "preview did not answer"; fi

step "the quota contains a runaway preview"
kubectl -n pr-1 scale deployment/app --replicas=20
quota_hit=false
for _ in $(seq 1 40); do
  if kubectl -n pr-1 get events -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | grep -q "exceeded quota"; then
    quota_hit=true
    break
  fi
  sleep 1
done
pods="$(kubectl -n pr-1 get pods --no-headers | wc -l | tr -d ' ')"
echo "  pods in pr-1 after asking for 20 replicas: $pods"
if [ "$quota_hit" = "true" ]; then ok "an 'exceeded quota' event was recorded"; else bad "no quota event"; fi
if [ "$pods" -le 6 ]; then ok "pod count capped at the quota (6)"; else bad "quota did not cap pods ($pods)"; fi
kubectl -n pr-1 scale deployment/app --replicas=2

step "pod security: a privileged pod is refused in a preview namespace"
if kubectl -n pr-1 run priv --image=busybox:1.37 --privileged --restart=Never -- sleep 1 2>/tmp/priv.out; then
  bad "privileged pod was admitted"
  kubectl -n pr-1 delete pod priv --ignore-not-found
else
  ok "privileged pod refused"
  sed 's/^/        | /' /tmp/priv.out
fi

step "reaper --dry-run changes nothing"
out="$("$here/reaper.sh" --dry-run)"
echo "$out" | sed 's/^/        | /'
if grep -q "WOULD DELETE pr-2" <<<"$out"; then ok "dry run names pr-2"; else bad "dry run did not name pr-2"; fi
check_exists pr-2

step "reaper deletes only what it should"
out="$("$here/reaper.sh")"
echo "$out" | sed 's/^/        | /'
if wait_gone pr-2; then ok "pr-2 (expired preview) is gone"; else bad "pr-2 still exists"; fi
check_exists pr-1
check_exists pr-3
check_exists pr-9
check_exists pr-77
check_exists precious
check_exists staging
if grep -q "reaped=1 kept=1 skipped=3" <<<"$out"; then ok "summary: reaped=1 kept=1 skipped=3"; else bad "unexpected summary"; fi

step "the reaper is idempotent"
out="$("$here/reaper.sh")"
if grep -q "reaped=0" <<<"$out"; then ok "second run reaps nothing"; else bad "second run reaped something"; fi

step "the in-cluster CronJob does the same work"
"$here/preview.sh" create 4 -60
kubectl apply -f "$root/deploy/reaper/reaper.yaml"
kubectl -n preview-system create configmap reaper-script --from-file="$here/reaper.sh"
kubectl -n preview-system create job manual-run --from=cronjob/preview-reaper
if kubectl -n preview-system wait --for=condition=complete job/manual-run --timeout=240s; then ok "reaper job completed"; else bad "reaper job did not complete"; fi
kubectl -n preview-system logs job/manual-run | sed 's/^/        | /'
if wait_gone pr-4; then ok "pr-4 (expired) was reaped by the CronJob"; else bad "pr-4 still exists"; fi
check_exists pr-1
check_exists precious

step "closing the PR removes its preview"
"$here/preview.sh" delete 1
if wait_gone pr-1; then ok "pr-1 deleted on PR close"; else bad "pr-1 still exists"; fi

step "info only: is NetworkPolicy enforced on this cluster?"
"$here/preview.sh" create 5 3600
kubectl -n pr-5 rollout status deployment/app --timeout=180s
# curl exit codes tell the cases apart: 0 = reached the app, 28 = timed out (what a dropped packet looks like),
# 6 = DNS failure, 7 = connection refused. Only 28 is evidence of a NetworkPolicy drop.
probe="$(kubectl run np-probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 --command -- \
  sh -c 'curl -sS -o /dev/null --max-time 5 http://app.pr-5.svc/ 2>/dev/null; echo curl-exit=$?' 2>/dev/null | tr -d '\r' | grep -o 'curl-exit=[0-9]*' || true)"
echo "  INFO  cross-namespace probe result: ${probe:-no result}"
case "$probe" in
  curl-exit=0) echo "  INFO  request SUCCEEDED: NetworkPolicy is not enforced on this cluster" ;;
  curl-exit=28) echo "  INFO  request TIMED OUT: consistent with NetworkPolicy dropping the traffic" ;;
  *) echo "  INFO  inconclusive: the request failed for a reason other than a timeout" ;;
esac
"$here/preview.sh" delete 5

echo
echo "checks passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
