#!/usr/bin/env bash
# Stage the audit policy and build the workshop cluster. Run from the repo root.
set -euo pipefail
PROFILE="${PROFILE:-k8s-security}"
MEM="${MEM:-6144}"

echo "==> Staging the audit policy into ~/.minikube/files"
mkdir -p "$HOME/.minikube/files/etc/ssl/certs"
cp audit/audit-policy.yaml "$HOME/.minikube/files/etc/ssl/certs/"

echo "==> Validating it before we boot anything (a bad policy bricks the API server)"
python3 -c "import yaml,sys; yaml.safe_load(open('audit/audit-policy.yaml'))" \
  && echo "    audit-policy.yaml parses OK"

echo "==> Starting minikube profile '$PROFILE' (3-5 minutes on a cold cache)"
minikube start -p "$PROFILE" \
  --driver=docker --container-runtime=containerd \
  --cni=calico --cpus=4 --memory="$MEM" --disk-size=20g \
  --extra-config=apiserver.audit-policy-file=/etc/ssl/certs/audit-policy.yaml \
  --extra-config=apiserver.audit-log-path=-

echo "==> Waiting for Calico"
kubectl wait --for=condition=Ready node --all --timeout=300s

echo "==> Creating the two tenants"
kubectl apply -f setup/tenants.yaml

echo
echo "Done. Verify audit logging actually landed:"
echo "  kubectl -n kube-system get pod kube-apiserver-$PROFILE \\"
echo "    -o jsonpath='{.spec.containers[0].command}' | tr ',' '\n' | grep audit"
