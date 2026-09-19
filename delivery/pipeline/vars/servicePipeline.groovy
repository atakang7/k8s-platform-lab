// CI/CD for a service: validate, build once (tests run in the Dockerfile),
// scan, publish, deploy to this repository's environment.
//   chart:   the service's Helm chart (inherits charts/service)
//   context: BuildKit context holding the Dockerfile
//   paths:   commits touching these run the pipeline
def call(Map args) {
    if (!args?.chart || !args?.context || !args?.paths) {
        error('servicePipeline: chart, context and paths are required')
    }

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
                    stage('Resolve') {
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
                                env.GITHUB_REPOSITORY = delivery.githubRepository(scmVars.GIT_URL) ?: error("not a GitHub remote: ${scmVars.GIT_URL}")
                                env.CHANGED = delivery.changedSince(scmVars.GIT_PREVIOUS_SUCCESSFUL_COMMIT, args.paths).toString()
                                delivery.installScripts()
                                delivery.githubStatus('pending', "ci/${env.RELEASE}", env.CHANGED == 'true' ? 'CI running' : 'No changes')
                            }
                        }
                    }
                    stage('Validate') {
                        when { environment name: 'CHANGED', value: 'true' }
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
                        when { environment name: 'CHANGED', value: 'true' }
                        steps {
                            container('buildkit') { sh '.delivery/build-image.sh' }
                        }
                    }
                    stage('Scan') {
                        when { environment name: 'CHANGED', value: 'true' }
                        steps {
                            container('ci-tools') { sh '.delivery/scan-image.sh' }
                        }
                        post {
                            always { archiveArtifacts artifacts: 'sbom.json', allowEmptyArchive: true }
                        }
                    }
                    stage('Publish') {
                        when { environment name: 'CHANGED', value: 'true' }
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
                post {
                    success {
                        script { delivery.githubStatus('success', "ci/${env.RELEASE}", env.CHANGED == 'true' ? "Published ${env.IMAGE_REF}" : 'No changes') }
                    }
                    unsuccessful {
                        script {
                            if (env.RELEASE) { delivery.githubStatus(delivery.failureState(), "ci/${env.RELEASE}", "CI ${currentBuild.currentResult.toLowerCase()}") }
                        }
                    }
                }
            }
            // No agent: an approval wait holds no executor or Pod.
            stage('Deploy') {
                when { environment name: 'CHANGED', value: 'true' }
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
