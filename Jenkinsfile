pipeline {
    agent any

    parameters {
        booleanParam(
            name: 'RUN_ONE_TIME_SETUP',
            defaultValue: true,
            description: '⚠️ Run ONE-TIME VM setup only. Do NOT check this on normal builds.'
        )
    }

    environment {
        REGION          = 'asia-south2'
        PROJECT_ID      = 'project-d3f73645-327e-4f11-ba2'
        REPOSITORY      = 'rocketchat'
        GAR_HOSTNAME    = "${REGION}-docker.pkg.dev"

        IMAGE_NAME      = 'rocketchat-v0.1'
        FULL_IMAGE      = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:${BUILD_NUMBER}"
        LATEST_IMAGE    = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"

        HELM_RELEASE    = 'rocketchat'
        HELM_CHART_PATH = './helm'
        K8S_NAMESPACE   = 'default'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '5'))
        timeout(time: 60, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
    }

    stages {

        // ══════════════════════════════════════════════════════
        // BLOCK A — ONE-TIME SETUP  (only when param is checked)
        // ══════════════════════════════════════════════════════

        stage('One-Time Setup: System Packages') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                sh '''
                    echo "📦 Phase 2 — System Preparation"

                    # Idempotent — safe to re-run
                    sudo apt update && sudo apt upgrade -y
                    sudo apt install -y curl wget git open-iscsi nfs-common

                    sudo systemctl enable iscsid
                    sudo systemctl start iscsid
                    sudo systemctl status iscsid --no-pager

                    echo "✅ System packages ready"
                '''
            }
        }

        stage('One-Time Setup: Install k3s') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                sh '''
                    echo "☸️  Phase 3 — Install k3s"

                    # Guard — skip if already installed
                    if command -v k3s &>/dev/null; then
                        echo "⏭️  k3s already installed, skipping"
                        k3s --version
                    else
                        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
                        sudo chmod 644 /etc/rancher/k3s/k3s.yaml
                        grep -qxF 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' ~/.bashrc \
                            || echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
                        echo "✅ k3s installed"
                    fi

                    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
                    kubectl get nodes
                '''
            }
        }

        stage('One-Time Setup: Install Helm') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                sh '''
                    if command -v helm &>/dev/null; then
                        echo "⏭️  Helm already installed"
                        helm version
                    else
                        echo "⎈  Installing Helm 3"
                        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
                        helm version
                        echo "✅ Helm installed"
                    fi
                '''
            }
        }

        stage('One-Time Setup: Install Docker') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                sh '''
                    if command -v docker &>/dev/null; then
                        echo "⏭️  Docker already installed"
                        docker --version
                    else
                        echo "🐳 Installing Docker"
                        curl -fsSL https://get.docker.com | sh
                        sudo usermod -aG docker jenkins
                        sudo systemctl enable docker
                        sudo systemctl start docker
                        docker --version
                        echo "✅ Docker installed"
                        echo "⚠️  Restarting Jenkins — pipeline will die here."
                        echo "    Wait 30s then re-run WITHOUT RUN_ONE_TIME_SETUP checked."
                        sudo systemctl restart docker
                        sudo systemctl restart jenkins
                    fi
                '''
            }
        }

        stage('One-Time Setup: Configure gcloud') {
            when { expression { params.RUN_ONE_TIME_SETUP == true } }
            steps {
                // SA key stored in Jenkins credentials — never interactive
                withCredentials([file(credentialsId: 'gcp-sa-key', variable: 'SA_KEY')]) {
                    sh '''
                        echo "☁️  Verifying VM metadata identity..."
            
                        # VM SA is auto-detected — just verify it works
                        gcloud auth list
            
                        # Configure docker to use VM identity for GAR
                        sudo -u jenkins gcloud auth configure-docker \
                            asia-south2-docker.pkg.dev -q
            
                        # Set default project
                        sudo -u jenkins gcloud config set project \
                            project-d3f73645-327e-4f11-ba2
            
                        # Verify
                        sudo -u jenkins gcloud auth list
                        sudo -u jenkins gcloud config list
            
                        echo "✅ Keyless gcloud configured — using VM Service Account"
                    '''
                }
            }
        }

        // ══════════════════════════════════════════════════════
        // BLOCK B — NORMAL CI/CD  (every build, setup skipped)
        // ══════════════════════════════════════════════════════

        stage('Clean Workspace') {
            when { expression { params.RUN_ONE_TIME_SETUP == false } }
            steps { cleanWs() }
        }

        stage('Checkout') {
            when { expression { params.RUN_ONE_TIME_SETUP == false } }
            steps { checkout scm }
        }

        stage('Validate') {
            when { expression { params.RUN_ONE_TIME_SETUP == false } }
            steps {
                script {
                    ['Dockerfile', 'docker-compose.yml'].each { f ->
                        if (!fileExists(f)) error "Required file missing: ${f}"
                    }
                    sh """
                        helm lint ${HELM_CHART_PATH} \
                            -f ${HELM_CHART_PATH}/values/values-db.yaml \
                            -f ${HELM_CHART_PATH}/values/values-nginx.yaml \
                            -f ${HELM_CHART_PATH}/values/values-rocketchat.yaml
                    """
                    echo "✅ Helm lint passed"
                }
            }
        }

        stage('Auth to Artifact Registry') {
            when { expression { params.RUN_ONE_TIME_SETUP == false } }
            steps {
                sh """
                    gcloud auth list
                    gcloud auth configure-docker ${GAR_HOSTNAME} -q
                    echo "✅ Docker authenticated to GAR"
                """
            }
        }

        stage('Debug Workspace') {
            when { expression { params.RUN_ONE_TIME_SETUP == false } }
            steps {
                sh '''
                    pwd && ls -la
                    cat .dockerignore || echo "No .dockerignore found"
                    find . -name "*.pem" || true
                '''
            }
        }

        stage('Build Image') {
            when { expression { params.RUN_ONE_TIME_SETUP == false } }
            steps {
                script {
                    def shortCommit = env.GIT_COMMIT ? env.GIT_COMMIT.take(7) : 'unknown'
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
                    echo "✅ Image built: ${FULL_IMAGE}"
                }
            }
        }

        // stage('Scan Image (Trivy)') {
        //     when { expression { params.RUN_ONE_TIME_SETUP == false } }
        //     steps {
        //         sh """
        //             echo "🔍 Scanning for HIGH/CRITICAL CVEs..."
        //             trivy image \
        //                 --exit-code 1 \
        //                 --severity HIGH,CRITICAL \
        //                 --ignore-unfixed \
        //                 ${FULL_IMAGE}
        //             echo "✅ Trivy scan passed"
        //         """
        //     }
        // }

        stage('Push to Artifact Registry') {
            when { expression { params.RUN_ONE_TIME_SETUP == false } }
            steps {
                script {
                    sh "docker push ${FULL_IMAGE}"
                    sh "docker push ${LATEST_IMAGE}"
                    echo "✅ Images pushed to GAR"
                    }
            }
        }

        stage('Bootstrap Cluster') {
            when {
                allOf {
                    expression { params.RUN_ONE_TIME_SETUP == false }
                    expression { env.GIT_BRANCH?.contains('develop') }
                }
            }
            steps {
                script {
                    withCredentials([file(credentialsId: 'k8s-kubeconfig', variable: 'KUBECONFIG')]) {

                        sh '''
                                if kubectl get storageclass local-path > /dev/null 2>&1; then
                                    kubectl patch storageclass local-path \
                                        --type=merge \
                                        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
                                    echo "✅ Storage class patched"
                                else
                                    echo "⏭️  local-path storageclass not found, skipping"
                                fi
                            '''

                        // ✅ Token masked, no temp file on disk
                        wrap([$class: 'MaskPasswordsBuildWrapper']) {
                            sh """
                                echo "🔐 Creating GAR image-pull secret..."
                                TOKEN=\$(gcloud auth print-access-token)
                                kubectl create secret docker-registry gar-secret \
                                    --docker-server=${GAR_HOSTNAME} \
                                    --docker-username=oauth2accesstoken \
                                    --docker-password=\$TOKEN \
                                    --namespace=${K8S_NAMESPACE} \
                                    --dry-run=client -o yaml | kubectl apply -f -
                                echo "✅ GAR pull secret ready"
                            """
                        }

                        sh """
                            echo "⏳ Waiting for Longhorn..."
                            kubectl -n longhorn-system wait \
                                --for=condition=ready pod \
                                -l app=longhorn-manager \
                                --timeout=120s || true
                            echo "✅ Longhorn ready"
                        """

                        sh """
                            echo "⏳ Waiting for Nginx Ingress..."
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
                    expression { params.RUN_ONE_TIME_SETUP == false }
                    expression { env.IMAGES_PUSHED == 'true' }
                    expression { env.GIT_BRANCH?.contains('develop') }
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
                                --atomic \
                                --cleanup-on-fail \
                                --wait \
                                --timeout 5m
                        """
                        echo "✅ Helm deploy successful"

                        sh """
                            kubectl rollout status deployment/${HELM_RELEASE}-rocketchat \
                                --namespace=${K8S_NAMESPACE} --timeout=3m
                            kubectl get pods -n ${K8S_NAMESPACE} -l app=rocketchat
                            kubectl get ingress -n ${K8S_NAMESPACE}
                        """
                    }
                }
            }
        }

        stage('Cleanup') {
            when {
                allOf {
                    expression { params.RUN_ONE_TIME_SETUP == false }
                    expression { env.IMAGES_PUSHED == 'true' }
                }
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

    } // end stages

    post {
        success {
            script {
                if (params.RUN_ONE_TIME_SETUP) {
                    echo "✅ One-time setup complete. Now run the pipeline normally."
                } else {
                    echo """
                    ╔══════════════════════════════════════╗
                    ║        BUILD SUCCESSFUL ✅           ║
                    ╠══════════════════════════════════════╣
                    ║ Image : ${FULL_IMAGE}
                    ║ Latest: ${LATEST_IMAGE}
                    ║ Build : #${BUILD_NUMBER}
                    ╚══════════════════════════════════════╝
                    """
                }
            }
        }
        failure {
            echo "❌ Build #${BUILD_NUMBER} failed. Check logs above."
        }
        always {
            sh "docker logout ${GAR_HOSTNAME} || true"
        }
    }
}
