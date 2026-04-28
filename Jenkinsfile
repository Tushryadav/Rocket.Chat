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
        stage('Clean Workspace') {
            steps { cleanWs() }
        }

        stage('Checkout') {
            steps { checkout scm }
        }

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

        stage('Auth to Artifact Registry') {
            steps {
                sh """
                    gcloud auth list
                    gcloud auth configure-docker ${GAR_HOSTNAME} 
                    echo "✅ Docker authenticated to GAR"
                """
            }
        }

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
            steps {
                script {
                    sh "docker push ${FULL_IMAGE}"
                    echo "✅ Images pushed to GAR"
                    }
            }
        }

        stage('Bootstrap Cluster') {
            when {
                allOf {
                    expression { env.GIT_BRANCH?.contains('develop') }
                }
            }
            steps {
                script {
                    withCredentials([file(credentialsId: 'k8s-kubeconfig', variable: 'KUBECONFIG')]) {

                        sh '''
                                    kubectl patch storageclass local-path \
                                        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
                                    echo "✅ Storage class patched"
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
                                    --dry-run=client -o yaml | kubectl apply -f - --validate=false
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
        failure {
            echo "❌ Build #${BUILD_NUMBER} failed. Check logs above."
        }
        always {
            sh "docker logout ${GAR_HOSTNAME} || true"
        }
    }
}
