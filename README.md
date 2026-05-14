# Rocket.Chat — Production Deployment Guide

Self-hosted Rocket.Chat on **Google Kubernetes Engine (GKE)** via Helm, with a Docker Compose setup for local development. A Jenkins pipeline builds, scans, and promotes images across `dev`, `staging`, and `prod` environments automatically on branch push.

---

## Table of contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Before you run](#before-you-run)
  - [Docker Compose checklist](#docker-compose-checklist)
  - [Helm / Kubernetes checklist](#helm--kubernetes-checklist)
- [Run commands](#run-commands)
  - [Docker Compose](#docker-compose)
  - [Kubernetes via Helm](#kubernetes-via-helm)
  - [Jenkins CI/CD](#jenkins-cicd)
- [Environment reference](#environment-reference)
- [Troubleshooting](#troubleshooting)
- [Known issues to fix before production](#known-issues-to-fix-before-production)

---

## Architecture

```
Internet
    │
    ▼
┌──────────────────────────────────────────────────────────────┐
│                      GKE Cluster (GCP)                       │
│                                                              │
│  ┌─────────────────────────────┐                             │
│  │  Namespace: rocketchat-nginx│                             │
│  │                             │                             │
│  │   ┌─────────────────────┐   │◄── LoadBalancer (L4)        │
│  │   │   Nginx Deployment  │   │    External IP (dynamic)    │
│  │   │   (reverse proxy)   │   │    Port 80 / 443            │
│  │   └──────────┬──────────┘   │                             │
│  └──────────────┼──────────────┘                             │
│                 │ proxy_pass :3000                            │
│  ┌──────────────▼──────────────┐                             │
│  │  Namespace: rocketchat      │                             │
│  │                             │                             │
│  │   ┌─────────────────────┐   │                             │
│  │   │  Rocket.Chat        │◄──┼── HPA (1–3 replicas)        │
│  │   │  Deployment         │   │   CPU ≥ 80% / Mem ≥ 80%     │
│  │   │  ClusterIP :3000    │   │                             │
│  │   │  PVC: uploads       │   │                             │
│  │   └──────────┬──────────┘   │                             │
│  └──────────────┼──────────────┘                             │
│                 │ mongodb://user:pass@<host>:27017            │
│                 │ /rocketchat?replicaSet=rs0&authSource=admin │
│  ┌──────────────▼──────────────┐                             │
│  │  Namespace: rocketchat-db   │                             │
│  │                             │                             │
│  │   ┌─────────────────────┐   │                             │
│  │   │  MongoDB 7.0        │   │                             │
│  │   │  StatefulSet        │   │                             │
│  │   │  ReplicaSet: rs0    │   │                             │
│  │   │  Headless Service   │   │                             │
│  │   │  PVC: mongo-data    │   │                             │
│  │   └─────────────────────┘   │                             │
│  └─────────────────────────────┘                             │
└──────────────────────────────────────────────────────────────┘

Image Registry
  Google Artifact Registry (GAR)
  asia-south2-docker.pkg.dev/<PROJECT_ID>/rocketchat/rocketchat-v0.1:<BUILD_NUMBER>

CI/CD — Jenkins branch strategy
  develop  ──► Build → Push → Deploy (dev namespaces)
  staging  ──► Build → Push → Deploy (staging namespaces)
  prod     ──► Build → Push → Deploy (prod namespaces)
  other    ──► Build → Push only (no deploy)

Local dev — Docker Compose
  nginx (8080) ──► rocketchat (3000) ──► mongodb (27017)
  backend network is internal: true (not internet-routable)
```

---

## Prerequisites

### Tools required on your machine

| Tool | Min version | Link |
|------|-------------|------|
| Docker | 24+ | https://docs.docker.com/get-docker |
| Docker Compose | v2 plugin | Bundled with Docker Desktop |
| kubectl | 1.28+ | https://kubernetes.io/docs/tasks/tools |
| Helm | 3.12+ | https://helm.sh/docs/intro/install |
| gcloud CLI | latest | https://cloud.google.com/sdk/docs/install |

### GCP resources required (Kubernetes path only)

**1. A GCP project** — note your `PROJECT_ID`.

**2. Enable required APIs:**
```bash
gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com
```

**3. Create the Artifact Registry repository:**
```bash
gcloud artifacts repositories create rocketchat \
  --repository-format=docker \
  --location=asia-south2
```

**4. Create GKE clusters** (one per environment or shared with namespaces):
```bash
gcloud container clusters create main \
  --zone us-east1 \
  --num-nodes 3 \
  --machine-type e2-standard-4
# Repeat with different names for staging and prod
```

**5. Create a GCP service account for Jenkins:**
```bash
gcloud iam service-accounts create jenkins-deployer \
  --display-name "Jenkins CI"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:jenkins-deployer@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:jenkins-deployer@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/container.developer"

# Download the key file for Jenkins
gcloud iam service-accounts keys create sa-key.json \
  --iam-account=jenkins-deployer@$PROJECT_ID.iam.gserviceaccount.com
```

---

## Before you run

### Docker Compose checklist

**1. Create the `.env` file**

```bash
cp .env.example .env
```

Edit `.env` with real values:

```env
MONGO_ROOT_USER=rocketchat
MONGO_ROOT_PASSWORD=<replace-with-strong-password>
```

**2. Generate the MongoDB keyfile**

Required for ReplicaSet internal auth. Run this once:

```bash
openssl rand -base64 756 | tr -d '\n' > /tmp/mongo-keyfile
sudo install -m 400 -o 999 -g 999 /tmp/mongo-keyfile /etc/mongo-keyfile
```

> The compose file mounts `/etc/mongo-keyfile` read-only into the MongoDB container.

**3. Create the Nginx config**

```bash
mkdir -p ./nginx
```

Create `./nginx/nginx.conf`:

```nginx
events {}

http {
    upstream rocketchat {
        server rocketchat_app:3000;
    }

    server {
        listen 8080;

        location / {
            proxy_pass         http://rocketchat;
            proxy_http_version 1.1;
            proxy_set_header   Upgrade    $http_upgrade;
            proxy_set_header   Connection "upgrade";
            proxy_set_header   Host       $host;
            proxy_set_header   X-Real-IP  $remote_addr;
            proxy_read_timeout 900s;
        }
    }
}
```

**4. Fix the nginx network in `docker-compose.yml`**

Nginx must be on **both** networks to proxy traffic to Rocket.Chat. Verify the nginx service block contains:

```yaml
nginx:
  networks:
    - frontend
    - backend    # ← required — nginx cannot reach rocketchat without this
```

**5. Validate the compose file**

The `mongodb` service has known indentation errors on `command`, `restart`, and `networks`. Fix the YAML indent and verify:

```bash
docker compose config --quiet && echo "YAML OK"
```

---

### Helm / Kubernetes checklist

**1. Align version numbers**

`Chart.yaml` and `values-rocketchat.yaml` reference `6.8.0` but the Dockerfile uses `7.4.0`. Fix both:

```yaml
# helm/Chart.yaml
appVersion: "7.4.0"
```

```yaml
# helm/values/values-rocketchat.yaml
rocketchat:
  image:
    tag: "7.4.0"
```

**2. Change default MongoDB credentials**

Never deploy with the default password. Edit `helm/values/values-db.yaml`:

```yaml
mongodb:
  auth:
    rootUser: rocketchat
    rootPassword: <replace-with-strong-password>
```

**3. Add Jenkins credentials**

Go to Jenkins → Manage Jenkins → Credentials → Global → Add Credential:

| Credential ID | Type | Value |
|---|---|---|
| `gcp-project-id` | Secret text | Your GCP Project ID |
| `gcp-service-acc` | Secret text | `jenkins-deployer@<PROJECT_ID>.iam.gserviceaccount.com` |
| `k8s-kubeconfig` | Secret file | kubeconfig for dev/main cluster |
| `k8s-kubeconfig-staging` | Secret file | kubeconfig for staging cluster |
| `k8s-kubeconfig-prod` | Secret file | kubeconfig for prod cluster |
| `mongo-db-user` | Secret text | MongoDB root username |
| `mongo-db-pass` | Secret text | MongoDB root password |

**4. Authenticate gcloud on the Jenkins agent**

```bash
gcloud auth activate-service-account \
  --key-file=/path/to/sa-key.json

gcloud auth configure-docker asia-south2-docker.pkg.dev
```

**5. Lint the chart locally before pushing**

```bash
helm lint ./helm \
  -f ./helm/values/values-db.yaml \
  -f ./helm/values/values-nginx.yaml \
  -f ./helm/values/values-rocketchat.yaml
```

Expected: `1 chart(s) linted, 0 chart(s) failed`

---

## Run commands

### Docker Compose

**Start all services:**

```bash
docker compose up -d
```

**Initialise MongoDB ReplicaSet — first run only:**

After containers start, wait ~15 seconds for MongoDB to pass its healthcheck, then:

```bash
docker exec -it rocketchat_mongo mongosh \
  -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  --eval 'rs.initiate({ _id: "rs0", members: [{ _id: 0, host: "mongodb:27017" }] })'
```

Verify it worked:

```bash
docker exec -it rocketchat_mongo mongosh \
  -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  --eval 'rs.status().myState'
# Expected output: 1  (means PRIMARY)
```

**Access the app:**

| Service | URL |
|---------|-----|
| Rocket.Chat via Nginx | http://localhost:8080 |
| Rocket.Chat direct | http://localhost:3000 |

**Common compose commands:**

```bash
# Follow logs for all services
docker compose logs -f

# Follow logs for one service
docker compose logs -f rocketchat

# Check service health
docker compose ps

# Stop and keep data
docker compose down

# Full reset — removes all volumes and data
docker compose down -v
```

---

### Kubernetes via Helm

Deploy the three components in order: **database → nginx → app**.

**Step 1 — Create namespaces:**

```bash
kubectl create namespace rocketchat-db    --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace rocketchat-nginx --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace rocketchat       --dry-run=client -o yaml | kubectl apply -f -
```

**Step 2 — Deploy MongoDB:**

```bash
helm upgrade --install rocketchat-db ./helm \
  -f ./helm/values/values-db.yaml \
  --set rocketchat.enabled=false \
  --set nginx.enabled=false \
  --namespace rocketchat-db \
  --create-namespace \
  --timeout=10m
```

Wait for MongoDB to be ready:

```bash
kubectl rollout status statefulset/rocketchat-db-mongodb -n rocketchat-db
```

**Step 3 — Deploy Nginx:**

```bash
helm upgrade --install rocketchat-nginx ./helm \
  -f ./helm/values/values-nginx.yaml \
  --set mongodb.enabled=false \
  --set rocketchat.enabled=false \
  --namespace rocketchat-nginx \
  --create-namespace \
  --wait \
  --timeout=5m
```

Get the LoadBalancer external IP (may take 1–3 minutes):

```bash
kubectl get svc rocketchat-nginx-nginx -n rocketchat-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

**Step 4 — Deploy Rocket.Chat:**

Replace `<LB_IP>`, `<MONGO_USER>`, and `<MONGO_PASS>` with real values:

```bash
MONGO_HOST="rocketchat-db-mongodb-0.rocketchat-db-mongodb.rocketchat-db.svc.cluster.local"
LB_IP="<LB_IP>"
MONGO_USER="<MONGO_USER>"
MONGO_PASS="<MONGO_PASS>"

helm upgrade --install rocketchat-app ./helm \
  -f ./helm/values/values-rocketchat.yaml \
  --set mongodb.enabled=false \
  --set nginx.enabled=false \
  --set rocketchat.mongoUrl="mongodb://${MONGO_USER}:${MONGO_PASS}@${MONGO_HOST}:27017/rocketchat?replicaSet=rs0&authSource=admin" \
  --set rocketchat.mongoOplogUrl="mongodb://${MONGO_USER}:${MONGO_PASS}@${MONGO_HOST}:27017/local?replicaSet=rs0&authSource=admin" \
  --set rocketchat.rootUrl="http://${LB_IP}" \
  --namespace rocketchat \
  --create-namespace \
  --wait \
  --timeout=10m
```

**Verify the deployment:**

```bash
kubectl get pods -n rocketchat-db
kubectl get pods -n rocketchat-nginx
kubectl get pods -n rocketchat
kubectl get hpa  -n rocketchat
kubectl logs -f deployment/rocketchat-app-rocketchat -n rocketchat
```

Open `http://<LB_IP>` in your browser.

**Teardown:**

```bash
helm uninstall rocketchat-app   -n rocketchat
helm uninstall rocketchat-nginx -n rocketchat-nginx
helm uninstall rocketchat-db    -n rocketchat-db

# Remove namespaces — this also deletes PVCs and all data
kubectl delete namespace rocketchat rocketchat-nginx rocketchat-db
```

---

### Jenkins CI/CD

The `Jenkinsfile` triggers automatically on every branch push. Deployment stages only run on `develop`, `staging`, and `prod` branches.

**Branch → environment mapping:**

| Branch | Environment | Namespace prefix | Cluster |
|--------|------------|-----------------|---------|
| `develop` | dev | `rocketchat` | `main` |
| `staging` | staging | `rocketchat-staging` | `staging` |
| `prod` | prod | `rocketchat-prod` | `prod` |
| any other | build only | — | — |

**Pipeline stages:**

```
Clean Workspace
     │
Checkout
     │
Set Environment       ← detects branch, sets env vars
     │
Validate              ← checks Dockerfile + docker-compose.yml exist, runs helm lint
     │
Auth to GAR           ← gcloud configure-docker
     │
Connect to GKE        ← skipped if no deploy branch
     │
Build Image           ← docker build with git commit, branch, and date labels
     │
[ Scan Image (Trivy) ]← currently commented out — uncomment to enable CVE scanning
     │
Push to GAR           ← pushes :<BUILD_NUMBER> and :latest tags
     │
Bootstrap Cluster     ← creates namespaces + GAR pull secrets (skipped if no deploy)
     │
Deploy with Helm      ← DB → Nginx → App with dynamic LB IP resolution (skipped if no deploy)
     │
Cleanup               ← docker rmi + image prune on agent
```

**To trigger manually:** Jenkins → your pipeline → Build Now.

---

## Environment reference

### `.env` variables (Docker Compose)

| Variable | Description | Default |
|----------|-------------|---------|
| `MONGO_ROOT_USER` | MongoDB admin username | `rocketchat` |
| `MONGO_ROOT_PASSWORD` | MongoDB admin password | *(must be set)* |

### Helm values files

| File | What it controls |
|------|-----------------|
| `helm/values/values-db.yaml` | MongoDB image, resources, auth credentials, storage class |
| `helm/values/values-nginx.yaml` | Nginx image, service type, TLS toggle, resources |
| `helm/values/values-rocketchat.yaml` | App image, HPA min/max, ingress, pull secrets, resources |

### Default resource allocation (tuned for 8 GB RAM / 4 core nodes)

| Component | CPU request | CPU limit | Memory request | Memory limit |
|-----------|------------|-----------|----------------|-------------|
| Rocket.Chat | 500m | 2000m | 1 Gi | 2 Gi |
| MongoDB | 500m | 1000m | 1 Gi | 2 Gi |
| Nginx | 100m | 500m | 128 Mi | 256 Mi |

---

## Troubleshooting

**MongoDB ReplicaSet not initialising**

Check the init Job that runs as a Helm post-install hook:

```bash
kubectl get jobs -n rocketchat-db
kubectl logs job/rocketchat-db-mongodb-init -n rocketchat-db
```

In Docker Compose, check MongoDB logs:

```bash
docker compose logs mongodb
```

---

**Rocket.Chat stuck in CrashLoopBackOff**

Usually a bad `MONGO_URL`. Verify DNS resolves from inside the pod:

```bash
kubectl exec -it deployment/rocketchat-app-rocketchat -n rocketchat -- \
  node -e "require('dns').resolve('<mongo-hostname>', console.log)"
```

---

**Nginx returns 502 Bad Gateway**

In Docker Compose — nginx is not on the `backend` network. Add `- backend` under the nginx `networks:` key.

In Kubernetes — verify the Rocket.Chat ClusterIP service is running:

```bash
kubectl get svc -n rocketchat
```

---

**GAR authentication fails in Jenkins**

Re-run gcloud configure on the Jenkins agent:

```bash
gcloud auth configure-docker asia-south2-docker.pkg.dev
```

Verify the service account has `roles/artifactregistry.writer`.

---

**LoadBalancer IP never assigned**

GCP can take up to 5 minutes. Check service events:

```bash
kubectl describe svc rocketchat-nginx-nginx -n rocketchat-nginx
```

---

## Known issues to fix before production

- [ ] Uncomment the Trivy scan stage in `Jenkinsfile` for image CVE visibility
- [ ] Add nginx to the `backend` network in `docker-compose.yml` so it can reach Rocket.Chat
- [ ] Fix YAML indentation errors in the `mongodb` service block of `docker-compose.yml`
- [ ] Align `appVersion` in `Chart.yaml` and image `tag` in `values-rocketchat.yaml` to `7.4.0`
- [ ] Enable TLS in `helm/templates/ingress.yaml` and nginx values for HTTPS
- [ ] Replace plain Kubernetes Secrets with SealedSecrets or ExternalSecrets for GitOps-safe credential management
- [ ] Add a `NetworkPolicy` to restrict MongoDB port access to the Rocket.Chat namespace only
- [ ] Add a manual approval gate in `Jenkinsfile` before the `prod` deploy stage
- [ ] Add Slack or email notifications in the `post { failure { } }` block
