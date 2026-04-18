# Rocket.Chat — Production DevOps Pipeline

A full end-to-end DevOps pipeline for deploying Rocket.Chat in production — covering secure Docker builds, vulnerability scanning, CI/CD automation with Jenkins, and a Kubernetes deployment managed entirely through Helm.

Built and tested on a fresh Azure VM. Single `helm install` — no manual steps.

> **Follow the build:** [LinkedIn](https://linkedin.com/in/tushar-yadav-6323a1219) · [Twitter/X](https://twitter.com/yadavtushr)

-----

## What’s Inside

```
Rocket.Chat/
├── Dockerfile                      # Hardened multi-stage Docker build
├── Jenkinsfile                     # CI/CD pipeline with Trivy scanning
└── helm/
    ├── Chart.yaml
    ├── values/
    │   ├── values-db.yaml          # MongoDB config
    │   ├── values-nginx.yaml       # Nginx config
    │   └── values-rocketchat.yaml  # App + ingress + HPA config
    └── templates/
        ├── secrets.yaml
        ├── mongodb-statefulset.yaml
        ├── mongodb-svc.yaml
        ├── mongodb-pvc.yaml
        ├── mongodb-configmap.yaml
        ├── mongodb-init-job.yaml
        ├── rocketchat-deployment.yaml
        ├── rocketchat-svc.yaml
        ├── rocketchat-pvc.yaml
        ├── nginx-deployment.yaml
        ├── nginx-svc.yaml
        ├── nginx-configmap.yaml
        ├── ingress.yaml
        └── hpa.yaml
```

-----

## Architecture

```
External Traffic (Users / Clients)
            │
            ▼
    Cloud Load Balancer
    (AWS ALB / GCP LB / Azure)
            │
            ▼
    Nginx Ingress Controller
    (TLS termination · routing · rate limiting)
            │
      ┌─────┴──────────────┐
      │                    │
      ▼                    ▼
 ClusterIP: nginx     ClusterIP: rocketchat
 HPA (min 1 · max 5)  HPA (min 1 · max 3)
 Deployment           Deployment
 nginx pods           Rocket.Chat pods
                           │
                           ▼
                   ClusterIP: mongodb
                   StatefulSet (RS mode)
                   pod: mongo-0 (primary)
                   PVC → Longhorn (15Gi RWX)
```

|Component  |Type          |Details                           |
|-----------|--------------|----------------------------------|
|Rocket.Chat|Deployment    |v6.8.0, HPA min 1 max 3           |
|MongoDB    |StatefulSet   |v7.0, replica set rs0             |
|Nginx      |Deployment    |Alpine, reverse proxy + WebSocket |
|Ingress    |Ingress       |nginx class, nip.io host          |
|Storage    |Longhorn RWX  |15Gi MongoDB · 10Gi uploads       |
|Secrets    |Auto-generated|MongoDB keyfile via `randAlphaNum`|

-----

## CI/CD Pipeline

Every push triggers the Jenkins pipeline:

```
Code Push
    │
    ▼
┌──────────────────────────────────────┐
│           Jenkins Pipeline           │
│                                      │
│  1. Checkout                         │
│  2. Docker Build                     │
│  3. Trivy Scan ──► FAIL if critical  │
│  4. Push to ACR                      │
│  5. helm upgrade (on merge to main)  │
└──────────────────────────────────────┘
```

**Trivy** scans every image before it is pushed to Azure Container Registry. If a critical vulnerability is found the pipeline fails — the image never ships. No exceptions.

```groovy
// Jenkinsfile excerpt
stage('Trivy Scan') {
    steps {
        sh 'trivy image --exit-code 1 --severity CRITICAL myapp:${BUILD_NUMBER}'
    }
}
```

-----

## Docker — Security Hardening

The Dockerfile uses a multi-stage build to keep the runtime image minimal and secure:

- Base image pinned to a specific digest — no surprise upstream changes
- Build dependencies removed from the final image
- Runs as a non-root user
- No unnecessary packages in the runtime layer
- Layers optimised to minimise attack surface

-----

## Health Checks

Health checks are defined at every layer:

**Container level — Kubernetes probes**

|Probe        |Rocket.Chat       |MongoDB                  |
|-------------|------------------|-------------------------|
|Liveness     |`GET /api/v1/info`|`db.adminCommand('ping')`|
|Readiness    |`GET /api/v1/info`|`db.adminCommand('ping')`|
|Initial delay|60s               |30s                      |
|Period       |15s               |10s                      |

**Pipeline level — Jenkins**

- Trivy scan must pass before image is pushed
- `helm lint` validates chart before deploy
- Deployment only proceeds if all stages are green

-----

## Prerequisites

|Tool          |Version|Purpose                |
|--------------|-------|-----------------------|
|Kubernetes    |1.25+  |Cluster (tested on k3s)|
|Helm          |3.x    |Chart management       |
|Longhorn      |1.11+  |RWX storage class      |
|Nginx Ingress |Any    |Ingress controller     |
|metrics-server|Any    |Required for HPA       |
|Jenkins       |2.x+   |CI/CD                  |
|Trivy         |Latest |Vulnerability scanning |

-----

## Quick Start

### 1. Install k3s

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
```

### 2. Install Longhorn

```bash
sudo apt install -y open-iscsi nfs-common
sudo systemctl enable iscsid && sudo systemctl start iscsid

helm repo add longhorn https://charts.longhorn.io && helm repo update

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultReplicaCount=1

# Remove k3s local-path as default — Longhorn must be the only default
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

### 3. Install Nginx Ingress

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace
```

### 4. Configure Values

```bash
PUBLIC_IP=$(curl -s ifconfig.me)

# Set ingress host and rootUrl
sed -i "s|<public_ip>|$PUBLIC_IP|g" helm/values/values-rocketchat.yaml
sed -i "s|http://rocketchat.local|http://$PUBLIC_IP.nip.io|g" helm/values/values-rocketchat.yaml

# Set a strong MongoDB password
nano helm/values/values-rocketchat.yaml
# Change: rootPassword: "CHANGE_ME"
```

### 5. Deploy

```bash
helm install rocketchat ./helm \
  -f helm/values/values-db.yaml \
  -f helm/values/values-nginx.yaml \
  -f helm/values/values-rocketchat.yaml
```

### 6. Watch it come up

```bash
kubectl get pods -w
```

```
rocketchat-mongodb-0           1/1   Running   ← MongoDB + replica set auto-init
rocketchat-nginx-xxx           1/1   Running   ← Nginx reverse proxy
rocketchat-rocketchat-xxx      1/1   Running   ← Rocket.Chat app
```

### 7. Access

```
http://<YOUR_PUBLIC_IP>.nip.io
```

-----

## Values Reference

### `values-db.yaml`

|Key                                   |Default   |Description    |
|--------------------------------------|----------|---------------|
|`mongodb.enabled`                     |`true`    |Enable MongoDB |
|`mongodb.replicaCount`                |`1`       |Number of pods |
|`mongodb.image.tag`                   |`7.0`     |MongoDB version|
|`mongodb.resources.limits.cpu`        |`1.0`     |CPU limit      |
|`mongodb.resources.limits.memory`     |`2Gi`     |Memory limit   |
|`mongodb.persistence.storageClassName`|`longhorn`|Storage class  |

### `values-nginx.yaml`

|Key                            |Default   |Description |
|-------------------------------|----------|------------|
|`nginx.enabled`                |`true`    |Enable Nginx|
|`nginx.service.type`           |`NodePort`|Service type|
|`nginx.resources.limits.cpu`   |`500m`    |CPU limit   |
|`nginx.resources.limits.memory`|`256Mi`   |Memory limit|

### `values-rocketchat.yaml`

|Key                                            |Default             |Description                      |
|-----------------------------------------------|--------------------|---------------------------------|
|`rocketchat.rootUrl`                           |`http://<ip>.nip.io`|Public URL — **must be set**     |
|`rocketchat.image.tag`                         |`6.8.0`             |App version                      |
|`rocketchat.hpa.minReplicas`                   |`1`                 |HPA min pods                     |
|`rocketchat.hpa.maxReplicas`                   |`3`                 |HPA max pods                     |
|`rocketchat.hpa.targetCPUUtilizationPercentage`|`80`                |CPU scale threshold              |
|`rocketchat.resources.limits.cpu`              |`2.0`               |CPU limit                        |
|`rocketchat.resources.limits.memory`           |`2Gi`               |Memory limit                     |
|`mongodb.auth.rootPassword`                    |`CHANGE_ME`         |**Must be changed before deploy**|

-----

## Known Issues & Solutions

### MongoDB keyfile permissions over NFS

**Problem:** Longhorn RWX uses NFS internally. NFS ignores Unix file permissions. MongoDB requires the keyfile at exactly `0400` or it refuses to start with `Unable to acquire security key[s]`.

**Solution:** An init container copies the keyfile from the Secret to an `emptyDir` volume with correct permissions before MongoDB starts. NFS never touches it.

```yaml
initContainers:
  - name: keyfile-init
    image: busybox
    command:
      - sh
      - -c
      - |
        cp /secret/mongo-keyfile /keyfile/mongo-keyfile
        chmod 0400 /keyfile/mongo-keyfile
        chown 999:999 /keyfile/mongo-keyfile
```

-----

### Replica set init timing

**Problem:** Using a `postStart` lifecycle hook for `rs.initiate()` is unreliable — Kubernetes kills the container if the hook takes too long, causing a crash loop with no clear error.

**Solution:** A dedicated Helm `post-install` Job polls MongoDB until ready then runs `rs.initiate()` using the full FQDN. Retries 20 times. Deletes itself on success.

```
<release>-mongodb-0.<release>-mongodb.<namespace>.svc.cluster.local:27017
```

-----

### Two default storage classes

**Problem:** k3s ships `local-path` as default. Longhorn registers as a second default. Two defaults cause unpredictable PVC binding — PVCs stay Pending on fresh installs.

**Solution:**

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

-----

## Useful Commands

```bash
# Full status overview
kubectl get pods,svc,ingress,pvc,hpa,jobs

# Check MongoDB replica set
kubectl exec -it rocketchat-mongodb-0 -- mongosh \
  -u admin -p <password> --authenticationDatabase admin \
  --eval "rs.status().members[0].stateStr"

# Rocket.Chat logs
kubectl logs -f deployment/rocketchat-rocketchat

# Check HPA
kubectl get hpa

# Upgrade after changes
helm upgrade rocketchat ./helm \
  -f helm/values/values-db.yaml \
  -f helm/values/values-nginx.yaml \
  -f helm/values/values-rocketchat.yaml

# Full teardown
helm uninstall rocketchat
kubectl delete pvc --all --force --grace-period=0
```

-----

## Roadmap

- [ ] Namespace isolation — `rocketchat-db` / `rocketchat-nginx` / `rocketchat-build`
- [ ] ResourceQuota per namespace (CPU / memory / pods / storage)
- [ ] `helm upgrade` wired into Jenkins CI/CD on merge to main
- [ ] Startup probes + PodDisruptionBudgets
- [ ] Pipeline-level smoke tests after deployment
- [ ] TLS via cert-manager + Let’s Encrypt
- [ ] MongoDB 3-node replica set for HA
- [ ] External Secrets Operator for credential management

-----

## Author

**Tushar Yadav** — DevOps Engineer @ Healthmug

[LinkedIn](https://linkedin.com/in/tushar-yadav-6323a1219) · [Twitter/X](https://twitter.com/yadavtushr) · [GitHub](https://github.com/Tushryadav)