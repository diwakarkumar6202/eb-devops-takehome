# Answers — Part 5

## Q1. Migrating ~40 Ingresses from end-of-life ingress-nginx to the Gateway API, with no downtime

**Approach: run both side by side, move traffic per hostname, remove the old controller last.**

1. **Inventory first.** Export all 40 Ingresses and group them by the
   ingress-nginx annotations they use (rewrites/regex paths, TLS, auth,
   CORS, rate limits, body size/timeouts, `configuration-snippet`). Plain
   host/path routing converts easily; the annotations are the real work and the
   real risk.
2. **Pick and install a Gateway API implementation** (e.g. Envoy Gateway,
   Istio, Cilium, NGINX Gateway Fabric) **alongside** ingress-nginx, with its own
   load balancer IP. One `Gateway` owned by the platform team; app teams own
   their `HTTPRoute`s.
3. **Convert** with `ingress2gateway` as a starting point, then review each
   route by hand. Anything that relied on snippets or regex needs a deliberate
   equivalent (filters, policies) or a decision to drop it.
4. **Test before switching**: hit the new LB directly with
   `curl --resolve host:443:<new-ip>` and compare status codes, headers and
   redirects against the old path.
5. **Cut over in waves**, low-risk hosts first: lower DNS TTL in advance, then
   switch DNS per hostname (or weighted DNS). Watch error rates and latency on
   both controllers.
6. **Keep rollback cheap**: leave the old Ingress objects in place until each
   route has been stable for a while; rollback = point DNS back.
7. **Decommission** ingress-nginx only after its traffic metrics show zero.

**What I expect to break:**

- Regex paths / `rewrite-target` and anything using `configuration-snippet`
- Client IP and `X-Forwarded-*` headers (different proxy, different defaults)
- TLS secrets in another namespace (needs a `ReferenceGrant`); cert-manager
  needs Gateway API support enabled
- Default timeouts, body-size limits, websocket/gRPC behaviour
- Dashboards and alerts built on ingress-nginx metrics go blank
- Some long-lived connections drop when DNS moves — acceptable if clients retry,
  so check that first
