pipeline {
    agent any

    environment {
        REGION          = 'asia-south2'
        PROJECT_ID      = 'project-d3f73645-327e-4f11-ba2'
        REPOSITORY      = 'rocketchat'
        GAR_HOSTNAME    = "${REGION}-docker.pkg.dev"

        IMAGE_NAME      = 'rocketchat-v0.1'
        FULL_IMAGE      = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:${BUILD_NUMBER}"
        LATEST_IMAGE    = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"

        SERVICE_ACC     = '440563071013-compute@developer.gserviceaccount.com'

        HELM_CHART_PATH = './helm'
        MONGO_DB        = 'rocketchat'
        MONGO_PASS      = 'verysecurepassword'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '5'))
        timeout(time: 60, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
    }

    stages {
        stage('Clean Workspace') {
            steps { cleanWs() }
        }

        stage('Checkout') {
            steps { checkout scm }
        }

        // ── Set per-branch environment ──────────────────────────────────────
        stage('Set Environment') {
            steps {
                script {
                    if (env.GIT_BRANCH?.contains('prod')) {
                        env.DEPLOY_ENV        = 'prod'
                        env.KUBECONFIG_ID     = 'k8s-kubeconfig-prod'
                        env.ROOT_URL          = 'http://prod.rocketchat.example.com'
                        env.HELM_RELEASE      = 'rocketchat-prod'
                        env.HELM_RELEASE_DB   = 'rocketchat-db-prod'
                        env.HELM_RELEASE_NGINX= 'rocketchat-nginx-prod'
                        env.K8S_NAMESPACE     = 'rocketchat-prod'

                    } else if (env.GIT_BRANCH?.contains('main')) {
                        env.DEPLOY_ENV        = 'staging'
                        env.KUBECONFIG_ID     = 'k8s-kubeconfig-staging'
                        env.ROOT_URL          = '34.138.88.107:8081'
                        env.HELM_RELEASE      = 'rocketchat-staging'
                        env.GKE_ZONE          = 'asia-south1-c'
                        env.GKE_CLUSTER       = 'gke-staging-cluster'
                        env.HELM_RELEASE_DB   = 'rocketchat-db-staging'
                        env.HELM_RELEASE_NGINX= 'rocketchat-nginx-staging'
                        env.K8S_NAMESPACE     = 'rocketchat-staging'

                    } else if (env.GIT_BRANCH?.contains('develop')) {
                        env.DEPLOY_ENV        = 'dev'
                        env.KUBECONFIG_ID     = 'k8s-kubeconfig'
                        env.ROOT_URL          = '34.138.88.107:8082'
                        env.HELM_RELEASE      = 'rocketchat-app'
                        env.GKE_CLUSTER       = 'main'
                        env.GKE_ZONE          = 'us-east1-d'
                        env.HELM_RELEASE_DB   = 'rocketchat-db'
                        env.HELM_RELEASE_NGINX= 'rocketchat-nginx'
                        env.K8S_NAMESPACE     = 'rocketchat'

                    } else {
                        env.DEPLOY_ENV        = 'none'
                        echo "⚠️ Branch ${env.GIT_BRANCH} — build only, no deploy"
                    }
                    echo "🌍 Environment: ${env.DEPLOY_ENV}"
                }
            }
        }

        // ── Validate ────────────────────────────────────────────────────────
        stage('Validate') {
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

        // ── Auth ────────────────────────────────────────────────────────────
        stage('Auth to Artifact Registry') {
            steps {
                sh """
                    gcloud auth configure-docker ${GAR_HOSTNAME}
                    echo "✅ Docker authenticated to GAR"
                """
            }
        }

        stage('Connect to GKE') {
            steps {
                sh '''
                    gcloud container clusters get-credentials ${GKE_CLUSTER} \
                        --zone ${GKE_ZONE} \
                        --project ${PROJECT_ID}
                '''
            }
        }

        // ── Build ───────────────────────────────────────────────────────────
        stage('Build Image') {
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

        // ── Scan ────────────────────────────────────────────────────────────
        stage('Scan Image (Trivy)') {
            steps {
                sh """
                    echo "🔍 Scanning for HIGH/CRITICAL CVEs..."
                    trivy image \
                        --exit-code 1 \
                        --severity HIGH,CRITICAL \
                        --ignore-unfixed \
                        ${FULL_IMAGE}
                    echo "✅ Trivy scan passed"
                """
            }
        }

        // ── Push ────────────────────────────────────────────────────────────
        stage('Push to Artifact Registry') {
            steps {
                script {
                    sh "docker push ${FULL_IMAGE}"
                    sh "docker push ${LATEST_IMAGE}"
                    echo "✅ Images pushed to GAR"
                }
            }
        }

        // ── Bootstrap ───────────────────────────────────────────────────────
        stage('Bootstrap Cluster') {
            when { expression { env.DEPLOY_ENV != 'none' } }
            steps {
                script {
                    withCredentials([file(credentialsId: env.KUBECONFIG_ID, variable: 'KUBECONFIG')]) {

                        wrap([$class: 'MaskPasswordsBuildWrapper']) {
                            sh """
                                echo "🔐 Creating GAR image-pull secret..."
                                TOKEN=\$(gcloud auth print-access-token)
                                for NS in rocketchat-db-${env.DEPLOY_ENV} rocketchat-nginx-${env.DEPLOY_ENV} ${env.K8S_NAMESPACE}; do
                                    kubectl create namespace \$NS --dry-run=client -o yaml | kubectl apply -f -
                                    kubectl create secret docker-registry gar-secret \
                                        --docker-server=${GAR_HOSTNAME} \
                                        --docker-username=oauth2accesstoken \
                                        --docker-password=\$TOKEN \
                                        --docker-email=${SERVICE_ACC} \
                                        --namespace=\$NS \
                                        --dry-run=client -o yaml | kubectl apply -f - --validate=false
                                done
                                echo "✅ GAR pull secrets ready in all namespaces"
                            """
                        }

                        echo "✅ Cluster bootstrap complete for ${env.DEPLOY_ENV}"
                    }
                }
            }
        }

        // ── Deploy ──────────────────────────────────────────────────────────
        stage('Deploy with Helm') {
            when { expression { env.DEPLOY_ENV != 'none' } }
            steps {
                script {
                    withCredentials([file(credentialsId: env.KUBECONFIG_ID, variable: 'KUBECONFIG')]) {

                        def dbNamespace    = "rocketchat-db-${env.DEPLOY_ENV == 'dev' ? '' : env.DEPLOY_ENV}".replaceAll('-$','')
                        def nginxNamespace = "rocketchat-nginx-${env.DEPLOY_ENV == 'dev' ? '' : env.DEPLOY_ENV}".replaceAll('-$','')
                        def mongoHost      = "${env.HELM_RELEASE_DB}-mongodb-0.${env.HELM_RELEASE_DB}-mongodb.${dbNamespace}.svc.cluster.local"

                        // 1. Database
                        sh """
                            helm upgrade --install ${env.HELM_RELEASE_DB} ${HELM_CHART_PATH} \
                                -f ${HELM_CHART_PATH}/values/values-db.yaml \
                                --set rocketchat.enabled=false \
                                --set nginx.enabled=false \
                                --namespace ${dbNamespace} \
                                --create-namespace \
                                --timeout=10m
                        """
                        echo "✅ DB deployed"

                        // 2. Nginx
                        sh """
                            helm upgrade --install ${env.HELM_RELEASE_NGINX} ${HELM_CHART_PATH} \
                                -f ${HELM_CHART_PATH}/values/values-nginx.yaml \
                                --set mongodb.enabled=false \
                                --set rocketchat.enabled=false \
                                --namespace ${nginxNamespace} \
                                --create-namespace \
                                --wait \
                                --timeout=5m
                        """
                        echo "✅ Nginx deployed"

                        // 3. RocketChat app
                        sh """
                            helm upgrade --install ${env.HELM_RELEASE} ${HELM_CHART_PATH} \
                                -f ${HELM_CHART_PATH}/values/values-rocketchat.yaml \
                                --set mongodb.enabled=false \
                                --set nginx.enabled=false \
                                --set rocketchat.mongoUrl="mongodb://${MONGO_DB}:${MONGO_PASS}@${mongoHost}:27017/rocketchat?replicaSet=rs0&authSource=admin" \
                                --set rocketchat.mongoOplogUrl="mongodb://${MONGO_DB}:${MONGO_PASS}@${mongoHost}:27017/local?replicaSet=rs0&authSource=admin" \
                                --set rocketchat.rootUrl="${env.ROOT_URL}" \
                                --namespace ${env.K8S_NAMESPACE} \
                                --create-namespace \
                                --wait \
                                --timeout=10m
                        """
                        echo "✅ RocketChat deployed to ${env.DEPLOY_ENV}"
                    }
                }
            }
        }

        // ── Cleanup ─────────────────────────────────────────────────────────
        stage('Cleanup') {
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
            echo """
            ╔══════════════════════════════════════╗
            ║        BUILD SUCCESSFUL ✅           ║
            ╠══════════════════════════════════════╣
            ║ Branch : ${GIT_BRANCH}
            ║ Env    : ${DEPLOY_ENV}
            ║ Image  : ${FULL_IMAGE}
            ║ Build  : #${BUILD_NUMBER}
            ╚══════════════════════════════════════╝
            """
        }
        failure {
            echo "❌ Build #${BUILD_NUMBER} failed on ${GIT_BRANCH}. Check logs above."
        }
        always {
            sh "docker logout ${GAR_HOSTNAME} || true"
        }
    }
}
