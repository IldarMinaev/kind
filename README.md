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

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: my-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "my-app.localhost.localdomain"
---
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: my-app
spec:
  hosts:
    - "my-app.localhost.localdomain"
  gateways:
    - my-gateway
  http:
    - route:
        - destination:
            host: my-app-svc
            port:
              number: 80
```

Access: `http://my-app.localhost.localdomain:8080`

For HTTPS on the Istio gateway, configure the Gateway server with `protocol: HTTPS`
and provide a TLS secret (cert-manager can provision it with `local-ca-issuer`).

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
| ImagePullBackOff | Add/update mirrors in `kind-config.yaml`, then `./setup.sh --recreate` |
