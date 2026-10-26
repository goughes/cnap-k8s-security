#!/usr/bin/env bash
# ============================================================================
# PRE-FLIGHT CHECK — run this at least a week before you present.
#
# The deck was written without live access to the Kubewarden / cert-manager /
# Calico docs, so a handful of strings in it are version-sensitive. This
# script checks every one of them against a REAL cluster and prints what it
# actually finds, so you can correct the slides.
#
# Requires: an already-running workshop cluster (scripts/start.sh).
# ============================================================================
PROFILE="${PROFILE:-k8s-security}"
PASS=0; FAIL=0
ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
note() { echo "  [note] $*"; }

echo "=== 1. Cluster and CNI ==============================================="
kubectl get nodes >/dev/null 2>&1 && ok "cluster reachable" || bad "cluster not reachable"
echo "  Calico pods (confirm the NAMESPACE the slides should name):"
kubectl get pods -A 2>/dev/null | grep -Ei 'calico|tigera' | awk '{print "    ns="$1"  "$2"  "$4}'

echo
echo "=== 2. API server audit flags ========================================"
CMD=$(kubectl -n kube-system get pod "kube-apiserver-$PROFILE" \
        -o jsonpath='{.spec.containers[0].command}' 2>/dev/null | tr ',' '\n' | grep audit)
[ -n "$CMD" ] && { ok "audit flags present"; echo "$CMD" | sed 's/^/    /'; } \
               || bad "no audit flags on kube-apiserver-$PROFILE"
echo "  hostPath mounts available to the API server (the policy file must be in one):"
kubectl -n kube-system get pod "kube-apiserver-$PROFILE" \
  -o jsonpath='{range .spec.volumes[*]}{"    "}{.name}{"\t"}{.hostPath.path}{"\n"}{end}' 2>/dev/null

echo
echo "=== 3. etcd data path (used by the Secrets section) =================="
kubectl -n kube-system get pod "etcd-$PROFILE" \
  -o jsonpath='{range .spec.volumes[*]}{"    "}{.name}{"\t"}{.hostPath.path}{"\n"}{end}' 2>/dev/null
note "the deck says /var/lib/minikube/etcd/member/snap/db — confirm against the above"

echo
echo "=== 4. Helm charts ==================================================="
helm repo add jetstack   https://charts.jetstack.io   >/dev/null 2>&1
helm repo add kubewarden https://charts.kubewarden.io >/dev/null 2>&1
helm repo update >/dev/null 2>&1
echo "  cert-manager chart versions:"; helm search repo jetstack/cert-manager --versions 2>/dev/null | head -3 | sed 's/^/    /'
echo "  kubewarden chart versions:";   helm search repo kubewarden --versions 2>/dev/null | head -5 | sed 's/^/    /'
note "SLIDE CHECK: does the cert-manager chart want --set crds.enabled=true"
note "             or the older --set installCRDs=true ? Run: helm show values jetstack/cert-manager | grep -iA2 crds"

echo
echo "=== 5. Kubewarden CRD contract (authoritative — beats the docs) ======"
kubectl get crd clusteradmissionpolicies.policies.kubewarden.io \
  -o jsonpath='{range .spec.versions[*]}{"    served apiVersion: policies.kubewarden.io/"}{.name}{"  storage="}{.storage}{"\n"}{end}' 2>/dev/null \
  || bad "Kubewarden CRDs not installed — run the section 03 helm installs first"
echo "  printer columns (what 'kubectl get clusteradmissionpolicies' shows):"
kubectl get crd clusteradmissionpolicies.policies.kubewarden.io \
  -o jsonpath='{range .spec.versions[?(@.storage)].additionalPrinterColumns[*]}{"    "}{.name}{" <- "}{.jsonPath}{"\n"}{end}' 2>/dev/null

echo
echo "=== 6. Policy modules pull, and their SETTINGS KEYS =================="
note "wrong settings keys are SILENTLY IGNORED by some policies -> a policy"
note "that reports active and blocks nothing. This is the #1 risk in the deck."
for p in pod-privileged host-namespaces-psp hostpaths-psp \
         allow-privilege-escalation-psp capabilities-psp; do
  echo "  --- $p"
  if command -v kwctl >/dev/null 2>&1; then
    kwctl inspect "registry://ghcr.io/kubewarden/policies/$p:latest" 2>&1 \
      | sed -n '1,40p' | sed 's/^/      /'
  else
    note "    kwctl not installed - get it from github.com/kubewarden/kwctl"
    note "    without it you cannot verify the settings schema"
  fi
done

echo
echo "=== 7. THE REAL TEST: do the denies actually happen? ================="
note "This is the only check that matters. Everything above can look fine"
note "while the policies block nothing."
kubectl apply -f policies/04-escape-attempts.yaml 2>&1 | sed 's/^/    /'
CREATED=$(kubectl get pods -n team-alpha -o name 2>/dev/null | grep -c attack- || true)
if [ "$CREATED" -eq 0 ]; then
  ok "all four escape attempts were refused"
else
  bad "$CREATED attack pod(s) WERE CREATED - those policies are inert"
  kubectl get pods -n team-alpha | grep attack- | sed 's/^/    /'
fi
echo
note "COPY THE EXACT REJECTION TEXT ABOVE ONTO THE SLIDES. Students"
note "pattern-match on error strings, and floaters triage faster with them."

echo
echo "====================================================================="
echo "  passed: $PASS   failed: $FAIL"
echo "  Re-read any slide this script contradicted before you present."
