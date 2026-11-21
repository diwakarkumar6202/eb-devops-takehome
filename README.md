# Enterprise Bot — DevOps take-home

| Path | Part | What it is |
|---|---|---|
| `service/` | 1 | Flask app (`GET /`, `GET /healthz`), multi-stage non-root Dockerfile, `.dockerignore` |
| `chart/` | 2 | Helm chart: Deployment, ConfigMap, Service, Ingress (`demo.local`) |
| `setup.sh` | 3 | One command: kind cluster `demo` → ingress-nginx → build + load image → `helm upgrade --install demo` |
| `lab/` | 4 | Debug lab: fixed `broken-chart/`, `FINDINGS.md`, `part4-session.log`, `notes/reporter-repro/` |
| `ANSWERS.md` | 5 | ingress-nginx → Gateway API migration |
| `.github/workflows/ci.yml` | bonus | helm lint, shellcheck, image build, Trivy (fails on HIGH/CRITICAL) |

## Run it

Prerequisites: Docker, kind, kubectl, helm. Host ports **80/443 must be free**
(kind maps them to the ingress controller).

```bash
./setup.sh        # safe to run again; the second run is a no-op upgrade
```

Tested on Windows 11 + WSL2 Ubuntu, Docker Desktop 4.67, kind v0.24.0
(Kubernetes v1.31), Helm v3.22. Run it from a Linux shell (WSL/Linux/macOS).

## Verify

```bash
kubectl -n demo get pods,svc,ingress,configmap        # 2/2 pods Running
curl -H "Host: demo.local" http://localhost/          # {"app":"demo","pod":"demo-...","version":"0.1.0"}
curl -H "Host: demo.local" http://localhost/healthz   # {"status":"ok"} 200
```

Repeat the first curl a few times — `pod` alternates between the two replicas.

**Config follows the ConfigMap:**

```bash
kubectl -n demo patch configmap demo --type merge -p '{"data":{"APP_NAME":"patched"}}'
# within ~60-90s, without a restart:
curl -H "Host: demo.local" http://localhost/          # "app":"patched"
```

**Chart overrides:**

```bash
helm template demo chart/ --set replicaCount=3 | grep replicas:          # 3
helm template demo chart/ --set config.appName=foo | grep APP_NAME       # "foo"
```

**Lab:** `cd lab && ./scenario.sh up && ./scenario.sh verify` — see
`lab/FINDINGS.md` for results (7/11 on my cluster, with the remaining reporter
failure traced to the image).

## Design decisions

- **Config via ConfigMap, two ways.** `envFrom` provides `APP_NAME`/`VERSION`
  as env vars (as the brief requires), and the same ConfigMap is mounted at
  `/etc/app-config`. The app reads the mounted file per request if present and
  falls back to the env var. Reason: env vars are fixed at container start, so a
  `kubectl patch` of the ConfigMap would otherwise not reach `GET /` without a
  restart; mounted ConfigMap files are updated by the kubelet. Helm changes also
  roll the pods via a `checksum/config` annotation. Outside Kubernetes
  (`docker run -e ...`) it's plain env vars.
- **Hardening:** non-root UID 10001 (numeric, so `runAsNonRoot` can verify it),
  `readOnlyRootFilesystem` with an `emptyDir` for `/tmp`, all capabilities
  dropped, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`.
- **Image:** multi-stage (pip and build cache stay in the builder), pinned base
  `python:3.12.16-slim-trixie`, gunicorn with 2 workers. The runtime stage runs
  `apt-get upgrade` so Debian security fixes published after the base image
  (e.g. zlib1g CVE-2026-85091 that Trivy flagged) are included — at the cost of
  builds not being bit-for-bit reproducible.
- **setup.sh** is idempotent by construction: cluster created only if missing,
  everything else is `kubectl apply` / `helm upgrade --install`. ingress-nginx is
  pinned (`controller-v1.11.3`), not `main`. Timeouts are 600s because image
  pulls from registry.k8s.io took 5+ minutes on my network; on a fast network
  the waits return in seconds. Helm install retries briefly to ride out the
  ingress-nginx admission webhook warming up.

## Resource requests and limits

| | request | limit | Why |
|---|---|---|---|
| CPU | 50m | 250m | Idle CPU measured at ~0.02% (`docker stats`). 50m is enough to schedule and serve light traffic; the limit stops a runaway pod starving neighbours, accepting some throttling under load. |
| Memory | 96Mi | 192Mi | Measured **~54 MiB** idle with 2 gunicorn workers. Request = idle + headroom for traffic; limit ≈ 2× request so normal spikes don't get OOMKilled, while a leak still gets contained. |

These are starting points from one idle measurement, not load-tested numbers
(see below).

## What I deliberately skipped, and the risk

| Skipped | Risk |
|---|---|
| TLS on the Ingress | Plain HTTP; fine for local kind, not for anything real |
| Load testing to size resources | Requests/limits may be wrong under real traffic (throttling or OOM) |
| HPA, PodDisruptionBudget, anti-affinity | 2 replicas on one node; a node drain or burst takes the service down |
| NetworkPolicy | Any pod in the cluster can reach the service |
| Immutable image tags | `setup.sh` reuses tag `0.1.0`; rebuilding the same tag does not restart running pods |
| Config reloader (e.g. stakater/Reloader) | `kubectl patch` changes reach pods after ~60–90s via the volume, and replicas update at slightly different times |
| Liveness distinct from readiness | Both hit `/healthz`; a dependency-aware readiness check isn't needed for this app yet |
| Lab: reporter | Blocked by a 1 KiB read limit in the lab image (`lab/FINDINGS.md`); asked the team |

## What I'd change for production

- Push images to a registry with immutable tags or digests; sign them (cosign)
  and keep the Trivy gate in CI.
- Deploy via GitOps (Argo CD) instead of a script; separate values per
  environment.
- TLS via cert-manager; move to the Gateway API (ingress-nginx is end-of-life —
  see `ANSWERS.md`).
- HPA + PDB + topology spread across nodes/zones; resources tuned from real
  metrics (Prometheus) rather than one idle sample.
- NetworkPolicies, Pod Security Admission (`restricted`) on the namespace.
- Structured logs, metrics endpoint, alerts on error rate and latency.

## How I used AI

I used **Claude (Claude Code)** throughout:

- **Understanding the brief** and planning the order of work.
- **Generating content:** the service, Dockerfile, Helm chart, `setup.sh`, the
  CI workflow, and drafts of `FINDINGS.md`, `ANSWERS.md` and this README, which
  I used as a reference and reviewed.
- **Debugging the lab:** I ran every command in the recorded session and read
  the output; Claude helped interpret it, suggested the next command, and
  proposed the chart fixes. The local reporter reproduction
  (`lab/notes/reporter-repro/`) was run with Claude outside the recording.
- **Environment setup** on Windows/WSL (kubectl version skew, git line endings,
  kubeconfig isolation from my other clusters).

What had to be corrected along the way:

- `setup.sh` timed out on my slow network (registry.k8s.io pulls took 5+ min);
  diagnosed from events and raised the waits.
- The first base image failed the Trivy gate (zlib1g HIGH CVE); bumped the base
  tag and applied Debian security updates.
- Early lab edits weren't saved before re-running, so the same helm error
  repeated — caught by reading the output again.
- Several hypotheses for the reporter (RBAC, CPU, response size) were tested
  and ruled out before the real cause was found.
