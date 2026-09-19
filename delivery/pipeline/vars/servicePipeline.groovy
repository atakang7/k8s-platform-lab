// CI/CD for one service in a GitHub multibranch job. Every branch and pull
// request validates, builds, tests, and scans. main additionally publishes the
// exact scanned artifact and deploys that immutable digest.
//
//   chart:   service Helm chart (inherits charts/service)
//   context: BuildKit context containing the Dockerfile
//   path:    service directory; only changes below it run service stages
def call(Map args) {
    if (!args?.chart || !args?.context || !args?.path) {
        error('servicePipeline: chart, context and path are required')
    }

    String serviceChanges = "${args.path.replaceAll('/+$', '')}/**"

    pipeline {
        agent none
        options {
            skipDefaultCheckout(true)
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '20'))
        }
        stages {
            stage('CI') {
                agent { label 'lab-ci-runner' }
                options { timeout(time: 30, unit: 'MINUTES') }
                stages {
                    stage('Checkout') {
                        steps {
                            script {
                                Map checkoutState = checkout scm
                                Map service = delivery.service(args.chart)
                                Map target = delivery.environment()

                                env.CHART = args.chart
                                env.BUILD_CONTEXT = args.context
                                env.RELEASE = service.name
                                env.IMAGE_REPOSITORY = service.repository
                                env.NAMESPACE = target.namespace
                                env.APPROVAL = target.approval.toString()
                                env.CHART_REF = target.chartRegistry
                                env.COMMIT_SHA = checkoutState.GIT_COMMIT
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
                                        withCredentials([
                                            usernamePassword(
                                                credentialsId: 'dockerhub-creds',
                                                usernameVariable: 'REGISTRY_USERNAME',
                                                passwordVariable: 'REGISTRY_PASSWORD'
                                            )
                                        ]) {
                                            sh '.delivery/validate-release.sh'
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
                                        }
                                    }
                                    script {
                                        String output = readFile('image_ref.env').trim()
                                        if (!(output ==~ /^IMAGE_REF=[a-z0-9.:\/_-]+@sha256:[0-9a-f]{64}$/)) {
                                            error('publish-image.sh returned an invalid IMAGE_REF')
                                        }
                                        env.IMAGE_REF = output.substring('IMAGE_REF='.length())
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // No agent: a manual approval wait holds no executor or Kubernetes Pod.
            stage('Deploy') {
                when {
                    allOf {
                        branch 'main'
                        expression { env.IMAGE_REF }
                    }
                }
                steps {
                    script {
                        if (env.APPROVAL == 'true') {
                            timeout(time: 24, unit: 'HOURS') {
                                input(
                                    message: "Deploy ${env.RELEASE} ${env.IMAGE_REF} to ${env.NAMESPACE}?",
                                    ok: 'Deploy'
                                )
                            }
                        }

                        build(
                            job: 'deploy',
                            wait: true,
                            parameters: [
                                string(name: 'CHART', value: env.CHART),
                                string(name: 'IMAGE_REF', value: env.IMAGE_REF),
                                string(name: 'COMMIT_SHA', value: env.COMMIT_SHA)
                            ]
                        )
                    }
                }
            }
        }
    }
}
