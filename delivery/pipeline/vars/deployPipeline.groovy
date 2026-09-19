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
                                String previous = null

                                for (Map target in config.environments) {
                                    Map digests = delivery.digests(target.name)
                                    for (String name in digests.keySet()) {
                                        String digest = digests[name]
                                        if (digest == null) {
                                            continue
                                        }
                                        if (previous != null) {
                                            withEnv(["DIGEST=${digest}", "PREVIOUS_STATE=state/${previous}.yaml"]) {
                                                String history = sh(
                                                    returnStdout: true,
                                                    script: 'git log --format=%H -S "$DIGEST" -- "$PREVIOUS_STATE"'
                                                ).trim()
                                                if (!history) {
                                                    error("${name} ${digest} is in ${target.name} but was never in ${previous}")
                                                }
                                            }
                                        }
                                        if (config.releases.containsKey(name)) {
                                            release(config, target, name, digest, '.delivery/validate-release.sh')
                                        }
                                    }
                                    previous = target.name
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

                                for (Map target in config.environments) {
                                    Map digests = delivery.digests(target.name)
                                    for (String name in digests.keySet()) {
                                        String digest = digests[name]
                                        if (digest != null && config.releases.containsKey(name)) {
                                            release(config, target, name, digest, '.delivery/deploy.sh')
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

// Runs one release step (dry-run or deploy) for one digest in one environment,
// with the chart from the commit the image was built from.
private void release(Map config, Map target, String name, String digest, String step) {
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
