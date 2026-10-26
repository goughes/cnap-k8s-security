# Securing Multitenant Kubernetes — CNAP workshop

Companion manifests for the CNAP workshop *Securing Multitenant Kubernetes* (part 2 of the Docker & Kubernetes series). Everything here runs on a throwaway local minikube cluster.

The workshop builds five layers of defence on one cluster shared by two tenants, in this order: admission control, RBAC, network policy, secrets, and audit logging. You start by escaping a container onto the node, then close every door you walked through.

## Read this first if you are presenting

The deck was written without live access to the Kubewarden, cert-manager and Calico documentation, so a small number of strings in it are version-sensitive and **must be dry-run before you present**. `scripts/preflight.sh` checks all of them against a real cluster and prints what it actually finds.

The five things to verify, in rough order of risk:

The Kubewarden policy **settings keys** in `policies/03-harden-tenants.yaml` are the biggest risk. Key names are not consistent between policies, and several policies ignore an unknown key rather than erroring — which gives you a policy that reports `STATUS=active` and blocks nothing. `kwctl inspect` prints each policy's real settings schema, and step 7 of the preflight script runs the actual attacks to prove the denies happen.

The **cert-manager CRD flag** changed between chart versions (`--set crds.enabled=true` versus the older `--set installCRDs=true`). The **exact rejection message** on the "Flip the switch to protect" slide is reconstructed rather than copied from a live run — paste the real one in, because students pattern-match on error text and floaters triage faster with it. The **etcd data path** used in the Secrets section is minikube-specific. And minikube's bundled **Calico namespace** is `kube-system` on some versions and `calico-system` on others.

Budget half an hour for this, on one Apple-silicon Mac and one Windows laptop.

## Setup

```bash
git clone <this repo>
cd k8s-security-workshop
./scripts/start.sh
```

`start.sh` stages the audit policy into `~/.minikube/files` (minikube copies anything there into the node when the cluster starts), validates it before booting, then creates the cluster with Calico and API audit logging enabled, and makes the two tenant namespaces.

Two prerequisites bite people:

**Docker Desktop memory must be at least 6 GB.** minikube with the docker driver runs inside Docker Desktop and cannot be given more memory than Docker Desktop itself has. Settings → Resources → Memory. On Windows/WSL 2 set it in `%UserProfile%\.wslconfig` and run `wsl --shutdown`. A 4 GB cluster works but is tight: `MEM=4096 ./scripts/start.sh`.

**Do the setup at home, not at the venue.** The cluster pulls Calico, cert-manager and Kubewarden — several hundred megabytes. Thirty laptops doing that simultaneously on venue Wi-Fi will not finish.

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

`scripts/start.sh` builds the cluster. `scripts/preflight.sh` verifies every version-sensitive claim in the deck. `scripts/token-probe.sh` and `scripts/audit-query.sh` wrap two commands whose quoting is painful to type live, especially in PowerShell.

`scripts/unbrick.sh` is the one to put on a card for your floaters. A malformed audit or encryption config stops the API server from starting, and the symptom is a cluster that hangs on `Waiting for apiserver` and then refuses every `kubectl` command. The script strips the offending flags from the static pod manifest; the kubelet notices and restarts the API server within about thirty seconds, with no rebuild. That turns a workshop-ending failure into a one-minute aside.

`scripts/reset.sh` is a full reset. Use it rather than `minikube delete` on its own, because a bad file left in `~/.minikube/files` is re-copied into *every* new cluster on every start — that is the "I deleted it and it's still broken" trap.

## Teardown

```bash
./scripts/reset.sh
```

Only the `k8s-security` profile is touched; any other minikube clusters you have are left alone.

## A note on the attack

Section 03 has students escape a container onto the node and read the node's filesystem. This is standard defensive-security curriculum — it is on the CKS exam — and it runs on a throwaway cluster on the student's own laptop, immediately followed by shutting the same attack down. Say out loud that doing this on a cluster you do not own is a crime rather than a party trick. The reason to teach the attack at all is that you cannot defend against something you have never watched work.
