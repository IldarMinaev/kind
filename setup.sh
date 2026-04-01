#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — Create / update / recreate a local kind Kubernetes cluster with:
#   - nginx ingress controller  (host ports 80/443)
#   - Istio service mesh + ingress gateway (host ports 8080/8443)
#   - cert-manager with a self-signed ClusterIssuer
#   - local-path-provisioner for persistent host storage
#   - DNS wildcard *.localhost.localdomain → 127.0.0.1 via NetworkManager/dnsmasq
#
# Usage:
#   ./setup.sh             — create cluster (skip if exists) + install/upgrade all components
#   ./setup.sh --recreate  — delete cluster and recreate it from scratch (keeps host storage)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"

CLUSTER_NAME="local-dev"
ISTIO_VERSION="1.23.3"
CERT_MANAGER_VERSION="v1.16.2"
STORAGE_ROOT="/var/local-path-provisioner"

RECREATE=false
for arg in "$@"; do
  case "$arg" in
    --recreate) RECREATE=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ── helpers ────────────────────────────────────────────────────────────────

log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ! $*\033[0m"; }
die()  { echo -e "\033[1;31m  ✗ $*\033[0m" >&2; exit 1; }

require() {
  command -v "$1" &>/dev/null || die "'$1' not found. Install it first (dnf install $1)."
}

wait_for_rollout() {
  local ns="$1" deploy="$2"
  kubectl rollout status deployment/"${deploy}" -n "${ns}" --timeout=5m
}

# ── prerequisites ──────────────────────────────────────────────────────────

log "Checking prerequisites"
require kind
require kubectl
require helm
require docker
ok "kind, kubectl, helm, docker — all found"

# ── istioctl: find or download ─────────────────────────────────────────────

ISTIOCTL="$(command -v istioctl 2>/dev/null || true)"

if [[ -z "${ISTIOCTL}" ]]; then
  ISTIO_BIN="${SCRIPT_DIR}/istio-${ISTIO_VERSION}/bin/istioctl"
  if [[ -x "${ISTIO_BIN}" ]]; then
    ISTIOCTL="${ISTIO_BIN}"
    ok "Found local istioctl at ${ISTIO_BIN}"
  else
    log "Downloading istioctl ${ISTIO_VERSION}"
    curl -sSL https://istio.io/downloadIstio \
      | ISTIO_VERSION="${ISTIO_VERSION}" TARGET_ARCH=x86_64 sh - 2>&1
    ISTIOCTL="${SCRIPT_DIR}/istio-${ISTIO_VERSION}/bin/istioctl"
    ok "istioctl downloaded to ${ISTIOCTL}"
    warn "Add to PATH permanently: export PATH=\"${SCRIPT_DIR}/istio-${ISTIO_VERSION}/bin:\$PATH\""
  fi
fi
export PATH="$(dirname "${ISTIOCTL}"):${PATH}"

# ── DNS check ─────────────────────────────────────────────────────────────

log "Checking DNS: *.localhost.localdomain → 127.0.0.1 / ::1"

if getent hosts test.localhost.localdomain &>/dev/null; then
  ok "DNS wildcard resolves: $(getent hosts test.localhost.localdomain)"
else
  warn "*.localhost.localdomain does not resolve."
  warn "Run the following once as root, then re-run this script:"
  echo
  echo "  sudo mkdir -p /etc/NetworkManager/conf.d /etc/NetworkManager/dnsmasq.d"
  echo "  echo -e '[main]\ndns=dnsmasq' | sudo tee /etc/NetworkManager/conf.d/dnsmasq.conf"
  echo "  echo 'address=/.localhost.localdomain/127.0.0.1' | sudo tee /etc/NetworkManager/dnsmasq.d/localhost-localdomain.conf"
  echo "  sudo systemctl reload NetworkManager"
  echo
  die "Fix DNS first."
fi

# ── storage root ───────────────────────────────────────────────────────────

log "Checking host storage root: ${STORAGE_ROOT}"

if [[ -d "${STORAGE_ROOT}" ]]; then
  ok "${STORAGE_ROOT} exists"
else
  die "${STORAGE_ROOT} does not exist. Run: sudo mkdir -p ${STORAGE_ROOT} && sudo chmod 777 ${STORAGE_ROOT}"
fi

# ── kind cluster ───────────────────────────────────────────────────────────

CLUSTER_EXISTS=false
kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$" && CLUSTER_EXISTS=true

if [[ "${RECREATE}" == "true" && "${CLUSTER_EXISTS}" == "true" ]]; then
  log "Deleting existing cluster '${CLUSTER_NAME}' (--recreate)"
  kind delete cluster --name "${CLUSTER_NAME}"
  CLUSTER_EXISTS=false
fi

if [[ "${CLUSTER_EXISTS}" == "false" ]]; then
  log "Creating kind cluster '${CLUSTER_NAME}'"
  kind create cluster --config "${KIND_CONFIG}"
  ok "Cluster created"
else
  ok "Cluster '${CLUSTER_NAME}' already exists — reusing"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

# ── Registry mirrors (containerd v2 hosts.toml) ────────────────────────────
#
# We configure mirrors by writing hosts.toml files into each node and
# restarting containerd — this is the correct method for containerd v2.
# The MIRRORS array can be edited freely; --recreate is NOT required.

MIRRORS=(
  "https://dockerhub.timeweb.cloud"
  "https://dockerhub1.beget.com"
  "https://mirror.gcr.io"
)

configure_mirrors() {
  local node="$1"
  local mirrors_str
  mirrors_str=$(printf '"%s"\n' "${MIRRORS[@]}" | paste -sd, -)

  docker exec "${node}" bash -c "
    set -e

    # ── 1. Clear the broken host-injected proxy from containerd ───────────────
    # Docker daemon injects HTTP_PROXY/HTTPS_PROXY into containers, but
    # 127.0.0.1 inside a container is the container itself (not the host proxy).
    # Override containerd's systemd unit to explicitly unset those variables.
    mkdir -p /etc/systemd/system/containerd.service.d
    cat > /etc/systemd/system/containerd.service.d/no-proxy.conf <<'UNIT'
[Service]
Environment='HTTP_PROXY='
Environment='HTTPS_PROXY='
Environment='http_proxy='
Environment='https_proxy='
Environment='ALL_PROXY='
Environment='all_proxy='
Environment='FTP_PROXY='
Environment='ftp_proxy='
UNIT

    # ── 2. Write hosts.toml mirrors for docker.io ─────────────────────────────
    mkdir -p /etc/containerd/certs.d/docker.io
    cat > /etc/containerd/certs.d/docker.io/hosts.toml <<TOML
server = \"https://registry-1.docker.io\"
$(for m in ${MIRRORS[*]}; do
  printf '[host.\"%s\"]\n  capabilities = [\"pull\", \"resolve\"]\n\n' "\${m}"
done)
TOML

    # ── 3. Point containerd at the certs.d directory (idempotent) ────────────
    if ! grep -q 'config_path' /etc/containerd/config.toml 2>/dev/null; then
      # Append a snippet that enables the hosts directory
      cat >> /etc/containerd/config.toml <<'CONF'

# Added by setup.sh — enable certs.d mirrors
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/containerd/certs.d'
CONF
    fi

    # ── 4. Reload and restart containerd ─────────────────────────────────────
    systemctl daemon-reload
    systemctl restart containerd
    sleep 2
    echo 'containerd restarted'
  " 2>&1 | sed "s/^/  [${node}] /"
}

log "Configuring Docker Hub mirrors on all kind nodes"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  configure_mirrors "${node}"
done
ok "Registry mirrors configured"

# ── local-path-provisioner ─────────────────────────────────────────────────

log "Configuring local-path-provisioner"

# kind v0.31+ ships local-path-provisioner in local-path-storage namespace.
# We do NOT replace it (avoids pulling external images); we only patch the
# ConfigMap to redirect storage to our host-mounted path.
kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=3m

kubectl patch configmap local-path-config \
  -n local-path-storage \
  --type merge \
  -p "{\"data\":{\"config.json\":\"{\\\"nodePathMap\\\":[{\\\"node\\\":\\\"DEFAULT_PATH_FOR_NON_LISTED_NODES\\\",\\\"paths\\\":[\\\"${STORAGE_ROOT}\\\"]}]}\"}}"

# Bounce the pod so it picks up the new ConfigMap
kubectl rollout restart deployment/local-path-provisioner -n local-path-storage
kubectl rollout status  deployment/local-path-provisioner -n local-path-storage --timeout=3m

# Auto-detect the StorageClass backed by rancher.io/local-path (may be called
# 'local-path' or 'standard' depending on the kind version).
LOCAL_PATH_SC=$(kubectl get storageclass \
  -o jsonpath='{range .items[?(@.provisioner=="rancher.io/local-path")]}{.metadata.name}{end}')

if [[ -n "${LOCAL_PATH_SC}" ]]; then
  kubectl patch storageclass "${LOCAL_PATH_SC}" \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  ok "StorageClass '${LOCAL_PATH_SC}' set as default"
else
  warn "Could not find a rancher.io/local-path StorageClass — skipping"
fi

ok "local-path-provisioner configured (storage root: ${STORAGE_ROOT})"

# ── nginx ingress controller ───────────────────────────────────────────────

log "Installing nginx ingress controller (ports 80/443)"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update 2>/dev/null || true
helm repo update ingress-nginx

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.hostPort.enabled=true \
  --set controller.hostPort.ports.http=80 \
  --set controller.hostPort.ports.https=443 \
  --set controller.service.type=ClusterIP \
  --set-string "controller.nodeSelector.ingress-ready=true" \
  --set "controller.tolerations[0].key=node-role.kubernetes.io/control-plane" \
  --set "controller.tolerations[0].operator=Exists" \
  --set "controller.tolerations[0].effect=NoSchedule" \
  --wait --timeout 5m

ok "nginx ingress controller installed"

# ── cert-manager ───────────────────────────────────────────────────────────

log "Installing cert-manager ${CERT_MANAGER_VERSION}"

helm repo add jetstack https://charts.jetstack.io --force-update 2>/dev/null || true
helm repo update jetstack

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --wait --timeout 5m

ok "cert-manager installed"

log "Creating self-signed ClusterIssuers"

# Wait for cert-manager webhook to be ready
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=2m

kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: local-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: local-dev-ca
  secretName: local-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: local-ca-issuer
spec:
  ca:
    secretName: local-ca-secret
EOF

# Wait for the CA certificate to be issued
echo "  Waiting for local CA certificate..."
for i in $(seq 1 30); do
  if kubectl get secret local-ca-secret -n cert-manager &>/dev/null; then
    ok "ClusterIssuers ready (selfsigned-issuer, local-ca-issuer)"
    break
  fi
  sleep 2
done

# ── Istio ──────────────────────────────────────────────────────────────────

log "Installing Istio ${ISTIO_VERSION} (demo profile)"

"${ISTIOCTL}" install --set profile=demo --skip-confirmation

kubectl label namespace default istio-injection=enabled --overwrite

ok "Istio control plane installed"

# ── Istio ingress gateway NodePorts ───────────────────────────────────────

log "Configuring Istio ingress gateway NodePorts (30080→8080, 30443→8443)"

# The demo profile creates the service with LoadBalancer type and existing ports.
# We replace the port list entirely with the ports we need + fixed NodePorts.
kubectl patch svc istio-ingressgateway -n istio-system --type=json -p='[
  {"op":"replace","path":"/spec/type","value":"NodePort"},
  {"op":"replace","path":"/spec/ports","value":[
    {"name":"status-port","port":15021,"targetPort":15021,"protocol":"TCP"},
    {"name":"http2",      "port":80,   "targetPort":8080, "nodePort":30080,"protocol":"TCP"},
    {"name":"https",      "port":443,  "targetPort":8443, "nodePort":30443,"protocol":"TCP"}
  ]}
]'

ok "Istio ingress gateway → NodePort 30080 (HTTP) / 30443 (HTTPS)"

# ── Verify ────────────────────────────────────────────────────────────────

log "Verifying cluster components"

echo
printf "  %-40s %s\n" "COMPONENT" "STATUS"
printf "  %-40s %s\n" "---------" "------"

check_deployment() {
  local ns="$1" name="$2"
  local ready
  ready=$(kubectl get deployment "${name}" -n "${ns}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  local desired
  desired=$(kubectl get deployment "${name}" -n "${ns}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
  if [[ "${ready}" == "${desired}" && "${ready}" != "0" ]]; then
    printf "  %-40s \033[1;32m%s/%s ready\033[0m\n" "${ns}/${name}" "${ready}" "${desired}"
  else
    printf "  %-40s \033[1;33m%s/%s ready\033[0m\n" "${ns}/${name}" "${ready:-0}" "${desired}"
  fi
}

check_deployment local-path-storage   local-path-provisioner
check_deployment ingress-nginx        ingress-nginx-controller
check_deployment cert-manager         cert-manager
check_deployment cert-manager         cert-manager-webhook
check_deployment istio-system         istiod
check_deployment istio-system         istio-ingressgateway

echo
kubectl get storageclass
echo

# ── Summary ────────────────────────────────────────────────────────────────

cat <<SUMMARY

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Cluster '${CLUSTER_NAME}' is ready
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  nginx Ingress (standard Ingress resources):
    HTTP   →  http://<name>.localhost.localdomain
    HTTPS  →  https://<name>.localhost.localdomain   (port 443)
    Annotation for TLS:  cert-manager.io/cluster-issuer: local-ca-issuer

  Istio Ingress Gateway (Gateway + VirtualService):
    HTTP   →  http://<name>.localhost.localdomain:8080
    HTTPS  →  https://<name>.localhost.localdomain:8443

  Storage:
    StorageClass : local-path (default)
    Host path    : ${STORAGE_ROOT}

  Re-run modes:
    ./setup.sh             — upgrade components in-place
    ./setup.sh --recreate  — delete + recreate cluster (keeps host storage)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY
