// CI for one service in a GitHub multibranch job (release flow steps 1-3 in
// delivery/README.md). main and every pull request validate, build, test,
// and scan; a pull request must also raise the app version. main publishes the
// exact scanned image and its chart as that version and commits the release to
// the first environment's state file; the deploy job releases it from there.
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
                        Map cluster = delivery.clusterTarget(config)

                        env.CHART = args.chart
                        // The service's source identity: the last commit that changed its
                        // path. The image carries it as its revision label, and a published
                        // version is reused only for the same source (publish-image.sh).
                        container('ci-tools') {
                            env.SERVICE_REVISION = sh(returnStdout: true, script: "git log -1 --format=%H -- '${args.path}'").trim()
                        }
                        env.BUILD_CONTEXT = args.context
                        env.RELEASE = service.name
                        env.IMAGE_REPOSITORY = service.repository
                        // Services the deploy job does not release are only linted.
                        env.RELEASED = config.releases.contains(service.name).toString()
                        // Dry-runs go to this cluster's environment; new releases enter
                        // the first environment in promotion order.
                        env.ENVIRONMENT = cluster.name
                        env.NAMESPACE = cluster.namespace
                        env.RECORD_ENVIRONMENT = config.environments[0].name
                        // main publishes whenever this version is not recorded in the first
                        // environment yet. Decided from state, not from what changed, so a
                        // failed publish is picked up again by any later main build.
                        env.UNRECORDED = (delivery.releases(env.RECORD_ENVIRONMENT)[service.name]?.version != service.version).toString()
                        env.CHART_REF = config.chartRegistry
                        env.COMMIT_SHA = checkoutState.GIT_COMMIT
                        // The app version: image tag, chart version and state entry.
                        env.APP_VERSION = service.version
                        env.SOURCE_URL = checkoutState.GIT_URL

                        delivery.installScripts()
                    }
                }
            }

            // Runs for changes under `path`, after any build that did not succeed, and
            // on main whenever the app version is not recorded yet. The first build
            // always runs.
            stage('Service') {
                when {
                    anyOf {
                        changeset pattern: serviceChanges
                        expression { currentBuild.previousBuild?.result != 'SUCCESS' }
                        allOf {
                            branch 'main'
                            expression { env.UNRECORDED == 'true' }
                        }
                    }
                }
                stages {
                    stage('Validate') {
                        steps {
                            container('ci-tools') {
                                sh 'hadolint "$BUILD_CONTEXT/Dockerfile"'
                                script {
                                    if (env.CHANGE_TARGET) {
                                        delivery.requireVersionBump(args.chart, env.CHANGE_TARGET, args.path)
                                    }
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
                                    ),
                                    string(credentialsId: 'cosign-private-key', variable: 'COSIGN_PRIVATE_KEY'),
                                    string(credentialsId: 'cosign-password', variable: 'COSIGN_PASSWORD')
                                ]) {
                                    sh '.delivery/publish-image.sh'
                                    withEnv(["CHART_DIR=${args.chart}"]) {
                                        sh '.delivery/publish-chart.sh'
                                    }
                                }
                            }
                            script {
                                String digest = readFile('pushed.digest').trim()
                                delivery.recordRelease(env.RECORD_ENVIRONMENT, env.RELEASE, env.APP_VERSION, digest)
                                currentBuild.description = "${env.RELEASE} ${env.APP_VERSION} → ${env.RECORD_ENVIRONMENT}"
                            }
                        }
                    }
                }
            }
        }
    }
}
