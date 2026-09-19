// CI/CD for a service, run as a GitHub multibranch job: every branch and
// pull request is validated, built, tested and scanned; main also publishes
// and deploys. GitHub commit statuses come from the GitHub Branch Source plugin.
//   chart:   the service's Helm chart (inherits charts/service)
//   context: BuildKit context holding the Dockerfile
//   path:    the service's directory; only changes under it run the pipeline
def call(Map args) {
    if (!args?.chart || !args?.context || !args?.path) {
        error('servicePipeline: chart, context and path are required')
    }
    String changes = "${args.path.replaceAll('/+$', '')}/**"

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
                                def scmVars = checkout scm
                                Map service = delivery.service(args.chart)
                                Map target = delivery.environment()
                                env.CHART = args.chart
                                env.BUILD_CONTEXT = args.context
                                env.RELEASE = service.name
                                env.IMAGE_REPOSITORY = service.repository
                                env.NAMESPACE = target.namespace
                                env.APPROVAL = target.approval.toString()
                                env.CHART_REF = target.chartRegistry
                                env.COMMIT_SHA = scmVars.GIT_COMMIT
                                env.SOURCE_URL = scmVars.GIT_URL
                                delivery.installScripts()
                            }
                        }
                    }
                    // The first build of a branch has no changelog to compare, so it always runs.
                    stage('Service') {
                        when {
                            anyOf {
                                changeset pattern: changes
                                expression { currentBuild.previousBuild == null }
                            }
                        }
                        stages {
                            stage('Validate') {
                                steps {
                                    container('ci-tools') {
                                        sh 'hadolint "$BUILD_CONTEXT/Dockerfile"'
                                        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'REGISTRY_USERNAME', passwordVariable: 'REGISTRY_PASSWORD')]) {
                                            sh '.delivery/validate-release.sh'
                                        }
                                    }
                                }
                            }
                            stage('Build') {
                                steps {
                                    container('buildkit') { sh '.delivery/build-image.sh' }
                                }
                            }
                            stage('Scan') {
                                steps {
                                    container('ci-tools') { sh '.delivery/scan-image.sh' }
                                }
                                post {
                                    always { archiveArtifacts artifacts: 'sbom.json', allowEmptyArchive: true }
                                }
                            }
                            stage('Publish') {
                                when { branch 'main' }
                                steps {
                                    container('ci-tools') {
                                        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'REGISTRY_USERNAME', passwordVariable: 'REGISTRY_PASSWORD')]) {
                                            sh '.delivery/publish-image.sh'
                                        }
                                    }
                                    script { env.IMAGE_REF = readFile('image_ref.env').trim().split('=', 2)[1] }
                                }
                            }
                        }
                    }
                }
            }
            // No agent: an approval wait holds no executor or Pod.
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
                                input(message: "Deploy ${env.RELEASE} ${env.IMAGE_REF} to ${env.NAMESPACE}?", ok: 'Deploy')
                            }
                        }
                        build(job: 'deploy', wait: true, parameters: [
                            string(name: 'CHART', value: env.CHART),
                            string(name: 'IMAGE_REF', value: env.IMAGE_REF),
                            string(name: 'COMMIT_SHA', value: env.COMMIT_SHA),
                        ])
                    }
                }
            }
        }
    }
}
