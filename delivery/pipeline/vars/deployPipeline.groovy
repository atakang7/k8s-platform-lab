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

                                for (Map recorded in delivery.recordedReleases(config)) {
                                    stage("Verify ${recorded.name} in ${recorded.target.name}") {
                                        delivery.requirePromoted(recorded)
                                        if (config.releases.contains(recorded.name)) {
                                            release(recorded, '.delivery/validate-release.sh')
                                        }
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

                                for (Map recorded in delivery.recordedReleases(config)) {
                                    if (config.releases.contains(recorded.name)) {
                                        stage("Deploy ${recorded.name} to ${recorded.target.name}") {
                                            release(recorded, '.delivery/deploy.sh')
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
}

// Runs one release step (dry-run or deploy) for one recorded release: the
// chart version and image digest CI published together.
private void release(Map recorded, String step) {
    withCredentials([
        usernamePassword(
            credentialsId: 'dockerhub-creds',
            usernameVariable: 'REGISTRY_USERNAME',
            passwordVariable: 'REGISTRY_PASSWORD'
        )
    ]) {
        withEnv([
            "RELEASE=${recorded.name}",
            "CHART_VERSION=${recorded.chart}",
            "IMAGE_DIGEST=${recorded.image}",
            "NAMESPACE=${recorded.target.namespace}",
            "ENVIRONMENT=${recorded.target.name}"
        ]) {
            container('ci-tools') {
                sh(step)
            }
        }
    }
}
