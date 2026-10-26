#!/usr/bin/env bash
# Section 07 helper. Usage:
#   scripts/audit-query.sh pods      # find the privileged pod you created
#   scripts/audit-query.sh secrets   # find who read a Secret
set -euo pipefail
PROFILE="${PROFILE:-k8s-security}"
WHAT="${1:-pods}"
SINCE="${SINCE:-90m}"
LOGS() { kubectl logs -n kube-system "kube-apiserver-$PROFILE" --since="$SINCE"; }

if command -v jq >/dev/null 2>&1; then
  case "$WHAT" in
    pods)    LOGS | grep '"resource":"pods"' | grep '"verb":"create"' | tail -3 \
               | jq '{user:.user.username, pod:.objectRef.name, ns:.objectRef.namespace,
                      priv:.requestObject.spec.containers[0].securityContext.privileged,
                      hostPID:.requestObject.spec.hostPID, code:.responseStatus.code}' ;;
    secrets) LOGS | grep '"resource":"secrets"' | tail -5 \
               | jq -c '{t:.requestReceivedTimestamp, user:.user.username, verb:.verb,
                         name:.objectRef.name, ns:.objectRef.namespace,
                         ip:.sourceIPs[0], code:.responseStatus.code}' ;;
    *) echo "usage: $0 [pods|secrets]"; exit 1 ;;
  esac
else
  # no jq — python fallback, since jq is not installed everywhere
  LOGS | grep "\"resource\":\"$WHAT\"" | tail -5 | python3 -c '
import sys, json
for line in sys.stdin:
    try: e = json.loads(line)
    except Exception: continue
    o = e.get("objectRef") or {}
    print(e.get("requestReceivedTimestamp"), e["user"]["username"], e.get("verb"),
          o.get("namespace"), o.get("name"), (e.get("responseStatus") or {}).get("code"))'
fi
