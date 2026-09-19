// The deploy job, a GitHub multibranch job over the environment state. Every
// branch and pull request that changes state/ or environments.yaml is
// verified; main then releases every environment, in promotion order, to what
// its state/<name>.yaml says.
def call() {
    pipeline {
        agent none
        options {
            skipDefaultCheckout(true)
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '50'))
        }
        stages {
            // The first build has no changelog to compare, so it must run.
            stage('State') {
                when {
                    anyOf {
                        changeset 'state/**'
                        changeset 'environments.yaml'
                        expression { currentBuild.previousBuild == null }
                    }
                }
                stages {
                    // A digest may enter an environment only after it was in the
                    // previous one. Released services must also pass a server-side
                    // dry-run of their chart with the target environment's values.
                    stage('Verify') {
                        agent { label 'lab-ci-runner' }
                        options { timeout(time: 15, unit: 'MINUTES') }
                        steps {
                            script {
                                checkout scm
                                delivery.installScripts()
                                Map config = delivery.environments()
                                env.CHART_REF = config.chartRegistry

                                for (Map recorded in delivery.recordedDigests(config)) {
                                    delivery.requirePromoted(recorded)
                                    if (config.releases.containsKey(recorded.name)) {
                                        release(config, recorded, '.delivery/validate-release.sh')
                                    }
                                }
                            }
                        }
                    }

                    stage('Deploy') {
                        when {
                            beforeAgent true
                            branch 'main'
                        }
                        agent { label 'lab-cd-runner' }
                        options { timeout(time: 30, unit: 'MINUTES') }
                        steps {
                            script {
                                checkout scm
                                delivery.installScripts()
                                Map config = delivery.environments()
                                env.CHART_REF = config.chartRegistry

                                for (Map recorded in delivery.recordedDigests(config)) {
                                    if (config.releases.containsKey(recorded.name)) {
                                        release(config, recorded, '.delivery/deploy.sh')
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// Runs one release step (dry-run or deploy) for one recorded digest, with the
// chart from the commit the image was built from.
private void release(Map config, Map recorded, String step) {
    String name = recorded.name
    String digest = recorded.digest
    Map target = recorded.target
    Map service = delivery.service(config.releases[name])
    if (service.name != name) {
        error("environments.yaml: release ${name} points at chart ${service.name}")
    }

    withCredentials([
        usernamePassword(
            credentialsId: 'dockerhub-creds',
            usernameVariable: 'REGISTRY_USERNAME',
            passwordVariable: 'REGISTRY_PASSWORD'
        )
    ]) {
        String revision
        withEnv(["IMAGE_REPOSITORY=${service.repository}", "IMAGE_DIGEST=${digest}"]) {
            container('ci-tools') {
                revision = sh(returnStdout: true, script: '.delivery/image-revision.sh').trim()
            }
        }

        String chart = delivery.chartAt(revision, config.releases[name])
        currentBuild.description = "${name} → ${target.name} · ${digest.take(19)}"
        withEnv([
            "CHART=${chart}",
            "RELEASE=${name}",
            "NAMESPACE=${target.namespace}",
            "ENVIRONMENT=${target.name}",
            "IMAGE_DIGEST=${digest}"
        ]) {
            container('ci-tools') {
                sh(step)
            }
        }
    }
}
