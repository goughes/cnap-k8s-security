# Securing Multitenant Kubernetes — CNAP workshop

Companion manifests for the CNAP workshop *Securing Multitenant Kubernetes* (part 2 of the Docker & Kubernetes series). Everything here runs on a throwaway local minikube cluster.

The workshop builds five layers of defense on one cluster shared by two tenants, in this order: admission control, RBAC, network policy, secrets, and audit logging. You start by escaping a container onto the node, then close every door you walked through.

Every command from the slides is below, in order, with the checkpoint that tells you it worked. If you fall behind during the session, pick up at the step number on the slide.

## Before you start

**Docker Desktop memory must be at least 6 GB.** minikube with the docker driver runs inside Docker Desktop and cannot be given more memory than Docker Desktop itself has. Settings → Resources → Memory. On Windows/WSL 2 set it in `%UserProfile%\.wslconfig` and run `wsl --shutdown`. A 4 GB cluster works but is tight.

**Do the setup at home, not at the venue.** The cluster pulls Calico, cert-manager and Kubewarden — several hundred megabytes. Thirty laptops doing that simultaneously on venue Wi-Fi will not finish.

If you would rather not type steps 1–5, `./scripts/start.sh` does all of them in one shot.

---

# §02 · Setup — one cluster, two tenants

### Step 1 — Clone the workshop repo

```bash
git clone https://github.com/goughes/cnap-k8s-security.git
cd cnap-k8s-security
ls
```

✓ `ls` shows the folders above, and your prompt is inside `cnap-k8s-security`.

### Step 2 — Stage the audit policy first

The API server reads its audit policy from a file on the node, so the file has to be in place *before* the cluster boots. minikube copies anything under `~/.minikube/files` into the node at start.

```bash
# Mac / Linux
mkdir -p ~/.minikube/files/etc/ssl/certs
cp audit/audit-policy.yaml ~/.minikube/files/etc/ssl/certs/
```

```powershell
# Windows PowerShell
mkdir -Force $HOME\.minikube\files\etc\ssl\certs
cp audit\audit-policy.yaml $HOME\.minikube\files\etc\ssl\certs\
```

✓ The file exists at `~/.minikube/files/etc/ssl/certs/audit-policy.yaml` on your laptop. Nothing has started yet.

### Step 3 — Start the cluster

```bash
minikube start -p k8s-security \
  --driver=docker --container-runtime=containerd \
  --cni=calico --cpus=4 --memory=6144 --disk-size=20g \
  --extra-config=apiserver.audit-policy-file=/etc/ssl/certs/audit-policy.yaml \
  --extra-config=apiserver.audit-log-path=-
```

✓ The command finishes with `Done! kubectl is now configured to use "k8s-security"`. First run takes 3–5 minutes.

### Step 4 — Check the cluster and the network plugin

```bash
kubectl get nodes
kubectl get pods -A | grep -Ei 'calico|tigera'
```

✓ One node, `STATUS Ready`, and `calico-node` showing `1/1 Running`.

### Step 5 — Create the two tenants

```bash
kubectl apply -f setup/tenants.yaml
kubectl get ns --show-labels | grep team-
```

✓ Two namespaces, `Active`, each carrying a `tenant=` label.

---

# §03 · Policy and admission control

Break out of a container onto the node, then close every door you walked through.

### Step 6 — Ask for a privileged pod. Nobody says no

```bash
kubectl apply -f policies/01-escape-pod.yaml
kubectl get pod -n team-alpha
```

✓ The pod is `Running`. Nothing warned you. Read the three commented lines in the YAML before you move on.

### Step 7 — Walk out of the container onto the node

```bash
kubectl exec -it -n team-alpha escape -- chroot /host sh

# you are now a root shell ON THE NODE
id
cat /etc/hostname
ls /var/lib/kubelet/pods | head -5
exit
```

✓ `id` prints `uid=0(root)` and the hostname is the node, not the pod. You have escaped the container.

### Step 8 — Install cert-manager

Kubewarden's webhook needs a TLS certificate the API server trusts. cert-manager issues it.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait
```

If `--set crds.enabled=true` errors, your chart version wants the older flag name: `--set installCRDs=true`.

✓ All three cert-manager pods show `1/1 Running`.

### Step 9 — Install Kubewarden

Three charts, in this order: the CRDs, the controller that watches them, then a default policy server to run your policies.

```bash
helm repo add kubewarden https://charts.kubewarden.io
helm repo update

helm install --wait -n kubewarden --create-namespace \
  kubewarden-crds kubewarden/kubewarden-crds
helm install --wait -n kubewarden \
  kubewarden-controller kubewarden/kubewarden-controller
helm install --wait -n kubewarden \
  kubewarden-defaults kubewarden/kubewarden-defaults

kubectl get pods -n kubewarden
```

Tight on RAM? Add `--set policyServer.replicaCount=1` to the defaults chart.

✓ `kubewarden-controller` and `policy-server-default` are both `1/1 Running`.

### Step 10 — Write your first policy, in monitor mode

```bash
kubectl apply -f policies/02-no-privileged.yaml
kubectl get clusteradmissionpolicies
```

✓ `STATUS` says `active`. Wait for it — a policy takes a few seconds to be pulled and loaded.

### Step 11 — Monitor mode watches. It does not block

```bash
kubectl delete -f policies/01-escape-pod.yaml
kubectl apply  -f policies/01-escape-pod.yaml

kubectl logs -n kubewarden \
  -l app=kubewarden-policy-server-default --tail=20
```

✓ The pod is created anyway, **and** the policy server log shows `"allowed":false` with `"mode":"monitor"`.

Do not skip the log check. In monitor mode a working policy and a completely inert one look identical from the outside — the pod is created either way. That log line is the only evidence the policy is actually evaluating anything, and if it is missing, step 12 will appear to fail.

### Step 12 — Flip the switch to protect

```bash
kubectl patch clusteradmissionpolicy no-privileged-pods \
  --type=merge -p '{"spec":{"mode":"protect"}}'

# the mode change rolls the policy server; the old pod answers in
# monitor mode until the new one is ready. Do not race it.
kubectl rollout status deploy/policy-server-default -n kubewarden

kubectl delete -f policies/01-escape-pod.yaml
kubectl apply  -f policies/01-escape-pod.yaml
```

✓ `kubectl apply` fails with `denied the request`, and `kubectl get pod -n team-alpha` finds nothing.

If the pod is still created, run `kubectl get clusteradmissionpolicy no-privileged-pods`. `MODE=protect` with `OBSERVED MODE=monitor` means the policy server has not reloaded yet — wait and retry. `MODE=monitor` means the patch never landed; PowerShell mangles the quoting on that `-p` argument, so use `kubectl apply -f policies/02b-no-privileged-protect.yaml` instead.

`monitor → protect` is one-way. Kubewarden will not let you relax a policy back to monitor — delete and recreate it if you need to.

### Step 13 — Close the other three doors

```bash
kubectl apply -f policies/03-harden-tenants.yaml
kubectl get clusteradmissionpolicies

# now try all four attacks at once
kubectl apply -f policies/04-escape-attempts.yaml
```

✓ Five policies, all `protect`, all `active` — and every pod in `04-escape-attempts.yaml` is refused.

### Step 14 — And the free one you should always turn on

```bash
kubectl label ns team-alpha \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted --overwrite

kubectl apply -f policies/01-escape-pod.yaml
```

✓ One `kubectl apply`, one long rejection listing every rule the pod broke at once.

---

# §04 · RBAC

Who may ask the API for what — and the traps that quietly undo it.

### Step 15 — Every pod carries an API token

```bash
kubectl apply -f rbac/00-probe.yaml

# the token is just a file inside the pod
kubectl exec -n team-alpha probe -- \
  head -c 50 /var/run/secrets/kubernetes.io/serviceaccount/token

# use it to ask the API for team-bravo's secrets
kubectl exec -n team-alpha probe -- sh -c 'curl -sk -o /dev/null \
  -w "%{http_code}\n" -H "Authorization: Bearer $(cat \
  /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  https://kubernetes.default.svc/api/v1/namespaces/team-bravo/secrets'
```

`scripts/token-probe.sh` wraps that last command if the quoting is painful in your shell.

✓ You see the start of a JWT, and the API returns `403` for team-bravo's secrets.

### Step 16 — Grant a tenant exactly what they need

```bash
kubectl apply -f rbac/01-tenant-developer.yaml

kubectl get role,rolebinding,sa -n team-alpha
```

✓ A ServiceAccount, a Role and a RoleBinding, all inside `team-alpha`.

### Step 17 — Test permissions without logging in

```bash
ALPHA=system:serviceaccount:team-alpha:alpha-dev

kubectl auth can-i create pods    -n team-alpha --as=$ALPHA
kubectl auth can-i get    secrets -n team-alpha --as=$ALPHA
kubectl auth can-i get    pods    -n team-bravo --as=$ALPHA

kubectl auth can-i --list -n team-alpha --as=$ALPHA
```

✓ `yes`, then two `no`s, then a list containing no secrets and nothing outside `team-alpha`.

---

# §05 · Network policies

By default every pod can reach every other pod, in every namespace.

### Step 18 — Reach into the other tenant's namespace

```bash
# bravo deploys their internal service
kubectl apply -f network/01-workloads.yaml

# alpha reaches straight into it
kubectl exec -n team-alpha probe -- curl -s -m 5 \
  -o /dev/null -w '%{http_code}\n' \
  http://api.team-bravo.svc.cluster.local:8080
```

✓ `200`. A pod in your namespace just talked to another tenant's internal service.

### Step 19 — Default-deny, then allow back

```bash
kubectl apply -f network/02-default-deny.yaml

kubectl exec -n team-alpha probe -- curl -s -m 5 \
  -o /dev/null -w '%{http_code}\n' \
  http://api.team-bravo.svc.cluster.local:8080
```

✓ The curl times out with exit code 28 and prints `000`.

### Step 20 — Allow exactly one caller back in

```bash
kubectl apply -f network/03-allow-alpha-probe.yaml

# the allowed caller
kubectl exec -n team-alpha probe -- curl -s -m 5 \
  -o /dev/null -w '%{http_code}\n' \
  http://api.team-bravo.svc.cluster.local:8080

# anybody else
kubectl run snoop -n team-bravo --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' http://api:8080
```

✓ `200` from the probe pod, `000` from anything else — including pods inside `team-bravo`.

### Step 21 — Lock down egress, and the DNS trap

```bash
# deny all egress from team-alpha...
kubectl apply -f network/04-deny-egress.yaml
kubectl exec -n team-alpha probe -- curl -s -m 5 \
  -o /dev/null -w '%{http_code}\n' http://api.team-bravo:8080

# ...now allow DNS back, and only DNS
kubectl apply -f network/05-allow-dns.yaml
kubectl exec -n team-alpha probe -- \
  nslookup api.team-bravo.svc.cluster.local
```

✓ Egress blocked, then `nslookup` works again once the DNS allow rule is applied.

---

# §06 · Secrets

Base64 is an encoding, not a lock.

### Step 22 — A Secret is a ConfigMap that mumbles

```bash
kubectl create secret generic bravo-db -n team-bravo \
  --from-literal=password='S3cr3t-P@ssw0rd'

kubectl get secret bravo-db -n team-bravo -o yaml

kubectl get secret bravo-db -n team-bravo \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

✓ The decoded password appears in your terminal. No key was involved.

### Step 23 — Now find it on the node's disk

```bash
minikube ssh -p k8s-security -- \
  "sudo grep -a -c 'S3cr3t-P@ssw0rd' \
   /var/lib/minikube/etcd/member/snap/db"

# see it in context
minikube ssh -p k8s-security -- \
  "sudo grep -a -o -m1 '.\{30\}S3cr3t-P@ssw0rd.\{15\}' \
   /var/lib/minikube/etcd/member/snap/db"
```

✓ `grep` returns 1 or more. The password is sitting in the etcd database file in plain text.

### Bonus — Encryption at rest, and its honest caveat

Skip if short on time. This recreates the cluster.

```bash
# stage the config, then recreate the cluster
cp secrets/encryption-config.yaml ~/.minikube/files/etc/ssl/certs/

minikube start -p k8s-security \
  --driver=docker --container-runtime=containerd \
  --cni=calico --cpus=4 --memory=6144 --disk-size=20g \
  --extra-config=apiserver.audit-policy-file=/etc/ssl/certs/audit-policy.yaml \
  --extra-config=apiserver.audit-log-path=- \
  --extra-config=apiserver.encryption-provider-config=/etc/ssl/certs/encryption-config.yaml

# rewrite existing secrets so they get encrypted
kubectl get secrets -A -o json | kubectl replace -f -
```

✓ `grep` now returns 0, but `kubectl` still shows the password. Both of those are correct.

A malformed encryption config stops the API server from starting. If the cluster hangs on `Waiting for apiserver` and every `kubectl` command then fails, run `./scripts/unbrick.sh`.

---

# §07 · Audit logging

Everything you did in the last 75 minutes was written down. Go and find it.

### Step 24 — Find your own container escape in the log

```bash
APISERVER=kube-apiserver-k8s-security

kubectl logs -n kube-system $APISERVER --since=90m \
  | grep '"resource":"pods"' | grep '"verb":"create"' \
  | tail -1 \
  | jq '{user: .user.username, pod: .objectRef.name,
         priv: .requestObject.spec.containers[0]
               .securityContext.privileged,
         hostPID: .requestObject.spec.hostPID}'
```

✓ You can see your own attack pod, with `privileged: true`, named and attributed to you.

### Step 25 — Who read the secret?

```bash
APISERVER=kube-apiserver-k8s-security

kubectl logs -n kube-system $APISERVER --since=90m \
  | grep '"kind":"Event"' \
  | grep '"resource":"secrets"' \
  | tail -5 \
  | jq -c '{t: .requestReceivedTimestamp, user: .user.username,
            verb: .verb, name: .objectRef.name,
            ns: .objectRef.namespace, code: .responseStatus.code}'
```

`scripts/audit-query.sh` wraps both of these if the quoting is painful in your shell.

✓ You can see both a successful read and the `403` from the probe pod in §04 — and no password anywhere.

---

## Teardown

```bash
./scripts/reset.sh
```

Only the `k8s-security` profile is touched; any other minikube clusters you have are left alone. Use this rather than `minikube delete` on its own, because a bad file left in `~/.minikube/files` is re-copied into *every* new cluster on every start — that is the "I deleted it and it's still broken" trap.

## Layout

| Path | What it is |
|---|---|
| `setup/tenants.yaml` | The two tenant namespaces. The `tenant=` labels are load-bearing — both NetworkPolicy and Kubewarden select namespaces by label, never by name. |
| `setup/quotas.yaml` | ResourceQuota and LimitRange. Cut from the workshop for time; included because real multitenancy needs them. |
| `policies/01-escape-pod.yaml` | The attack: `privileged`, `hostPID`, and a `hostPath` mount of `/`. |
| `policies/02-no-privileged.yaml` | First Kubewarden policy, in `monitor` mode. |
| `policies/02b-...-protect.yaml` | Same policy in `protect` mode, if the `kubectl patch` is awkward in your shell. |
| `policies/03-harden-tenants.yaml` | Four more policies: host namespaces, hostPath, privilege escalation, capabilities. **Verify the settings keys.** |
| `policies/04-escape-attempts.yaml` | Four attacks, one per door. With `03` applied, every one must be refused. |
| `rbac/00-probe.yaml` | A policy-compliant probe pod. Note the `securityContext` — once policy is enforced, manifests have to be written properly. |
| `rbac/01-tenant-developer.yaml` | Least-privilege tenant identity. Read what is *not* granted. |
| `network/01-workloads.yaml` | team-bravo's "internal only" API. |
| `network/02-default-deny.yaml` | Default-deny ingress. |
| `network/03-allow-alpha-probe.yaml` | One targeted allow rule. Read the AND-versus-OR warning in the comments. |
| `network/04-deny-egress.yaml` | Deny egress — this will break DNS, which is the lesson. |
| `network/05-allow-dns.yaml` | Allow DNS back. Both UDP *and* TCP on 53. |
| `secrets/encryption-config.yaml` | Bonus: encryption at rest, with an honest caveat about where the key lives. |
| `audit/audit-policy.yaml` | The API server audit policy, staged into the node at setup. |

## Scripts

`scripts/start.sh` builds the cluster — steps 1–5 in one command. `scripts/preflight.sh` verifies every version-sensitive claim in the deck. `scripts/token-probe.sh` and `scripts/audit-query.sh` wrap two commands whose quoting is painful to type live, especially in PowerShell.

`scripts/unbrick.sh` is the one to put on a card for your floaters. A malformed audit or encryption config stops the API server from starting, and the symptom is a cluster that hangs on `Waiting for apiserver` and then refuses every `kubectl` command. The script strips the offending flags from the static pod manifest; the kubelet notices and restarts the API server within about thirty seconds, with no rebuild. That turns a workshop-ending failure into a one-minute aside.

`scripts/reset.sh` is a full reset.

## Read this before you present

The deck was written without live access to the Kubewarden, cert-manager and Calico documentation, so a small number of strings in it are version-sensitive and **must be dry-run before you present**. `scripts/preflight.sh` checks all of them against a real cluster and prints what it actually finds.

The Kubewarden policy **settings keys** in `policies/03-harden-tenants.yaml` are the biggest risk. Key names are not consistent between policies, and several policies ignore an unknown key rather than erroring — which gives you a policy that reports `STATUS=active` and blocks nothing. `kwctl inspect` prints each policy's real settings schema, and step 7 of the preflight script runs the actual attacks to prove the denies happen.

The **cert-manager CRD flag** changed between chart versions (`--set crds.enabled=true` versus the older `--set installCRDs=true`). The **exact rejection message** on the "Flip the switch to protect" slide is reconstructed rather than copied from a live run — paste the real one in, because students pattern-match on error text and floaters triage faster with it. The **etcd data path** used in the Secrets section is minikube-specific. And minikube's bundled **Calico namespace** is `kube-system` on some versions and `calico-system` on others.

Budget half an hour for this, on one Apple-silicon Mac and one Windows laptop.

## A note on the attack

Section 03 has students escape a container onto the node and read the node's filesystem. This is standard defensive-security curriculum — it is on the CKS exam — and it runs on a throwaway cluster on the student's own laptop, immediately followed by shutting the same attack down. Say out loud that doing this on a cluster you do not own is a crime rather than a party trick. The reason to teach the attack at all is that you cannot defend against something you have never watched work.
