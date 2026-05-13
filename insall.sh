#!/bin/bash
set -e

# Step 1: System Update & Dependencies"
sudo apt update && sudo apt upgrade -y

# Longhorn requirements
sudo apt install -y curl wget git open-iscsi nfs-common

# Step 11: Setup GCP & Push Image"

sudo apt-get update
sudo apt-get install ca-certificates gnupg curl
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
sudo apt-get update && sudo apt-get install google-cloud-cli
grep -rhE ^deb /etc/apt/sources.list* | grep "cloud-sdk"

# Step 2: Install k3s (Traefik disabled)"

sudo apt-get update
sudo apt-get install -y kubectl
kubectl version --client
sudo apt-get install google-cloud-sdk-gke-gcloud-auth-plugin
gcloud version

# Cluster configration dev 
gcloud container clusters get-credentials dev --region asia-south2 --project project-d3f73645-327e-4f11-ba2
kubectl get nodes

#  gcloud config
gcloud auth login
gcloud config set account 440563071013-compute@developer.gserviceaccount.com
gcloud auth list
#  Verify your GCP project ID — the one below may be incomplete/incorrect.
gcloud config set project project-d3f73645-327e-4f11-ba2
gcloud config get-value project

# Step 3: Install Helm"
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version

# Step 6: Enable Filestore CSI Driver on GKE
gcloud container clusters update dev \
  --update-addons=GcpFilestoreCsiDriver=ENABLED \
  --zone=asia-south2

# verify storageclass
kubectl get storageclass

# Step 7: Install Nginx Ingress Controller"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace

# Wait for it to come up
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller

# Get the external IP
kubectl -n ingress-nginx get svc ingress-nginx-controller

# gcloud access — copy gcloud config to jenkins home
sudo mkdir -p /var/lib/jenkins/.config/gcloud
sudo cp -r ~/.config/gcloud/* /var/lib/jenkins/.config/gcloud/
sudo chown -R jenkins:jenkins /var/lib/jenkins/.config

# kubectl access — copy kubeconfig to jenkins home
sudo mkdir -p /var/lib/jenkins/.kube
sudo cp ~/.kube/config /var/lib/jenkins/.kube/config
sudo chown -R jenkins:jenkins /var/lib/jenkins/.kube

# Step 10: Verify Values Files"

grep -E "host|rootUrl|rootPassword|storageClassName" \
  helm/values/values-rocketchat.yaml \
  helm/values/values-db.yaml

kubectl create namespace rocketchat
kubectl create namespace rocketchat-db
kubectl create namespace rocketchat-nginx

# Cluster configration staging

gcloud container clusters get-credentials staging --region asia-south2 --project project-d3f73645-327e-4f11-ba2
kubectl get nodes

#  gcloud config
gcloud auth login
gcloud config set account 440563071013-compute@developer.gserviceaccount.com
gcloud auth list
#  Verify your GCP project ID — the one below may be incomplete/incorrect.
gcloud config set project project-d3f73645-327e-4f11-ba2
gcloud config get-value project

# Step 3: Install Helm"
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version

# Step 6: Enable Filestore CSI Driver on GKE
gcloud container clusters update staging \
  --update-addons=GcpFilestoreCsiDriver=ENABLED \
  --zone=asia-south2

# verify storageclass
kubectl get storageclass

# Step 7: Install Nginx Ingress Controller"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace

# Wait for it to come up
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller

# Get the external IP
kubectl -n ingress-nginx get svc ingress-nginx-controller

# gcloud access — copy gcloud config to jenkins home
sudo mkdir -p /var/lib/jenkins/.config/gcloud
sudo cp -r ~/.config/gcloud/* /var/lib/jenkins/.config/gcloud/
sudo chown -R jenkins:jenkins /var/lib/jenkins/.config

# kubectl access — copy kubeconfig to jenkins home
sudo mkdir -p /var/lib/jenkins/.kube
sudo cp ~/.kube/config /var/lib/jenkins/.kube/config
sudo chown -R jenkins:jenkins /var/lib/jenkins/.kube

# Step 10: Verify Values Files"

grep -E "host|rootUrl|rootPassword|storageClassName" \
  helm/values/values-rocketchat.yaml \
  helm/values/values-db.yaml

kubectl create namespace rocketchat
kubectl create namespace rocketchat-db
kubectl create namespace rocketchat-nginx

gcloud container clusters get-credentials prod --region asia-south2 --project project-d3f73645-327e-4f11-ba2
kubectl get nodes

#  gcloud config
gcloud auth login
gcloud config set account 440563071013-compute@developer.gserviceaccount.com
gcloud auth list
#  Verify your GCP project ID — the one below may be incomplete/incorrect.
gcloud config set project project-d3f73645-327e-4f11-ba2
gcloud config get-value project

# Step 3: Install Helm"
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version

# Step 6: Enable Filestore CSI Driver on GKE
gcloud container clusters update prod \
  --update-addons=GcpFilestoreCsiDriver=ENABLED \
  --zone=asia-south2

# verify storageclass
kubectl get storageclass

# Step 7: Install Nginx Ingress Controller"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace

# Wait for it to come up
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller

# Get the external IP
kubectl -n ingress-nginx get svc ingress-nginx-controller

# gcloud access — copy gcloud config to jenkins home
sudo mkdir -p /var/lib/jenkins/.config/gcloud
sudo cp -r ~/.config/gcloud/* /var/lib/jenkins/.config/gcloud/
sudo chown -R jenkins:jenkins /var/lib/jenkins/.config

# kubectl access — copy kubeconfig to jenkins home
sudo mkdir -p /var/lib/jenkins/.kube
sudo cp ~/.kube/config /var/lib/jenkins/.kube/config
sudo chown -R jenkins:jenkins /var/lib/jenkins/.kube

# Step 10: Verify Values Files"

grep -E "host|rootUrl|rootPassword|storageClassName" \
  helm/values/values-rocketchat.yaml \
  helm/values/values-db.yaml

kubectl create namespace rocketchat
kubectl create namespace rocketchat-db
kubectl create namespace rocketchat-nginx

# Step 12: Pre-flight Checks"
echo "[0] cluster:"
gcloud container clusters list

echo "[1] Nodes:"
kubectl get nodes

echo "[2] Storage classes (only longhorn should be default):"
kubectl get storageclass

echo "[3] Longhorn pods:"
kubectl -n longhorn-system get pods

echo "[4] Nginx ingress external IP:"
kubectl -n ingress-nginx get svc ingress-nginx-controller

echo "[5] Existing PVCs (should be empty for a clean install):"
kubectl get pvc --all-namespaces

echo "[6] Namespaces:"
kubectl get namespaces | grep rocketchat


echo " Setup complete!"
echo "========================================"
