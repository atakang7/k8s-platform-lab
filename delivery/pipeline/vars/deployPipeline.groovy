// Deploys one published image of one service chart to this repository's
// environment. Parameters are untrusted until validated.
def call() {
    pipeline {
        agent { label 'lab-cd-runner' }
        parameters {
            string(name: 'CHART', description: 'Service chart path, e.g. app/chart')
            string(name: 'IMAGE_REF', description: 'Immutable image reference repository@sha256:...')
            string(name: 'COMMIT_SHA', description: 'Full Git commit SHA the image was built from')
        }
        options {
            skipDefaultCheckout(true)
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '50'))
            timeout(time: 15, unit: 'MINUTES')
        }
        stages {
            stage('Resolve') {
                steps {
                    script {
                        if (!(params.COMMIT_SHA ==~ /^[0-9a-f]{40}$/)) { error('COMMIT_SHA must be a full Git SHA') }
                        if (!(params.IMAGE_REF ==~ /^[a-z0-9.:\/_-]+@sha256:[0-9a-f]{64}$/)) { error('IMAGE_REF must be repository@sha256:<64 hex>') }
                        if (!(params.CHART ==~ /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/) ||
                            params.CHART.tokenize('/').any { it == '.' || it == '..' }) {
                            error('CHART must be a repository-relative path without dot segments')
                        }

                        checkout scm
                        sh 'git checkout --detach "$COMMIT_SHA"'

                        Map service = delivery.service(params.CHART)
                        Map target = delivery.environment()
                        List<String> image = params.IMAGE_REF.tokenize('@')
                        if (image[0] != service.repository) { error("${params.IMAGE_REF} is not from ${service.name}'s repository ${service.repository}") }

                        env.RELEASE = service.name
                        env.NAMESPACE = target.namespace
                        env.CHART_REF = target.chartRegistry
                        env.IMAGE_DIGEST = image[1]
                        currentBuild.description = "${service.name} → ${target.name} · ${image[1].take(19)}"
                        delivery.installScripts()
                    }
                }
            }
            stage('Deploy') {
                steps {
                    container('ci-tools') {
                        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'REGISTRY_USERNAME', passwordVariable: 'REGISTRY_PASSWORD')]) {
                            sh '.delivery/deploy.sh'
                        }
                    }
                }
            }
        }
    }
}
