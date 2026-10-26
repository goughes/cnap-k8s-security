#!/usr/bin/env bash
# Section 04 step 15, as a script — the nested quoting is painful to type
# by hand and impossible to paste reliably into PowerShell.
set -euo pipefail
echo "--- the ServiceAccount token is just a file inside the pod:"
kubectl exec -n team-alpha probe -- \
  head -c 50 /var/run/secrets/kubernetes.io/serviceaccount/token; echo; echo
echo "--- using it to ask the API for team-bravo's secrets (expect 403):"
kubectl exec -n team-alpha probe -- sh -c \
  'curl -sk -o /dev/null -w "%{http_code}\n" \
     -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
     https://kubernetes.default.svc/api/v1/namespaces/team-bravo/secrets'
