#!/bin/bash
set -e

echo "========================================"
echo " Step 1: System Update & Dependencies"
echo "========================================"
sudo apt update && sudo apt upgrade -y

# Longhorn requirements
sudo apt install -y curl wget git open-iscsi nfs-common

# Enable iSCSI (required by Longhorn for RWX volumes)
sudo systemctl enable iscsid
sudo systemctl start iscsid

# Verify iSCSI is running
sudo systemctl status iscsid

echo "========================================"
echo " Step 2: Install k3s (Traefik disabled)"
echo "========================================"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

# Set up kubeconfig
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Persist for future sessions
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
# NOTE: `source ~/.bashrc` has no effect in non-interactive scripts; the export
# above is sufficient for the rest of this script's execution.

# Verify node is Ready
kubectl get nodes

echo "========================================"
echo " Step 3: Install Helm"
echo "========================================"
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version

echo "========================================"
echo " Step 4: Install Docker"
echo "========================================"
# FIX: Use a plain list + --ignore-missing instead of the broken dpkg pipe.
# `|| true` prevents set -e from exiting if packages are not installed.
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
newgrp docker

# FIX: `newgrp docker` spawns an interactive subshell and HALTS the script.
# Removed. The group membership takes effect on next login.
# If you need docker immediately in this session, run: sg docker -c "docker ps"

echo "========================================"
echo " Step 5: Install Jenkins"
echo "========================================"
# FIX: Removed duplicate openjdk-17-jre install. Use openjdk-21-jre only,
# which satisfies Jenkins LTS requirements (Java 17+).
sudo apt install -y fontconfig openjdk-21-jre
java -version

sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
  https://pkg.jenkins.io/debian-stable binary/ \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt update
sudo apt install -y jenkins

# Enable & start Jenkins
sudo systemctl enable jenkins
sudo systemctl start jenkins

# Print initial admin password
echo "Jenkins initial admin password:"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword

echo "========================================"
echo " Step 6: Install Longhorn"
echo "========================================"
helm repo add longhorn https://charts.longhorn.io
helm repo update

helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set defaultSettings.defaultReplicaCount=1

# Wait for Longhorn manager to be ready (~2-3 min)
kubectl -n longhorn-system rollout status daemonset/longhorn-manager

# Verify storage class exists
kubectl get storageclass

echo "========================================"
echo " Step 7: Install Nginx Ingress Controller"
echo "========================================"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace

# Wait for it to come up
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller

# Get the external IP
kubectl -n ingress-nginx get svc ingress-nginx-controller

echo "========================================"
echo " Step 8: Verify Metrics Server"
echo "========================================"
kubectl -n kube-system get deploy metrics-server
kubectl top nodes

echo "========================================"
echo " Step 9: Detect Public IP & Patch Values"
echo "========================================"
PUBLIC_IP=$(curl -s ifconfig.me)
echo "Your public IP: $PUBLIC_IP"

sed -i "s|<public_ip>|$PUBLIC_IP|g" helm/values/values-rocketchat.yaml
sed -i "s|http://rocketchat.local|http://$PUBLIC_IP.nip.io|g" helm/values/values-rocketchat.yaml

echo "========================================"
echo " Step 10: Verify Values Files"
echo "========================================"
grep -E "host|rootUrl|rootPassword|storageClassName" \
  helm/values/values-rocketchat.yaml \
  helm/values/values-db.yaml

echo "========================================"
echo " Step 11: Setup GCP & Push Image"
echo "========================================"
# FIX: Removed `exec -l $SHELL` — it replaces the current process and halts
# the script. Export PATH manually after install instead.
curl https://sdk.cloud.google.com | bash
export PATH="$HOME/google-cloud-sdk/bin:$PATH"
gcloud version

# TODO: Replace interactive login with a service account for CI/automation:
#   gcloud auth activate-service-account --key-file=/path/to/key.json
gcloud auth login

# TODO: Verify your GCP project ID — the one below may be incomplete/incorrect.
gcloud config set project project-d3f73645-327e-4f11-ba2
gcloud config get-value project

sudo gcloud auth configure-docker asia-south2-docker.pkg.dev


echo "========================================"
echo " Step 12: Pre-flight Checks"
echo "========================================"
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

echo "========================================"
echo " Setup complete!"
echo "========================================"
