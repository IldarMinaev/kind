# Local kind Kubernetes cluster

## Prerequisites

```bash
# Fedora
sudo dnf install -y kind kubectl helm docker

# Start Docker
sudo systemctl enable --now docker
sudo usermod -aG docker $USER   # log out/in after this
```

> **istioctl** is downloaded automatically by `setup.sh` if not found.
> To install it manually: `curl -sSL https://istio.io/downloadIstio | sh -`

---

## One-time DNS setup (wildcard *.localhost.localdomain)

NetworkManager's built-in dnsmasq plugin handles the wildcard DNS record.
Run once as root:

```bash
# 1. Enable dnsmasq plugin in NetworkManager
sudo sed -i '/^\[main\]/a dns=dnsmasq' /etc/NetworkManager/NetworkManager.conf

# 2. Create the wildcard record
sudo mkdir -p /etc/NetworkManager/dnsmasq.d
echo 'address=/.localhost.localdomain/127.0.0.1' \
  | sudo tee /etc/NetworkManager/dnsmasq.d/localhost-localdomain.conf

# 3. Reload
sudo systemctl reload NetworkManager

# 4. Verify
ping -c1 anything.localhost.localdomain   # should resolve to 127.0.0.1
```

---

## Start the cluster

```bash
chmod +x setup.sh
./setup.sh
```

The script is idempotent — safe to re-run.

---

## Architecture

```
Host machine (Fedora)
  *.localhost.localdomain → 127.0.0.1
       │
       ├── :80 / :443  ──► kind node hostPort ──► nginx ingress controller
       │                                           (Ingress resources)
       │
       └── :8080 / :8443 ─► kind node NodePort ──► Istio ingress gateway
                             30080 / 30443          (Gateway + VirtualService)
```

| Entry point        | Port on host | Used for                          |
|--------------------|--------------|-----------------------------------|
| nginx ingress      | 80 / **443** | Standard `Ingress` resources      |
| Istio gateway      | 8080 / 8443  | Istio `Gateway` + `VirtualService`|
| Storage            | —            | `/var/local-path-provisioner`     |

---

## Usage examples

### nginx Ingress with automatic TLS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: local-ca-issuer
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - my-app.localhost.localdomain
      secretName: my-app-tls
  rules:
    - host: my-app.localhost.localdomain
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app-svc
                port:
                  number: 80
```

Access: `https://my-app.localhost.localdomain`

---

### Istio Gateway + VirtualService

`setup.sh` creates a wildcard TLS certificate (`istio-system/istio-gw-tls`) that all
Gateways can share via `credentialName`.

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: my-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    # HTTP
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts: ["my-app.localhost.localdomain"]
    # HTTPS — uses the shared wildcard cert from setup.sh
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: istio-gw-tls   # secret in istio-system
      hosts: ["my-app.localhost.localdomain"]
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: my-app
spec:
  hosts: ["my-app.localhost.localdomain"]
  gateways: [my-gateway]
  http:
    - route:
        - destination:
            host: my-app-svc
            port:
              number: 80
```

Access:
- HTTP:  `http://my-app.localhost.localdomain:8080`
- HTTPS: `https://my-app.localhost.localdomain:8443`

> **Per-service certs**: create a `cert-manager.io/v1 Certificate` in `istio-system`
> with `secretName: my-app-tls` and reference it as `credentialName: my-app-tls`.

---

### Persistent Volume Claim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path   # default — can be omitted
  resources:
    requests:
      storage: 5Gi
```

Data is stored under `/var/local-path-provisioner/` on your host and **survives
cluster deletion** as long as you don't delete that directory.

---

## Trust the self-signed CA in your browser

```bash
# Export the CA certificate
kubectl get secret local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > local-ca.crt

# Import into Firefox/Chrome system trust (Fedora)
sudo cp local-ca.crt /etc/pki/ca-trust/source/anchors/local-dev-ca.crt
sudo update-ca-trust

# Then restart your browser
```

---

## Tear down

```bash
kind delete cluster --name local-dev

# Optional — removes all persistent data
sudo rm -rf /var/local-path-provisioner
```

---

## Loading local Docker images into kind

kind nodes run inside Docker containers and cannot access images from the host
Docker daemon directly.  There are two approaches — a **local registry** (recommended)
and **`kind load`** (simpler, no registry needed).

---

### Local registry

`setup.sh` starts a `registry:2` container named `kind-registry` and connects
it to the `kind` Docker network.  Containerd on every node is configured to
resolve `localhost:5001` → `http://kind-registry:5000`, so pod specs can use
`image: localhost:5001/<name>:<tag>` and the image is pulled from the local
registry automatically — no `kind load` needed.

**Advantages:**
- Push once — all nodes pull from the registry; no per-node copying
- Survives node restarts — nodes re-pull from the registry
- Works exactly like a real registry

#### Workflow

Use `kbuild` — it builds and pushes to the local registry in a single command,
with no separate `docker tag` or `docker push` step:

```bash
# Build and push in one step
./kbuild inventory-service:latest ./inventory

# With extra build args or a custom Dockerfile
./kbuild inventory-service:latest --build-arg ENV=dev ./inventory
./kbuild inventory-service:latest --file ./inventory/Dockerfile.prod ./inventory

# After a rebuild (same tag), restart the deployment to force a re-pull
kubectl rollout restart deployment/inventory-service -n inventory
```

Reference the image in your pod spec using the registry address:
```
image: localhost:5001/inventory-service:latest
```

#### Pod spec example

```yaml
spec:
  containers:
    - name: inventory-service
      image: localhost:5001/inventory-service:latest
      imagePullPolicy: Always   # always re-pull on pod restart
```

> Set `imagePullPolicy: Always` when using mutable tags like `latest` so a
> `kubectl rollout restart` reliably picks up a freshly pushed image.

#### Verify registry contents

```bash
# List repositories in the local registry
curl -s http://localhost:5001/v2/_catalog | jq

# List tags for a specific image
curl -s http://localhost:5001/v2/inventory-service/tags/list | jq
```

---

## Registry mirrors / Docker Hub proxy

If your environment has no direct access to Docker Hub, configure mirrors in
`kind-config.yaml` under `containerdConfigPatches`. The mirrors are baked into
every node at cluster creation time — they require a **cluster recreation** to
take effect.

```yaml
# kind-config.yaml (already present, edit the mirror list to suit your network)
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
          endpoint = [
            "https://dockerhub.timeweb.cloud",
            "https://dockerhub1.beget.com",
            "https://mirror.gcr.io"
          ]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."ghcr.io"]
          endpoint = ["https://ghcr.io"]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
          endpoint = ["https://quay.io"]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
          endpoint = ["https://registry.k8s.io"]
```

Mirrors are tried in order; the original registry is used as a fallback.

To apply after editing:

```bash
./setup.sh --recreate
```

To verify mirrors are active on a running node:

```bash
docker exec local-dev-control-plane \
  cat /etc/containerd/config.toml | grep -A5 mirrors
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Port 80/443 already in use | Stop any local nginx/Apache: `sudo systemctl stop nginx` |
| DNS not resolving | Check `systemd-resolved` isn't overriding: `resolvectl status` |
| Istio pods pending | Ensure worker nodes have enough resources (4 CPU / 8 GB RAM recommended) |
| TLS cert not issued | `kubectl describe certificaterequest -A` and check cert-manager logs |
| ImagePullBackOff (public image) | Add/update mirrors in `kind-config.yaml`, then `./setup.sh --recreate` |
| ImagePullBackOff (local image) | `./kbuild <image>:<tag> <context>`, use `localhost:5001/…` in pod spec |
