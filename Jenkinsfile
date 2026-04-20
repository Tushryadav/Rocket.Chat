pipeline {
    agent any

    environment {
        ACR_NAME         = 'rocketchat'
        ACR_LOGIN_SERVER = "rocketchat.azurecr.io"
        IMAGE_NAME       = 'rocketchat-v0.1'
        IMAGE_TAG        = "v0.0.1"
        FULL_IMAGE       = "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:${BUILD_NUMBER}"
        LATEST_IMAGE     = "${ACR_LOGIN_SERVER}/${IMAGE_NAME}:latest"
        ACR_CREDENTIALS  = 'rocketchat.azurecr.io'
        KUBECONFIG_CRED  = 'k8s-kubeconfig'        // Jenkins credential ID — add this in Jenkins → Credentials
        HELM_RELEASE     = 'rocketchat'
        HELM_CHART_PATH  = './helm'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '5'))
        timeout(time: 60, unit: 'MINUTES')
        disableConcurrentBuilds()
        timestamps()
    }

    stage('Clean Workspace') {
        steps {
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

        stage('Login to ACR') {
            steps {
                script {
                    withCredentials([
                        usernamePassword(
                            credentialsId: ACR_CREDENTIALS,
                            usernameVariable: 'ACR_USER',
                            passwordVariable: 'ACR_PASS'
                        )
                    ]) {
                        sh "echo \$ACR_PASS | docker login ${ACR_LOGIN_SERVER} --username \$ACR_USER --password-stdin"
                        echo "Logged into ${ACR_LOGIN_SERVER}"
                    }
                }
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

        stage('Push to ACR') {
            steps {
                script {
                    try {
                        [FULL_IMAGE, LATEST_IMAGE].each { image ->
                            sh "docker push ${image}"
                            echo "✅ Pushed: ${image}"
                        }

                        // Only set if ALL pushes succeed
                        env.IMAGES_PUSHED = "true"

                    } catch (err) {
                        env.IMAGES_PUSHED = "false"
                        error "❌ Image push failed"
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
                    withCredentials([
                        file(
                            credentialsId: KUBECONFIG_CRED,
                            variable: 'KUBECONFIG'
                        )
                    ]) {
                        sh """
                            helm upgrade --install ${HELM_RELEASE} ${HELM_CHART_PATH} \
                                -f ${HELM_CHART_PATH}/values/values-db.yaml \
                                -f ${HELM_CHART_PATH}/values/values-nginx.yaml \
                                -f ${HELM_CHART_PATH}/values/values-rocketchat.yaml \
                                --set rocketchat.image.repository=${ACR_LOGIN_SERVER}/${IMAGE_NAME} \
                                --set rocketchat.image.tag=${BUILD_NUMBER} \
                                --wait \
                                --timeout 5m
                        """
                        echo "✅ Helm deploy successful — release: ${HELM_RELEASE} image tag: ${BUILD_NUMBER}"
 
                        // Verify rollout
                        sh """
                            kubectl rollout status deployment/${HELM_RELEASE}-rocketchat --timeout=3m
                            kubectl get pods -l app=rocketchat
                        """
                    }
                }
            }
        }

        post {
            success {
                script {
                    echo """
                    ╔══════════════════════════════════════╗
                    ║         BUILD SUCCESSFUL ✅          ║
                    ╠══════════════════════════════════════╣
                    ║ Image : ${FULL_IMAGE}
                    ║ Latest: ${LATEST_IMAGE}
                    ║ Build : #${BUILD_NUMBER}
                    ║ Commit: ${GIT_COMMIT.take(7)}
                    ╚══════════════════════════════════════╝
                    """
                }
            }
            failure {
                echo "❌ Build #${BUILD_NUMBER} failed. Check logs above."
            }
            always {
                sh "docker logout ${ACR_LOGIN_SERVER} || true"
            }
        }
    }
