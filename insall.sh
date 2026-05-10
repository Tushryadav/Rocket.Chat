#!/bin/bash
set -e

# Step 1: System Update & Dependencies"
sudo apt update && sudo apt upgrade -y

# Longhorn requirements
sudo apt install -y curl wget git open-iscsi nfs-common

# Enable iSCSI (required by Longhorn for RWX volumes)
#sudo systemctl enable iscsid
#sudo systemctl start iscsid

# Verify iSCSI is running
#sudo systemctl status iscsid

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
gcloud container clusters get-credentials main --region asia-south2 --project project-d3f73645-327e-4f11-ba2
kubectl get nodes

#  gcloud config
gcloud auth login
gcloud config set account 440563071013-compute@developer.gserviceaccount.com
gcloud auth list
#  Verify your GCP project ID — the one below may be incomplete/incorrect.
gcloud config set project project-d3f73645-327e-4f11-ba2
gcloud config get-value project

gcloud auth configure-docker asia-south2-docker.pkg.dev

# Step 3: Install Helm"
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version

#Step 4: Install Docker
sudo apt remove --ignore-missing -y \
  docker.io docker-compose docker-compose-v2 docker-doc \
  podman-docker containerd runc || true

# Add Docker's official GPG key
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker "$USER"

# FIX: `newgrp docker` spawns an interactive subshell and HALTS the script.

# Step 5: Install Jenkins
#sudo apt install -y fontconfig openjdk-21-jre
#java -version

#sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
#  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

#echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
#  https://pkg.jenkins.io/debian-stable binary/ \
#  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

#sudo apt update
#sudo apt install -y jenkins

# Enable & start Jenkins
#sudo systemctl enable jenkins
#sudo systemctl start jenkins

# Print initial admin password
# "Jenkins initial admin password:"
#sudo cat /var/lib/jenkins/secrets/initialAdminPassword

# Step 6: Install Longhorn"
#helm repo add longhorn https://charts.longhorn.io
#helm repo update

#helm install longhorn longhorn/longhorn \
#  --namespace longhorn-system \
#  --create-namespace \
#  --set defaultSettings.defaultReplicaCount=1

# Wait for Longhorn manager to be ready (~2-3 min)
#kubectl -n longhorn-system rollout status daemonset/longhorn-manager

#kubectl patch storageclass local-path \
#  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# Verify storage class exists
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

# Step 8: Verify Metrics Server"
#kubectl -n kube-system get deploy metrics-server
#kubectl top nodes

# Step 9: Detect Public IP & Patch Values"

PUBLIC_IP=$(curl -s ifconfig.me)
echo "Your public IP: $PUBLIC_IP"

sed -i "s|<public_ip>|$PUBLIC_IP|g" helm/values/values-rocketchat.yaml
sed -i "s|http://rocketchat.local|http://$PUBLIC_IP.nip.io|g" helm/values/values-rocketchat.yaml

# Step 10: Verify Values Files"

grep -E "host|rootUrl|rootPassword|storageClassName" \
  helm/values/values-rocketchat.yaml \
  helm/values/values-db.yaml

kubectl create namespace rocketchat
kubectl create namespace rocketchat-db
kubectl create namespace rocketchat-nginx

# Create k8s image pull secret
kubectl create secret docker-registry gar-secret \
  --docker-server=asia-south2-docker.pkg.dev \
  --docker-username=oauth2accesstoken \
  --docker-password="$(gcloud auth print-access-token)" \
  --docker-email=440563071013-compute@developer.gserviceaccount.com \
  --namespace rocketchat

# Step 12: Pre-flight Checks"
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
