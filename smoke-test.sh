#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke-test.sh — Verify the local-dev kind cluster is working correctly.
#
# Tests:
#   1. DNS wildcard resolution
#   2. nginx ingress HTTP → HTTPS redirect
#   3. nginx ingress HTTPS with cert-manager TLS
#   4. Istio ingress gateway HTTP
#   5. PersistentVolumeClaim provisioning (local-path)
#   6. Istio sidecar injection
#
# Run:
#   ./smoke-test.sh
# ---------------------------------------------------------------------------
set -euo pipefail

# Unset host proxy variables — they intercept *.localhost.localdomain traffic
# even when the domain is listed in NO_PROXY (wildcard matching quirk in curl).
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY

CLUSTER_NAME="local-dev"
NS="smoke-test"
PASS=0
FAIL=0

# ── helpers ────────────────────────────────────────────────────────────────

log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
pass() { echo -e "  \033[1;32m✓ $*\033[0m"; PASS=$((PASS + 1)); }
fail() { echo -e "  \033[1;31m✗ $*\033[0m"; FAIL=$((FAIL + 1)); }
info() { echo -e "    $*"; }

require_cluster() {
  kubectl config current-context 2>/dev/null | grep -q "kind-${CLUSTER_NAME}" \
    || { echo "Switch to kind-${CLUSTER_NAME} first: kubectl config use-context kind-${CLUSTER_NAME}"; exit 1; }
}

# curl wrapper: always bypass host proxy variables
kcurl() { curl --noproxy '*' "$@"; }

wait_for() {
  local desc="$1"; shift
  local max=60 i=0
  while ! eval "$@" &>/dev/null; do
    ((i++))
    [[ $i -ge $max ]] && { fail "${desc} (timed out after ${max}s)"; return 1; }
    sleep 1
  done
}

# ── setup ──────────────────────────────────────────────────────────────────

log "Preflight"
require_cluster

if ! kubectl get namespace "${NS}" &>/dev/null; then
  kubectl create namespace "${NS}"
fi
kubectl label namespace "${NS}" istio-injection=enabled --overwrite >/dev/null

# Ensure smoke resources are deployed
kubectl apply -n "${NS}" -f - >/dev/null <<'EOF'
# Echo server
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:latest
          args: ["-text=hello-from-kind"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: echo
spec:
  selector:
    app: echo
  ports:
    - port: 80
      targetPort: 5678
---
# nginx Ingress with TLS
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo
  annotations:
    cert-manager.io/cluster-issuer: local-ca-issuer
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [echo.localhost.localdomain]
      secretName: echo-tls
  rules:
    - host: echo.localhost.localdomain
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: echo
                port:
                  number: 80
---
# Istio Gateway
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: echo-gw
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts: [echo-istio.localhost.localdomain]
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: echo
spec:
  hosts: [echo-istio.localhost.localdomain]
  gateways: [echo-gw]
  http:
    - route:
        - destination:
            host: echo
            port:
              number: 80
---
# PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: echo-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Mi
EOF

info "Waiting for echo pod..."
kubectl rollout status deployment/echo -n "${NS}" --timeout=5m >/dev/null
pass "Smoke resources deployed"

# ── 1. DNS ─────────────────────────────────────────────────────────────────

log "1. DNS wildcard (*.localhost.localdomain)"

if getent hosts echo.localhost.localdomain | grep -qE '127\.0\.0\.1|::1'; then
  RESOLVED=$(getent hosts echo.localhost.localdomain | awk '{print $1}' | head -1)
  pass "Resolves → ${RESOLVED}"
else
  fail "echo.localhost.localdomain did not resolve"
fi

# ── 2. nginx HTTP redirect ─────────────────────────────────────────────────

log "2. nginx ingress — HTTP → HTTPS redirect (port 80)"

HTTP_STATUS=$(kcurl -so /dev/null -w '%{http_code}' -4 http://echo.localhost.localdomain/ 2>/dev/null || echo "000")
if [[ "${HTTP_STATUS}" == "308" || "${HTTP_STATUS}" == "301" || "${HTTP_STATUS}" == "302" ]]; then
  pass "HTTP redirect (${HTTP_STATUS})"
else
  fail "Expected 3xx redirect, got ${HTTP_STATUS}"
fi

# ── 3. nginx HTTPS ────────────────────────────────────────────────────────

log "3. nginx ingress — HTTPS (port 443)"

# Wait for cert-manager to issue the TLS secret
if wait_for "TLS secret issued" "kubectl get secret echo-tls -n ${NS}"; then
  # Retry HTTPS: nginx may briefly return 503 while endpoint becomes active
  HTTPS_BODY=""
  for i in $(seq 1 20); do
    HTTPS_BODY=$(kcurl -sk -4 https://echo.localhost.localdomain/ 2>/dev/null || echo "")
    [[ "${HTTPS_BODY}" == *"hello-from-kind"* ]] && break
    sleep 2
  done

  if [[ "${HTTPS_BODY}" == *"hello-from-kind"* ]]; then
    pass "HTTPS → 'hello-from-kind'"
  else
    fail "HTTPS body unexpected after retries: '${HTTPS_BODY}'"
  fi

  # Check TLS cert details
  CERT_CN=$(kcurl -sk -4 -v https://echo.localhost.localdomain/ 2>&1 \
    | grep -i "subject:" | head -1 || true)
  info "TLS: ${CERT_CN}"
else
  fail "TLS secret not issued within 60s"
fi

# ── 4. Istio ingress gateway ───────────────────────────────────────────────

log "4. Istio ingress gateway — HTTP (port 8080)"

ISTIO_BODY=$(kcurl -s -4 http://echo-istio.localhost.localdomain:8080/ 2>/dev/null || echo "")
if [[ "${ISTIO_BODY}" == *"hello-from-kind"* ]]; then
  pass "Istio gateway → 'hello-from-kind'"
else
  fail "Istio gateway body unexpected: '${ISTIO_BODY}'"
fi

# ── 5. PVC provisioning ────────────────────────────────────────────────────

log "5. PersistentVolumeClaim — local-path provisioner"

# Bind a PVC by creating a pod that uses it
kubectl apply -n "${NS}" -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: pvc-checker
spec:
  restartPolicy: Never
  containers:
    - name: checker
      image: busybox:latest
      command: [sh, -c, "echo kind-pvc-ok > /data/test.txt && cat /data/test.txt"]
      volumeMounts:
        - mountPath: /data
          name: data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: echo-data
EOF

PVC_STATUS=""
for i in $(seq 1 60); do
  PVC_STATUS=$(kubectl get pvc echo-data -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "${PVC_STATUS}" == "Bound" ]] && break
  sleep 1
done

if [[ "${PVC_STATUS}" == "Bound" ]]; then
  pass "PVC bound (local-path → /var/local-path-provisioner)"
  # Wait for pod to complete
  kubectl wait pod/pvc-checker -n "${NS}" --for=condition=Ready --timeout=60s >/dev/null 2>&1 || true
  PVC_DATA=$(kubectl logs pvc-checker -n "${NS}" 2>/dev/null || echo "")
  if [[ "${PVC_DATA}" == *"kind-pvc-ok"* ]]; then
    pass "Pod wrote and read data from PVC"
  else
    fail "Could not verify data in PVC"
  fi
else
  fail "PVC not bound after 60s (status: ${PVC_STATUS})"
fi

# ── 6. Istio sidecar injection ─────────────────────────────────────────────

log "6. Istio sidecar injection"

# Istio 1.23+ uses native sidecar (initContainer with restartPolicy:Always)
# on Kubernetes 1.28+; check both containers and initContainers.
ALL_CONTAINERS=$(kubectl get pod -n "${NS}" -l app=echo -o jsonpath=\
'{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}' \
2>/dev/null || echo "")
if echo "${ALL_CONTAINERS}" | grep -q "istio-proxy"; then
  pass "istio-proxy sidecar injected (containers: [${ALL_CONTAINERS}])"
else
  fail "istio-proxy NOT found in pod (containers: [${ALL_CONTAINERS}])"
fi

# ── summary ────────────────────────────────────────────────────────────────

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Results: \033[1;32m${PASS} passed\033[0m / \033[1;31m${FAIL} failed\033[0m"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "${FAIL}" -gt 0 ]]; then
  echo
  echo "  Resources left in namespace '${NS}' for investigation:"
  echo "    kubectl get pods -A"
  echo "    kubectl describe ingress echo -n ${NS}"
  echo "    kubectl describe certificate echo-tls -n ${NS}"
  echo "    kubectl get events -n ${NS} --sort-by=.lastTimestamp"
  echo
  echo "  Clean up manually: kubectl delete namespace ${NS}"
  exit 1
else
  log "Cleanup — removing namespace '${NS}' (all tests passed)"
  kubectl delete namespace "${NS}" >/dev/null
  pass "Namespace '${NS}' deleted"
fi
