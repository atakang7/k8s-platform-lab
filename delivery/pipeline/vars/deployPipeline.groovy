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
                    // An image may enter an environment only after it was in the
                    // previous one. Released services must also carry the delivery
                    // signature and pass a server-side dry-run of their chart with
                    // the target environment's values.
                    stage('Verify') {
                        agent { label 'lab-ci-runner' }
                        options { timeout(time: 15, unit: 'MINUTES') }
                        steps {
                            script {
                                checkout scm
                                delivery.installScripts()
                                delivery.installSigningKey()
                                Map config = delivery.environments()
                                env.CHART_REF = config.chartRegistry
                                env.DELIVERY_ENVIRONMENTS = config.environments*.name.join(' ')

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

                    // One agent Pod per environment, in promotion order, running
                    // as that environment's jenkins-deploy-<name> identity
                    // (platform/environment): it can release there and nowhere else.
                    stage('Deploy') {
                        when { branch 'main' }
                        options { timeout(time: 30, unit: 'MINUTES') }
                        steps {
                            script {
                                for (String environment in env.DELIVERY_ENVIRONMENTS.tokenize(' ')) {
                                    podTemplate(inheritFrom: 'cd-runner', serviceAccount: "jenkins-deploy-${environment}") {
                                        node(POD_LABEL) {
                                            checkout scm
                                            delivery.installScripts()
                                            Map config = delivery.environments()
                                            env.CHART_REF = config.chartRegistry
                                            env.METRICS_URL = config.metrics ?: ''

                                            for (Map recorded in delivery.recordedReleases(config)) {
                                                if (recorded.target.name == environment && config.releases.contains(recorded.name)) {
                                                    stage("Deploy ${recorded.name} to ${environment}") {
                                                        release(recorded, '.delivery/deploy.sh')
                                                    }
                                                }
                                            }
                                            // Reached only when every release above passed its tests.
                                            delivery.tagRelease(environment)
                                            delivery.openPromotions(config, environment)
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

// Runs one release step (dry-run or deploy) for one recorded release: an app
// version and the image digest CI published as it.
private void release(Map recorded, String step) {
    Map canary = recorded.target.canary ?: [:]
    withCredentials([
        usernamePassword(
            credentialsId: 'dockerhub-creds',
            usernameVariable: 'REGISTRY_USERNAME',
            passwordVariable: 'REGISTRY_PASSWORD'
        )
    ]) {
        withEnv([
            "RELEASE=${recorded.name}",
            "APP_VERSION=${recorded.version}",
            "IMAGE_DIGEST=${recorded.image}",
            "NAMESPACE=${recorded.target.namespace}",
            "ENVIRONMENT=${recorded.target.name}",
            "CANARY_WEIGHT=${canary.weight ?: ''}",
            "CANARY_MINUTES=${canary.minutes ?: ''}",
            "CANARY_MAX_ERROR_RATE=${canary.maxErrorRate ?: ''}"
        ]) {
            container('ci-tools') {
                sh(step)
            }
        }
    }
}
