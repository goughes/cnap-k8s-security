#!/usr/bin/env bash
# THE PARKING BRAKE.
# Recovers a cluster whose API server is crash-looping because of a bad
# audit or encryption config, in about 30 seconds, with no rebuild.
# The kubelet notices the static pod manifest changed and restarts the
# API server without the offending flags.
set -euo pipefail
PROFILE="${PROFILE:-k8s-security}"
echo "==> Stripping audit and encryption flags from the API server manifest"
minikube ssh -p "$PROFILE" -- \
  'sudo sed -i "/--audit-/d;/--encryption-provider-config/d" /etc/kubernetes/manifests/kube-apiserver.yaml'
echo "==> Waiting for the API server to come back (about 30s)"
for i in $(seq 1 30); do
  if kubectl get nodes >/dev/null 2>&1; then echo "    recovered"; exit 0; fi
  sleep 2
done
echo "    still down — read the real error with:"
echo "    minikube ssh -p $PROFILE -- 'sudo crictl logs --tail 60 \$(sudo crictl ps -a --name kube-apiserver -q | head -1)'"
