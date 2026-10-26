#!/usr/bin/env bash
# Full reset. NOTE: deleting the cluster is not enough on its own —
# a bad file staged in ~/.minikube/files is re-copied into EVERY new
# cluster on every start. That is the "I deleted it and it's still
# broken" trap. This script clears both.
set -euo pipefail
PROFILE="${PROFILE:-k8s-security}"
echo "==> Deleting minikube profile '$PROFILE'"
minikube delete -p "$PROFILE" || true
echo "==> Removing the staged audit policy"
rm -f "$HOME/.minikube/files/etc/ssl/certs/audit-policy.yaml"
rm -f "$HOME/.minikube/files/etc/ssl/certs/encryption-config.yaml"
echo "Done. Run scripts/start.sh for a clean cluster."
