// The deploy job, a GitHub multibranch job over the environment state. Every
// branch and pull request that changes state/ or environments.yaml is
// verified; main then releases this cluster's environment (clusterEnvironment
// in environments.yaml) to what its state/<name>.yaml says.
def call() {
    pipeline {
        agent none
        options {
            skipDefaultCheckout(true)
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '50'))
        }
        stages {
            // Runs for state changes, and again after any build that did not succeed:
            // a change is judged against the previous build only, so without the retry a
            // failed release would never be attempted again. The first build has no
            // previous build and always runs.
            stage('State') {
                when {
                    anyOf {
                        changeset 'state/**'
                        changeset 'environments.yaml'
                        expression { currentBuild.previousBuild?.result != 'SUCCESS' }
                    }
                }
                stages {
                    // An image may enter an environment only after it was in the
                    // previous one; that is checked for every environment. This
                    // cluster's releases must also carry the delivery signature and
                    // pass a server-side dry-run with its environment's values.
                    stage('Verify') {
                        agent { label 'lab-ci-light' }
                        options { timeout(time: 15, unit: 'MINUTES') }
                        steps {
                            script {
                                checkout scm
                                delivery.installScripts()
                                delivery.installSigningKey()
                                Map config = delivery.environments()
                                env.CHART_REF = config.chartRegistry
                                env.CLUSTER_ENVIRONMENT = config.clusterEnvironment

                                for (Map recorded in delivery.recordedReleases(config)) {
                                    stage("Verify ${recorded.name} in ${recorded.target.name}") {
                                        delivery.requirePromoted(recorded)
                                        if (recorded.target.name == config.clusterEnvironment && config.releases.contains(recorded.name)) {
                                            release(recorded, '.delivery/validate-release.sh')
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // This cluster's environment, from an agent Pod running as its
                    // jenkins-deploy-<name> identity (platform/environment), which
                    // can release there and nowhere else.
                    stage('Deploy') {
                        when { branch 'main' }
                        options { timeout(time: 30, unit: 'MINUTES') }
                        steps {
                            script {
                                String deployLabel = "lab-cd-runner-${env.CLUSTER_ENVIRONMENT}"
                                // Fixed environment-specific label: the same authorized Pod can
                                // stay warm and be reused by later deploys on this cluster.
                                podTemplate(
                                    inheritFrom: 'cd-runner',
                                    label: deployLabel,
                                    serviceAccount: "jenkins-deploy-${env.CLUSTER_ENVIRONMENT}",
                                    idleMinutes: 10
                                ) {
                                    node(deployLabel) {
                                        checkout scm
                                        delivery.installScripts()
                                        Map config = delivery.environments()
                                        String environment = config.clusterEnvironment
                                        env.CHART_REF = config.chartRegistry
                                        env.METRICS_URL = config.metrics ?: ''

                                        List<Map> releases = delivery.recordedReleases(config).findAll {
                                            it.target.name == environment && config.releases.contains(it.name)
                                        }
                                        for (Map recorded in releases) {
                                            stage("Deploy ${recorded.name} to ${environment}") {
                                                release(recorded, '.delivery/deploy.sh')
                                            }
                                        }
                                        // Reached only when every release above passed its tests. An
                                        // environment that runs nothing yet has nothing to tag or promote.
                                        if (releases) {
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
