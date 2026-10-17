#!/usr/bin/env bash
# Create, delete or list preview environments.
#   scripts/preview.sh create <pr-number> <ttl-seconds>
#   scripts/preview.sh delete <pr-number>
#   scripts/preview.sh list
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-}"

case "$cmd" in
  create)
    pr="${2:?pr number required}"
    ttl="${3:?ttl in seconds required}"
    case "$pr" in *[!0-9]* | '') echo "pr must be a number" >&2; exit 2 ;; esac
    PR="$pr"
    EXPIRES="$(($(date +%s) + ttl))"
    export PR EXPIRES
    # shellcheck disable=SC2016
    envsubst '${PR} ${EXPIRES}' <"$here/../preview/preview.yaml.tmpl" | kubectl apply -f -
    ;;
  delete)
    pr="${2:?pr number required}"
    kubectl delete namespace "pr-$pr" --ignore-not-found --wait=false
    ;;
  list)
    kubectl get namespaces -l preview=true \
      -o custom-columns='NAME:.metadata.name,PR:.metadata.labels.preview-pr,EXPIRES-AT:.metadata.annotations.preview-expires-at'
    ;;
  *)
    echo "usage: $0 create <pr> <ttl-seconds> | delete <pr> | list" >&2
    exit 2
    ;;
esac
