// Deploys one immutable image of one service chart to this repository's
// environment. All build parameters are untrusted until the Resolve stage has
// validated them and checked out the exact source commit.
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
                        String chart = params.CHART ?: ''
                        String imageReference = params.IMAGE_REF ?: ''
                        String commitSha = params.COMMIT_SHA ?: ''

                        if (commitSha != commitSha.trim() || !(commitSha ==~ /^[0-9a-f]{40}$/)) {
                            error('COMMIT_SHA must be a full lowercase Git SHA without surrounding whitespace')
                        }
                        if (imageReference != imageReference.trim() ||
                            !(imageReference ==~ /^[a-z0-9.:\/_-]+@sha256:[0-9a-f]{64}$/)) {
                            error('IMAGE_REF must be repository@sha256:<64 hex> without surrounding whitespace')
                        }
                        if (chart != chart.trim() ||
                            !(chart ==~ /^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/) ||
                            chart.tokenize('/').any { it == '.' || it == '..' }) {
                            error('CHART must be a repository-relative path without dot segments')
                        }

                        checkout scm
                        env.COMMIT_SHA = commitSha
                        sh '''
                          git cat-file -e "${COMMIT_SHA}^{commit}" || {
                            echo "FAIL | commit ${COMMIT_SHA} is not available in this checkout" >&2
                            exit 1
                          }
                          git checkout --detach "${COMMIT_SHA}"
                          test "$(git rev-parse HEAD)" = "${COMMIT_SHA}"
                        '''

                        Map service = delivery.service(chart)
                        Map target = delivery.environment()
                        int separator = imageReference.lastIndexOf('@')
                        String imageRepository = imageReference.substring(0, separator)
                        String imageDigest = imageReference.substring(separator + 1)

                        if (imageRepository != service.repository) {
                            error("${imageReference} is not from ${service.name}'s repository ${service.repository}")
                        }

                        env.CHART = chart
                        env.RELEASE = service.name
                        env.NAMESPACE = target.namespace
                        env.CHART_REF = target.chartRegistry
                        env.IMAGE_REPOSITORY = imageRepository
                        env.IMAGE_DIGEST = imageDigest

                        currentBuild.description = "${service.name} → ${target.name} · ${imageDigest.take(19)}"
                        delivery.installScripts()
                    }
                }
            }

            stage('Deploy') {
                steps {
                    container('ci-tools') {
                        withCredentials([
                            usernamePassword(
                                credentialsId: 'dockerhub-creds',
                                usernameVariable: 'REGISTRY_USERNAME',
                                passwordVariable: 'REGISTRY_PASSWORD'
                            )
                        ]) {
                            sh '.delivery/deploy.sh'
                        }
                    }
                }
            }
        }
    }
}
