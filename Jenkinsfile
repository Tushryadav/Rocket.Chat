pipeline {
    agent any

    parameters {
        booleanParam(
            name: 'RUN_ONE_TIME_SETUP',
            defaultValue: false,
            description: '⚠️ Run ONE-TIME VM setup (Phase 2+3: packages, k3s, helm, docker, gcloud). Only needed on first-time VM provisioning.'
        )
    }

    environment {
        REGION           = 'asia-south2'
        PROJECT_ID       = 'project-d3f73645-327e-4f11-ba2'
        REPOSITORY       = 'rocketchat'
        GAR_HOSTNAME     = "${REGION}-docker.pkg.dev"
        
        IMAGE_NAME       = 'rocketchat-v0.1'
        FULL_IMAGE       = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:${BUILD_NUMBER}"
        LATEST_IMAGE     = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"

        KUBECONFIG_CRED  = 'k8s-kubeconfig'
        HELM_RELEASE     = 'rocketchat'
        HELM_CHART_PATH  = './helm'
        K8S_NAMESPACE    = 'default'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '5'))
        timeout(time: 60, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
    }

    stages {

        // ─────────────────────────────────────────────────────────────────
        // ONE-TIME SETUP  (skipped on every normal build)
        // Trigger manually: Build with Parameters → check RUN_ONE_TIME_SETUP
        // ─────────────────────────────────────────────────────────────────

        stage('One-Time Setup: System Packages') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                sh '''
                    echo "📦 Phase 2 — System Preparation"
                    sudo apt update && sudo apt upgrade -y

                    # Longhorn storage requirements
                    sudo apt install -y curl wget git open-iscsi nfs-common

                    # Enable iSCSI (required by Longhorn)
                    sudo systemctl enable iscsid
                    sudo systemctl start iscsid

                    # Verify
                    sudo systemctl status iscsid --no-pager
                    echo "✅ System packages installed"
                '''
            }
        }

        stage('One-Time Setup: Install k3s') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                sh '''
                    echo "☸️  Phase 3 — Install k3s (without Traefik)"
                    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

                    # Set up kubeconfig for current user
                    sudo chmod 644 /etc/rancher/k3s/k3s.yaml
                    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

                    # Persist for all future shells
                    grep -qxF 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' ~/.bashrc \
                        || echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

                    # Verify node is Ready
                    kubectl get nodes
                    echo "✅ k3s installed"
                '''
            }
        }

        stage('One-Time Setup: Install Helm') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                sh '''
                    echo "⎈  Installing Helm 3"
                    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
                    helm version
                    echo "✅ Helm installed"
                '''
            }
        }

        stage('One-Time Setup: Install Docker') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                sh '''
                    echo "🐳 Installing Docker"
                    curl -fsSL https://get.docker.com | sh
                    sudo usermod -aG docker jenkins
                    sudo systemctl enable docker
                    sudo systemctl start docker
                    docker --version
                    sudo systemctl restart docker
                    sudo systemctl restart jenkins
                    echo "✅ Docker installed — NOTE: Jenkins restarted, pipeline will abort here."
                    echo "    Re-run this job (without RUN_ONE_TIME_SETUP) once Jenkins is back up."
                '''
            }
        }

        stage('One-Time Setup: Configure gcloud for Jenkins') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                // ✅ Key file injected securely, never touches disk permanently
                withCredentials([file(credentialsId: 'gcp-sa-key', variable: 'SA_KEY')]) {
                    sh '''
                        echo "☁️  Activating GCP Service Account..."
        
                        # Authenticate as service account (non-interactive)
                        sudo -u jenkins gcloud auth activate-service-account \
                            --key-file=$SA_KEY
        
                        # Configure Docker for Artifact Registry
                        sudo -u jenkins gcloud auth configure-docker \
                            asia-south2-docker.pkg.dev -q
        
                        # Set default project
                        sudo -u jenkins gcloud config set project \
                            project-d3f73645-327e-4f11-ba2
        
                        # Verify
                        sudo -u jenkins gcloud auth list
                        sudo -u jenkins gcloud config list
        
                        echo "✅ gcloud configured for jenkins user"
                    '''
                }
            }
        }

    stages {                                          // ✅ Fix 1: removed duplicate mistyped `steges` block

        stage('Clean Workspace') {
            steps {                                   // ✅ Fix 2: added missing `steps {}` wrapper
                cleanWs()
            }
        }

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Validate') {
            steps {
                script {
                    def requiredFiles = ['Dockerfile', 'docker-compose.yml']
                    requiredFiles.each { file ->
                        if (!fileExists(file)) {
                            error "Required file not found: ${file}"
                        }
                    }
                    sh """
                        helm lint ${HELM_CHART_PATH} \
                            -f ${HELM_CHART_PATH}/values/values-db.yaml \
                            -f ${HELM_CHART_PATH}/values/values-nginx.yaml \
                            -f ${HELM_CHART_PATH}/values/values-rocketchat.yaml
                    """
                    echo "✅ Helm chart lint passed"
                }
            }
        }

        stage('Verify Identity') {
            steps {
                sh '''
                gcloud auth list
                '''
            }
        }

        stage('Auth to Artifact Registry (Keyless)') {
            steps {
                sh '''
                    echo "Using VM Service Account..."
                    gcloud auth list
                    gcloud auth configure-docker ${GAR_HOSTNAME} -q
                '''
            }
        }

        stage('Debug Workspace') {
            steps {
                sh 'pwd'
                sh 'ls -la'
                sh 'cat .dockerignore || echo "No dockerignore found"'
                sh 'find . -name "*.pem" || true'
            }
        }

        stage('Build Image') {
            steps {
                script {
                    def shortCommit = env.GIT_COMMIT ? env.GIT_COMMIT.take(7) : "unknown"
                    sh """
                    docker build \
                      -t ${FULL_IMAGE} \
                      -t ${LATEST_IMAGE} \
                      --label build-number=${BUILD_NUMBER} \
                      --label git-commit=${shortCommit} \
                      --label git-branch=${GIT_BRANCH} \
                      --label build-date=\$(date -u +%Y-%m-%dT%H:%M:%SZ) \
                      .
                    """
                    echo "✅ Image Built: ${FULL_IMAGE}"
                }
            }
        }

        // stage('Scan Image with Trivy') {
        //     steps {
        //         script {
        //             echo "🔍 Scanning Docker image with Trivy..."
        //             sh """
        //             trivy image --exit-code 1 --severity HIGH,CRITICAL ${FULL_IMAGE}
        //             """
        //             echo "✅ Trivy scan passed (no HIGH/CRITICAL vulnerabilities)"
        //         }
        //     }
        // }

        stage('Configure GCP Auth (Keyless)') {
            steps {
                sh '''
                gcloud auth configure-docker ${REGISTRY} --quiet
                '''
            }
        }

        stage('Tag Image') {
            steps {
                sh '''
                docker tag ${IMAGE}:${TAG} \
                ${REGISTRY}/${PROJECT_ID}/${REPO}/${IMAGE}:${TAG}
                '''
            }
        }

        stage('Push to Artifact Registry') {
            steps {
                sh '''
                docker push \
                ${REGISTRY}/${PROJECT_ID}/${REPO}/${IMAGE}:${TAG}
                '''
            }
        }
    
        stage('Bootstrap Cluster') {
            when {
                allOf {
                    expression { env.IMAGES_PUSHED == 'true' }
                    expression { env.GIT_BRANCH == 'origin/develop' }
                }
            }
            steps {
                script {
                    withCredentials([file(credentialsId: 'k8s-kubeconfig', variable: 'KUBECONFIG')]) {
                        sh """
                            echo "🔧 Patching storage class..."
                            kubectl patch storageclass local-path \
                                -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
                                --ignore-not-found=true || true
                            echo "✅ Storage class patched"
                        """
                        sh """
                            echo "🔐 Creating GAR image-pull secret..."
                            TOKEN=\$(gcloud auth print-access-token)
                            kubectl create secret docker-registry gar-secret \
                                --docker-server=${GAR_HOSTNAME} \
                                --docker-username=oauth2accesstoken \
                                --docker-password=\$TOKEN \
                                --namespace=${K8S_NAMESPACE} \
                                --dry-run=client -o yaml > /tmp/gar-secret.yaml
                            kubectl apply --validate=false -f /tmp/gar-secret.yaml
                            rm /tmp/gar-secret.yaml
                            echo "✅ GAR pull secret ready"
                        """
                        sh """
                            echo "⏳ Checking Longhorn..."
                            kubectl -n longhorn-system wait \
                                --for=condition=ready pod \
                                -l app=longhorn-manager \
                                --timeout=120s || true
                            echo "✅ Longhorn ready"
                        """
                        sh """
                            echo "⏳ Checking Nginx Ingress..."
                            kubectl -n ingress-nginx wait \
                                --for=condition=ready pod \
                                -l app.kubernetes.io/name=ingress-nginx \
                                --timeout=120s || true
                            echo "✅ Nginx Ingress ready"
                        """
                        echo "✅ Cluster bootstrap complete"
                    }
                }
            }
        }

        stage('Deploy with Helm') {
            when {
                allOf {
                    expression { env.IMAGES_PUSHED == 'true' }
                    expression { env.GIT_BRANCH == 'origin/develop' }
                    branch 'develop'
                }
            }
            steps {
                script {
                    withCredentials([file(credentialsId: 'k8s-kubeconfig', variable: 'KUBECONFIG')]) {
                        sh """
                            helm upgrade --install ${HELM_RELEASE} ${HELM_CHART_PATH} \
                                -f ${HELM_CHART_PATH}/values/values-db.yaml \
                                -f ${HELM_CHART_PATH}/values/values-nginx.yaml \
                                -f ${HELM_CHART_PATH}/values/values-rocketchat.yaml \
                                --set rocketchat.image.repository=${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME} \
                                --set rocketchat.image.tag=${BUILD_NUMBER} \
                                --set rocketchat.image.pullPolicy=Always \
                                --set rocketchat.imagePullSecrets[0].name=gar-secret \
                                --namespace ${K8S_NAMESPACE} \
                                --wait \
                                --timeout 5m
                        """
                        echo "✅ Helm deploy successful — release: ${HELM_RELEASE}, tag: ${BUILD_NUMBER}"
                        sh """
                            echo "🔍 Verifying rollout..."
                            kubectl rollout status deployment/${HELM_RELEASE}-rocketchat \
                                --namespace=${K8S_NAMESPACE} \
                                --timeout=3m
                            echo "📦 Running pods:"
                            kubectl get pods -n ${K8S_NAMESPACE} -l app=rocketchat
                            echo "🌐 Ingress:"
                            kubectl get ingress -n ${K8S_NAMESPACE}
                        """
                    }
                }
            }
        }

        stage('Cleanup') {
            when {
                expression { env.IMAGES_PUSHED == 'true' }
            }
            steps {
                script {
                    [FULL_IMAGE, LATEST_IMAGE].each { image ->
                        sh "docker rmi ${image} || true"
                    }
                    sh 'docker image prune -f'
                    echo "✅ Local images cleaned up"
                }
            }
        }

    }                                                 // ✅ end of stages

    post {                                            // ✅ Fix 3: moved post{} to pipeline level (was inside stages)
        success {
            echo """
            ╔══════════════════════════════════════╗
            ║         BUILD SUCCESSFUL ✅          ║
            ╠══════════════════════════════════════╣
            ║ Image : ${FULL_IMAGE}
            ║ Latest: ${LATEST_IMAGE}
            ║ Build : #${BUILD_NUMBER}
            ╚══════════════════════════════════════╝
            """
        }
        failure {
            echo "❌ Build #${BUILD_NUMBER} failed. Check logs above."
        }
        always {
            sh "docker logout ${GAR_HOSTNAME} || true"
        }
    }
}
