// CI for one service in a GitHub multibranch job. Every branch and pull
// request validates, builds, tests, and scans. main additionally publishes the
// exact scanned image and its chart, and commits both to the first
// environment's state file; the deploy job releases them from there.
//
//   chart:   service Helm chart; its name is the service's state entry
//   context: BuildKit context containing the Dockerfile
//   path:    service directory; only changes below it run service stages
def call(Map args) {
    if (!args?.chart || !args?.context || !args?.path) {
        error('servicePipeline: chart, context and path are required')
    }

    String serviceChanges = "${args.path.replaceAll('/+$', '')}/**"

    pipeline {
        agent { label 'lab-ci-runner' }
        options {
            skipDefaultCheckout(true)
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '20'))
            timeout(time: 30, unit: 'MINUTES')
        }
        stages {
            stage('Checkout') {
                steps {
                    script {
                        Map checkoutState = checkout scm
                        Map service = delivery.service(args.chart)
                        Map config = delivery.environments()
                        Map first = config.environments[0]

                        env.CHART = args.chart
                        env.BUILD_CONTEXT = args.context
                        env.RELEASE = service.name
                        env.IMAGE_REPOSITORY = service.repository
                        // Services the deploy job does not release are only linted.
                        env.RELEASED = config.releases.contains(service.name).toString()
                        env.ENVIRONMENT = first.name
                        env.NAMESPACE = first.namespace
                        env.CHART_REF = config.chartRegistry
                        env.COMMIT_SHA = checkoutState.GIT_COMMIT
                        // One chart version per commit, published with the image it was tested with.
                        env.CHART_VERSION = "${service.version}-sha-${checkoutState.GIT_COMMIT.take(12)}"
                        env.SOURCE_URL = checkoutState.GIT_URL

                        delivery.installScripts()
                    }
                }
            }

            // The first build has no changelog to compare, so it must run.
            stage('Service') {
                when {
                    anyOf {
                        changeset pattern: serviceChanges
                        expression { currentBuild.previousBuild == null }
                    }
                }
                stages {
                    stage('Validate') {
                        steps {
                            container('ci-tools') {
                                sh 'hadolint "$BUILD_CONTEXT/Dockerfile"'
                                script {
                                    if (env.RELEASED == 'true') {
                                        withCredentials([
                                            usernamePassword(
                                                credentialsId: 'dockerhub-creds',
                                                usernameVariable: 'REGISTRY_USERNAME',
                                                passwordVariable: 'REGISTRY_PASSWORD'
                                            )
                                        ]) {
                                            sh '.delivery/validate-release.sh'
                                        }
                                    } else {
                                        sh '''
                                          helm lint "$CHART" \
                                            --set-string image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000
                                        '''
                                    }
                                }
                            }
                        }
                    }

                    stage('Build') {
                        steps {
                            container('buildkit') {
                                sh '.delivery/build-image.sh'
                            }
                        }
                    }

                    stage('Scan') {
                        steps {
                            container('ci-tools') {
                                sh '.delivery/scan-image.sh'
                            }
                        }
                        post {
                            always {
                                archiveArtifacts(
                                    artifacts: 'sbom.json',
                                    allowEmptyArchive: true
                                )
                            }
                        }
                    }

                    stage('Publish') {
                        when { branch 'main' }
                        steps {
                            container('ci-tools') {
                                withCredentials([
                                    usernamePassword(
                                        credentialsId: 'dockerhub-creds',
                                        usernameVariable: 'REGISTRY_USERNAME',
                                        passwordVariable: 'REGISTRY_PASSWORD'
                                    )
                                ]) {
                                    sh '.delivery/publish-image.sh'
                                    withEnv(["CHART_DIR=${args.chart}"]) {
                                        sh '.delivery/publish-chart.sh'
                                    }
                                }
                            }
                            script {
                                String digest = readFile('pushed.digest').trim()
                                delivery.recordRelease(env.ENVIRONMENT, env.RELEASE, env.CHART_VERSION, digest)
                                currentBuild.description = "${env.RELEASE} ${env.CHART_VERSION} → ${env.ENVIRONMENT}"
                            }
                        }
                    }
                }
            }
        }
    }
}
