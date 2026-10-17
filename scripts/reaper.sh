#!/bin/sh
# Delete expired preview namespaces. POSIX sh, so it also runs in the minimal in-cluster image.
# Usage: reaper.sh [--dry-run]       (NOW=<epoch> overrides the clock, for tests)
#
# Three guards, because this script deletes things:
#   1. it only looks at namespaces carrying the label preview=true
#   2. it only touches names matching pr-<number>
#   3. a missing or unparseable expiry means "skip", never "delete"
set -eu

dry_run=false
if [ "${1:-}" = "--dry-run" ]; then
  dry_run=true
fi

now="${NOW:-$(date +%s)}"
reaped=0
kept=0
skipped=0

for ns in $(kubectl get namespaces -l preview=true -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in
    pr-[0-9]*) ;;
    *)
      echo "SKIP   $ns: name is not pr-<number>"
      skipped=$((skipped + 1))
      continue
      ;;
  esac

  expires="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.annotations.preview-expires-at}')"
  case "$expires" in
    '' | *[!0-9]*)
      echo "SKIP   $ns: preview-expires-at is missing or not an epoch number ('$expires')"
      skipped=$((skipped + 1))
      continue
      ;;
  esac

  if [ "$expires" -le "$now" ]; then
    if [ "$dry_run" = "true" ]; then
      echo "WOULD DELETE $ns (expired $((now - expires))s ago)"
    else
      kubectl delete namespace "$ns" --wait=false
      echo "DELETED $ns (expired $((now - expires))s ago)"
    fi
    reaped=$((reaped + 1))
  else
    echo "KEEP   $ns (expires in $((expires - now))s)"
    kept=$((kept + 1))
  fi
done

echo "reaped=$reaped kept=$kept skipped=$skipped dry_run=$dry_run"
