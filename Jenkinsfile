pipeline {
    agent any

    environment {
        REGION          = 'asia-south2'
        REPOSITORY      = 'rocketchat'
        GAR_HOSTNAME    = "${REGION}-docker.pkg.dev"
        IMAGE_NAME      = 'rocketchat-v0.1'
        HELM_CHART_PATH = './helm'
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
                        env.GKE_ZONE          = 'us-east1'
                        env.GKE_CLUSTER       = 'prod'
                        env.HELM_RELEASE      = 'rocketchat-prod'
                        env.HELM_RELEASE_DB   = 'rocketchat-db-prod'
                        env.HELM_RELEASE_NGINX= 'rocketchat-nginx-prod'
                        env.K8S_NAMESPACE     = 'rocketchat-prod'
                        env.PROJECT_ID        = 'project-d3f73645-327e-4f11-ba2'
                        env.DB_NAMESPACE       = 'rocketchat-db-prod'
                        env.NGINX_NAMESPACE    = 'rocketchat-nginx-prod'

                    } else if (env.GIT_BRANCH?.contains('staging')) {
                        env.DEPLOY_ENV        = 'staging'
                        env.KUBECONFIG_ID     = 'k8s-kubeconfig-staging'
                        env.HELM_RELEASE      = 'rocketchat-staging'
                        env.GKE_ZONE          = 'us-east1'
                        env.GKE_CLUSTER       = 'staging'
                        env.HELM_RELEASE_DB   = 'rocketchat-db-staging'
                        env.HELM_RELEASE_NGINX= 'rocketchat-nginx-staging'
                        env.K8S_NAMESPACE     = 'rocketchat-staging'
                        env.DB_NAMESPACE       = 'rocketchat-db-staging'
                        env.NGINX_NAMESPACE    = 'rocketchat-nginx-staging'

                    } else if (env.GIT_BRANCH?.contains('develop')) {
                        env.DEPLOY_ENV        = 'dev'
                        env.KUBECONFIG_ID     = 'k8s-kubeconfig'
                        env.HELM_RELEASE      = 'rocketchat-app'
                        env.GKE_CLUSTER       = 'main'
                        env.GKE_ZONE          = 'us-east1'
                        env.HELM_RELEASE_DB   = 'rocketchat-db'
                        env.HELM_RELEASE_NGINX= 'rocketchat-nginx'
                        env.K8S_NAMESPACE     = 'rocketchat'
                        env.DB_NAMESPACE       = 'rocketchat-db'
                        env.NGINX_NAMESPACE    = 'rocketchat-nginx'

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
            when { expression { env.DEPLOY_ENV != 'none' } }
            steps {
                withCredentials([
                    string(credentialsId: 'gcp-project-id', variable: 'PROJECT_ID')
                ]) {
                sh '''
                    gcloud container clusters get-credentials ${GKE_CLUSTER} \
                        --zone ${GKE_ZONE} \
                        --project ${PROJECT_ID}
                   '''
                }
            }
        }

        // ── Build ───────────────────────────────────────────────────────────
        stage('Build Image') {
            steps {
                script {
                    withCredentials([
                        string(credentialsId: 'gcp-project-id', variable: 'PROJECT_ID')
                    ]) {
                        def shortCommit = env.GIT_COMMIT ? env.GIT_COMMIT.take(7) : 'unknown'
                        env.FULL_IMAGE   = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:${BUILD_NUMBER}"
                        env.LATEST_IMAGE = "${GAR_HOSTNAME}/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"
                        sh """
                            docker build \
                                -t ${env.FULL_IMAGE} \
                                -t ${env.LATEST_IMAGE} \
                                --label build-number=${BUILD_NUMBER} \
                                --label git-commit=${shortCommit} \
                                --label git-branch=${GIT_BRANCH} \
                                --label build-date=\$(date -u +%Y-%m-%dT%H:%M:%SZ) \
                                .
                        """
                        echo "✅ Image built: ${env.FULL_IMAGE}"
                    }           // closes withCredentials
                }               // closes script
            }                   // closes steps
        }

        // ── Scan ────────────────────────────────────────────────────────────
        // stage('Scan Image (Trivy)') {
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
                    withCredentials([file(credentialsId: env.KUBECONFIG_ID, variable: 'KUBECONFIG'),
                        string(credentialsId: 'gcp-service-acc', variable: 'SERVICE_ACC')
                    ]) {
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
                    withCredentials([file(credentialsId: env.KUBECONFIG_ID, variable: 'KUBECONFIG'),
                                     string(credentialsId: 'mongo-db-user',  variable: 'MONGO_USER'),
                                     string(credentialsId: 'mongo-db-pass',  variable: 'MONGO_PASS')
                    ]) {
                        
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
                        
                        // 3. Fetch LB IP dynamically from this cluster
                        def lbIp = ""
                        echo "⏳ Waiting for nginx LoadBalancer IP..."
                        for (int i = 0; i < 24; i++) {
                            lbIp = sh(
                                script: """
                                    kubectl get svc ${env.HELM_RELEASE_NGINX}-nginx \
                                        -n ${env.NGINX_NAMESPACE} \
                                        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
                                """,
                                returnStdout: true
                            ).trim()
                            if (lbIp) {
                                echo "✅ LB IP: ${lbIp}"
                                break
                            }
                            echo "Waiting for LB IP... attempt ${i + 1}/24"
                            sleep(10)
                        }
                        if (!lbIp) error "❌ LB IP not assigned after 4 minutes"

                        def rootUrl = "http://${lbIp}"
                        echo "🌍 ROOT_URL: ${rootUrl}"

                        // 3. RocketChat app
                        sh """
                            helm upgrade --install ${env.HELM_RELEASE} ${HELM_CHART_PATH} \
                                -f ${HELM_CHART_PATH}/values/values-rocketchat.yaml \
                                --set mongodb.enabled=false \
                                --set nginx.enabled=false \
                                --set rocketchat.mongoUrl="mongodb://\$MONGO_USER:\$MONGO_PASS@${mongoHost}:27017/rocketchat?replicaSet=rs0&authSource=admin" \
                                --set rocketchat.mongoOplogUrl="mongodb://\$MONGO_USER:\$MONGO_PASS@${mongoHost}:27017/local?replicaSet=rs0&authSource=admin" \
                                --set rocketchat.rootUrl="${rootUrl}" \
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
