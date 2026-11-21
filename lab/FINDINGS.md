# Findings — Part 4 debug lab

Recording: `lab/part4-session.log` (`script -q`). Each fix is a separate commit
under `lab/broken-chart/` so the git history lines up with the entries below.

**Summary:** I found and fixed **seven** chart defects (the brief says six — I
list everything I changed rather than force-fit the count). Final state on my
cluster: **7/11 verify checks pass**. The reporter is still not Ready; I traced
that to a 1 KiB response-body limit inside the image itself (see
"Unresolved" at the end). All other workloads are Ready, and a manual in-cluster
probe shows backend and gateway (`backend":"ok"`) working end to end.

Order below is the order I hit them in — several were masked by the one before.

---

## Defect 1 — migrate Job uses `restartPolicy: Always`

**Symptom** (from `./scenario.sh up`):

```
Release "debug-lab" does not exist. Installing it now.
Error: 1 error occurred:
        * Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"
```
```
$ helm -n debug-lab history debug-lab
REVISION  STATUS  DESCRIPTION
1         failed  Release "debug-lab" failed: 1 error occurred: * Job.batch "migrate" is invalid: ...
```

**Cause:** A Job must be able to run to completion. `Always` restarts the
container even after a successful exit, so the API server rejects it for Jobs.
`kubectl explain job.spec.template.spec.restartPolicy` lists `Always` because it
documents the generic Pod field — "In some contexts, only a subset of those
values may be permitted"; the Job controller is one of those contexts.
Because the API rejected the Job, the whole Helm release was marked `failed`,
which masked everything else (Helm does not roll back without `--atomic`, so
the Deployments were created anyway — that's how Defect 2 showed up).

**Fix:** `restartPolicy: Never` in `templates/migrate-job.yaml`.
`Never` over `OnFailure`: with `Never`, each retry (up to `backoffLimit: 2`) is a
new pod and failed pods are kept, so `kubectl logs` of every failed attempt is
still available. For a database migration that evidence matters more than the
small overhead of extra pods.

**How I found it:** The helm error on the very first `scenario.sh up` named the
field. Confirmed release state with `helm history`, checked what had been
created with `kubectl get job,deploy,pods`, located the line with
`grep -n restartPolicy`, and checked the API docs with `kubectl explain`.

---

## Defect 2 — `runAsNonRoot: true` with an image whose USER is non-numeric

**Symptom:** All five Deployments' pods stuck:

```
$ kubectl -n debug-lab get pods
backend-794fdd8bbd-gzlxd   0/1   CreateContainerConfigError   0   4m1s
gateway-6ddf8cd98d-jfmnj   0/1   CreateContainerConfigError   0   4m1s
...
$ kubectl -n debug-lab describe pod -l app=backend
  Warning  Failed  ... kubelet  Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```

**Cause:** The chart enforces `runAsNonRoot: true` (good), but the image
declares `USER nonroot` — a name, not a UID. The kubelet does not read the
image's `/etc/passwd`, so it cannot prove the user isn't UID 0 and refuses to
create the container (fail-safe).

**Fix:** Kept `runAsNonRoot: true` and added the numeric identity:
`runAsUser`/`runAsGroup` from a single value `common.runAsUser: 65532`, applied
to all six workloads (5 Deployments + the Job). Rejected alternative: removing
`runAsNonRoot` — that hides the symptom by weakening security.

The UID was read from the image, not guessed:

```
$ docker image inspect docker.io/ebinterview/eb-debug-app:1.0.1 --format '{{.Config.User}}'
nonroot
$ docker create --name ebimg docker.io/ebinterview/eb-debug-app:1.0.1
$ docker cp ebimg:/etc/passwd - | tar -xO
root:x:0:0:root:/root:/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin
nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin
```

**How I found it:** `get pods` → `CreateContainerConfigError` on every pod (same
image, same securityContext → shared cause) → `describe pod` Events gave the
exact reason → the image has no shell, so I used `docker create` + `docker cp`
to read its `/etc/passwd` without running it. Verified the render with
`helm template ... | grep -c runAsUser` → `6`.

---

## Defect 3 — worker needs a writable `/var/cache/app` on a read-only rootfs

**Symptom:**

```
worker-7d8d5bd7c6-48h2l   0/1   CrashLoopBackOff   4 (11s ago)   96s

$ kubectl -n debug-lab logs deploy/worker --previous
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)

$ kubectl -n debug-lab describe pod -l app=worker
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
```

**Cause:** `readOnlyRootFilesystem: true` (good hardening) but the worker must
create its cache directory at startup. Exit code 1 → app-level failure, so the
logs, not the kubelet, hold the answer.

**Fix:** Mounted an `emptyDir` (`sizeLimit: 64Mi`) at `/var/cache/app` in
`templates/worker.yaml`. Root filesystem stays read-only; only the cache path is
writable; `emptyDir` is ephemeral, which suits a cache. Rejected alternatives:
`readOnlyRootFilesystem: false` (weakens the whole container for one path);
`CACHE_DIR` alone (every path is read-only, so it would still need a volume).

**How I found it:** `get pods` → CrashLoopBackOff → `logs --previous` (the
crashed attempt) gave an explicit message → `describe` confirmed exit code 1.

---

## Defect 4 — metrics CPU limit exceeds the namespace LimitRange

**Symptom:** No new metrics pod at all after the upgrade:

```
$ kubectl -n debug-lab get rs -l app=metrics
NAME                 DESIRED   CURRENT   READY   AGE
metrics-6b94df8c49   1         0         0       97s

$ kubectl -n debug-lab describe rs -l app=metrics
Conditions:
  ReplicaFailure   True    FailedCreate
Events:
  Warning  FailedCreate  replicaset-controller  Error creating: pods "metrics-6b94df8c49-vr7xz" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

**Cause:** `values.yaml` gave metrics `requests.cpu: "2"`, `limits.cpu: "4"`.
The environment's LimitRange (`cluster-state/limits.yaml`, not to be modified)
caps each container at 1 CPU. Admission rejects the pod before it exists, which
is why `describe pod` showed nothing — the error lives on the ReplicaSet.

**Fix:** `requests.cpu: 50m`, `limits.cpu: 200m` — same as the other services
running the same image in the same `api` mode. Nothing indicated metrics needs
2–4 CPUs, so I matched its siblings rather than setting the limit to exactly
`"1"` just to squeeze under the cap.

**How I found it:** Noticed metrics was the only Deployment with no new pod →
`get rs` showed `CURRENT 0` → `describe rs` showed `FailedCreate` → compared
with `kubectl get limitrange -o yaml`.

**Environment note:** On my first `scenario.sh up`, the LimitRange itself
failed to apply — `kubectl apply -f cluster-state/` processes files
alphabetically, so `limits.yaml` ran before `namespace.yaml`:
```
namespace/debug-lab created
Error from server (NotFound): error when creating "cluster-state/limits.yaml": namespaces "debug-lab" not found
```
It applied on the next `up`. Because LimitRanges are only enforced at pod
creation, the original metrics pod (created before the LimitRange existed)
slipped through; only the new ReplicaSet exposed the defect. I verified with
`kubectl -n debug-lab get limitrange` before trusting later results.

---

## Defect 5 — app listens on 8081; chart assumes 8080 everywhere

**Symptom:** After Defect 2, pods ran but never became Ready:

```
Warning  Unhealthy  pod/backend-548575964-cw2nx   Readiness probe failed: Get "http://10.244.0.16:8080/healthz": dial tcp 10.244.0.16:8080: connect: connection refused

$ kubectl -n debug-lab logs deploy/backend
eb-debug-app 2.0.0 starting: mode=api pod=backend-548575964-cw2nx listening on :8081 (image default is 8081; set PORT to override)
```

**Cause:** The chart's `common.port: 8080` drives containerPort, the readiness
probe and the Service `targetPort`, but nothing told the app to listen there.
The image defaults to 8081. "Connection refused" (not a timeout, not an HTTP
error) = nothing listening on that port.

**Fix:** Set `PORT` from `{{ .Values.common.port }}` in all five serving
Deployments (not the Job — it doesn't serve). Rejected alternative: changing
`common.port` to 8081 — that keeps the chart dependent on an undocumented image
default that can change in the next release. Now one value drives the app,
probe, containerPort and Service.

**How I found it:** Readiness events said `connection refused` on :8080 → app
logs said `listening on :8081` and named the override.

---

## Defect 6 — RoleBinding grants the reporter's Role to the `default` ServiceAccount

**Symptom:**

```
$ kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter
no

$ kubectl -n debug-lab get rolebinding reporter-read -o yaml
subjects:
- kind: ServiceAccount
  name: default
  namespace: debug-lab

reporter log:
pod list failed: kubernetes API returned HTTP 403: ... "pods is forbidden: User \"system:serviceaccount:debug-lab:reporter\" cannot list resource \"pods\" in API group \"\" in the namespace \"debug-lab\""
```

**Cause:** The Role (`get`, `list` on pods) is correct, but it's bound to
`default`, while the reporter pod runs as `serviceAccountName: reporter`. This
fails twice: the reporter gets nothing, and every other pod using `default`
silently gets pod-read access (least-privilege violation).

**Fix:** RoleBinding subject (and the ServiceAccount name) now come from
`.Values.reporter.serviceAccountName`, the same value the Deployment uses, so
they can't drift apart again.

**How I found it:** `verify` flagged it; reproduced with `kubectl auth can-i
--as=...`; read the RoleBinding; the reporter's own log showed the 403 with its
identity. After the fix: `can-i` → `yes`, and the reporter's 403s stopped at
the moment of the upgrade (11:20:47 in the log).

---

## Defect 7 — gateway `BACKEND_URL` points at the `default` namespace

**Symptom:**

```
gateway-665b4cc5d-b97wm   0/1   Running

readiness failed: backend not reachable: GET http://backend.default.svc:8080/healthz: ... dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host
GET /healthz -> 503

$ kubectl -n debug-lab get deploy gateway -o jsonpath='{.spec.template.spec.containers[0].env}'
[... {"name":"BACKEND_URL","value":"http://backend.default.svc:8080"} ...]
```

**Cause:** Backend lives in `debug-lab`; `backend.default.svc` does not exist.
The gateway's readiness checks its dependency, so it returned 503 and never
became Ready.

**Fix:** `BACKEND_URL: "http://backend:8080"`. The short Service name resolves
via the pod's DNS search path to the pod's own namespace, so the chart works in
whatever namespace it's installed into — rather than swapping one hardcoded
namespace for another.

**How I found it:** Used `kubectl logs -l app=gateway --prefix` to read the
*new* pod (`logs deploy/gateway` had picked the old 8081 pod during the
rollout), which named the failing hostname; confirmed the env var with
jsonpath. Verified after the fix with an in-cluster probe:

```
GATEWAY:
{"app":"gateway","backend":"ok","backend_url":"http://backend:8080","pod":"gateway-7cb875975c-wdprv","self":"ok","version":"2.0.0"}
```

Design note: gateway readiness depending on backend means a backend outage
pulls every gateway out of its Service — turning a partial outage into a full
one. Worth discussing; I left the app behaviour as is.

---

## Unresolved — reporter: `parse pod list: unexpected end of JSON input`

**Symptom** (after Defect 6 was fixed — the 403s stop, this starts):

```
pod list failed: parse pod list: unexpected end of JSON input
GET /healthz -> 503

$ curl -sS -i localhost:8082/healthz     (port-forward to the reporter pod)
HTTP/1.1 503 Service Unavailable
{"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}

$ kubectl -n debug-lab get endpoints reporter
reporter   <none>
```

**What I ruled out (in the recording):**

| Hypothesis | Test | Result |
|---|---|---|
| RBAC / token / network / API | Ran the same request from a pod using the `reporter` ServiceAccount (`curlimages/curl`) | `HTTP/2 200`, `BODY_BYTES=103773` — the API serves the full PodList to that identity |
| Bloated pod objects | `jq` sizes per pod | ~6 KB each, 7 pods — normal |
| A missing env var / setting | `grep` over the binary (`docker cp ebimg:/eb-debug-app`) | Only `APP_MODE APP_NAME BACKEND_URL CACHE_DIR NAMESPACE PORT MIGRATE_SECONDS`; no CLI flags |
| CPU throttling | Temporary `kubectl set resources deploy/reporter --limits=cpu=1` (reverted by the next `scenario.sh up`) | Same error |

**Root cause (found outside the recording):** I ran the lab image locally
against a small fake Kubernetes API server (Python, TLS, mounted fake
ServiceAccount files), varying one thing at a time:

| PodList body | Result |
|---|---|
| 1011 bytes | `{"namespace":"test","pods":7}` ✅ |
| 1039 bytes | `parse pod list: unexpected end of JSON input` ❌ |
| 843 bytes, sent in two writes 0.5 s apart | ✅ (it reads the stream fully — not a single-`Read()` bug) |
| with / without `Content-Length` | same 1 KiB cutoff |
| container memory none / 64m / 128m / 256m / 512m | fails every time |

The reporter in `eb-debug-app:1.0.1` parses at most **1024 bytes** of the pod
list. A single real pod is ~6 KB, so on any real cluster the list is truncated,
readiness stays 503 and `/report` fails. With the image/tag fixed and no
setting for the limit, I don't believe this is fixable from the chart — I've
asked the team whether it's intended.

**What I'd try next:** confirm with the image owners (or a newer tag) that the
read limit is a bug; if a chart-side workaround were acceptable, the only
lever I can see is reducing the response the reporter receives (e.g. a
filtering proxy in front of the API), which I would not ship without agreement.

---

## Other observations

- **`verify`'s in-cluster checks vs. reality.** My final recorded `verify`
  still shows `backend does not answer` and `gateway /status does not report
  backend=ok`, yet a manual probe from a busybox pod in the same namespace
  returns `{"status":"ok"}` from backend and `"backend":"ok"` from gateway.
  Without a delay, my manual probe also lost the backend/gateway output: on my
  (slow, WSL2) machine `kubectl run -i` attached after those requests had
  already printed. I suspect the same attach race in `verify`, but I have not
  proven it — I'd confirm by re-running `verify` on a faster machine.
- **Slow image pulls** on my network (one image waited 5m21s) explained some
  `ContainerCreating` delays; I checked events before treating anything as a
  defect.
- **Rolling updates kept old broken pods** (e.g. `CreateContainerConfigError`)
  around until new pods became Ready — expected with a 1-replica Deployment,
  not a separate defect. It also meant `kubectl logs deploy/X` sometimes picked
  the old pod; `logs -l app=X --prefix` avoided that.
