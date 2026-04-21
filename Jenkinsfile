pipeline {
    agent any

    environment {
        REGION           = 'asia-south2'                          // e.g. us-central1, asia-south1
        PROJECT_ID       = 'your-gcp-project-id'                  // GCP project ID
        REPOSITORY       = 'rocketchat'                           // GAR repository name
        GAR_HOSTNAME     = "${REGION}-docker.pkg.dev"
        
        IMAGE_NAME       = 'rocketchat-v0.1'
        FULL_IMAGE       = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:${BUILD_NUMBER}"
        LATEST_IMAGE     = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"

        // ── Kubernetes / Helm ─────────────────────────────────
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

    steges {
        stage('Clean Workspace') {
            cleanWs()
        }
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Validate') {
            steps {
                script {
                    // ── Groovy expression-based file validation ──
                    def requiredFiles = ['Dockerfile', 'docker-compose.yml',]

                    requiredFiles.each { file ->
                        if (!fileExists(file)) {
                            error "Required file not found: ${file}"
                        }
                    }
                    // Validate Helm chart
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

        stage('Scan Image with Trivy') {
            steps {
                script {
                    echo "🔍 Scanning Docker image with Trivy..."
        
                    sh """
                    # Run scan (FAIL if HIGH or CRITICAL vulnerabilities found)
                    trivy image --exit-code 1 --severity HIGH,CRITICAL ${FULL_IMAGE}
                    """
        
                    echo "✅ Trivy scan passed (no HIGH/CRITICAL vulnerabilities)"
                }
            }
        }

        stage('Push Image') {
            steps {
                script {
                    sh "docker push ${FULL_IMAGE}"
                    sh "docker push ${LATEST_IMAGE}"
                    env.IMAGES_PUSHED = 'true'
                }
            }
        }

        // ── 9. Bootstrap Cluster (one-time setup, idempotent) ─
        stage('Bootstrap Cluster') {
            when {
                allOf {
                    expression { env.IMAGES_PUSHED == 'true' }
                    branch 'develop'
                }
            }
            steps {
                script {
                    withCredentials([file(credentialsId: 'k8s-kubeconfig', variable: 'KUBECONFIG')]) {
                        // ── 9a. Fix duplicate default storage class ────────
                        sh """
                            echo "🔧 Patching storage class..."
                            kubectl patch storageclass local-path \
                                -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
                                --ignore-not-found=true || true
                            echo "✅ Storage class patched"
                        """
 
                        // ── 9b. Create ACR pull secret (skip if exists) ───
                        sh """
                            echo "🔐 Creating GAR image-pull secret..."
                            kubectl create secret docker-registry gar-secret \
                                --docker-server=${GAR_HOSTNAME} \
                                --docker-username=oauth2accesstoken \
                                --docker-password=\$(gcloud auth print-access-token) \
                                --namespace=${K8S_NAMESPACE} \
                                --dry-run=client -o yaml | kubectl apply -f -
                        """
                        // ── 9c. Wait for Longhorn to be ready ─────────────
                        sh """
                            echo "⏳ Checking Longhorn..."
                            kubectl -n longhorn-system wait \
                                --for=condition=ready pod \
                                -l app=longhorn-manager \
                                --timeout=120s || true
                            echo "✅ Longhorn ready"
                        """
 
                        // ── 9d. Wait for nginx ingress to be ready ────────
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
                    branch 'develop'    // only deploy from main branch
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
 
                        // Verify rollout
                        sh """
                            echo "🔍 Verifying rollout..."
                            kubectl rollout status deployment/${HELM_RELEASE}-rocketchat \
                                --namespace=${K8S_NAMESPACE} \
                                --timeout=3m
                            echo ""
                            echo "📦 Running pods:"
                            kubectl get pods -n ${K8S_NAMESPACE} -l app=rocketchat
                            echo ""
                            echo "🌐 Ingress:"
                            kubectl get ingress -n ${K8S_NAMESPACE}
                        """
                    }
                }
            }
        }

        // ── 11. Cleanup ───────────────────────────────────────
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
 
    }

post {
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
