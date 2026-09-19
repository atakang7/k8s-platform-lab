// Shared, repository-level delivery helpers. Configuration is checked once,
// here, where it is read; the step scripts trust what they are given. Pipeline
// flow remains visible in the pipeline files.

// The delivery environments in promotion order, the chart registry, and the
// services the deploy job releases. Fail here when the contract is malformed so
// every consumer sees the same validated configuration.
Map environments() {
    Map config = readYaml(file: 'environments.yaml')
    List targets = config?.environments

    if (!(targets instanceof List) || targets.isEmpty()) {
        error('environments.yaml: environments must be a non-empty list')
    }
    if (targets.any { !it?.name || !it?.namespace }) {
        error('environments.yaml: every environment needs a name and a namespace')
    }
    if (targets*.name.unique(false).size() != targets.size()) {
        error('environments.yaml: environment names must be unique')
    }
    if (!(config?.chartRegistry as String)?.startsWith('oci://')) {
        error('environments.yaml: chartRegistry must be an oci:// reference')
    }
    if (!(config?.releases instanceof List)) {
        error('environments.yaml: releases must list the services the deploy job releases')
    }

    config
}

// The releases desired in one environment, by service (state/<name>.yaml).
// Each is an app version (image tag and chart version) and the image digest
// CI published as it; null means the service is not released there yet.
Map releases(String environment) {
    String file = "state/${environment}.yaml"
    Map state = readYaml(file: file)

    if (state?.environment != environment) {
        error("${file}: environment must be ${environment}")
    }
    if (!(state?.services instanceof Map)) {
        error("${file}: services must map service names to releases")
    }
    for (String name in state.services.keySet()) {
        Map release = state.services[name]
        if (release != null && (!release.version || !(release.image ==~ /^sha256:[0-9a-f]{64}$/))) {
            error("${file}: ${name} must be null or {version: <app version>, image: sha256:<64 hex>}")
        }
    }

    state.services
}

// Every release the state records, in promotion order, with the environment it
// must have been in first (null for the first environment).
List<Map> recordedReleases(Map config) {
    List<Map> recorded = []
    Map previous = null

    for (Map target in config.environments) {
        Map environmentReleases = releases(target.name)
        for (String name in environmentReleases.keySet()) {
            Map release = environmentReleases[name]
            if (release != null) {
                recorded << [target: target, previous: previous, name: name, version: release.version, image: release.image]
            }
        }
        previous = target
    }

    recorded
}

// An image may enter an environment only after it was recorded in the previous
// one; the Git history of that environment's state file is the proof.
void requirePromoted(Map recorded) {
    if (recorded.previous == null) {
        return
    }

    withEnv(["IMAGE_DIGEST=${recorded.image}", "PREVIOUS_STATE=state/${recorded.previous.name}.yaml"]) {
        String history = sh(
            returnStdout: true,
            script: 'git log --format=%H -S "$IMAGE_DIGEST" -- "$PREVIOUS_STATE"'
        ).trim()
        if (!history) {
            error("${recorded.name} ${recorded.image} is in ${recorded.target.name} but was never in ${recorded.previous.name}")
        }
    }
}

// Commits a new release to main's state/<environment>.yaml: that commit is the
// deploy. The push is retried because another service may record first.
void recordRelease(String environment, String name, String version, String image) {
    withEnv([
        "STATE_FILE=state/${environment}.yaml",
        "STATE_MESSAGE=Deploy ${name} ${version} to ${environment}"
    ]) {
        withCredentials([gitUsernamePassword(credentialsId: 'github-creds')]) {
            retry(3) {
                sh 'git fetch --no-tags origin main && git checkout --detach FETCH_HEAD'
                Map state = readYaml(file: env.STATE_FILE)
                Map release = [version: version, image: image]

                if (!state.services.containsKey(name)) {
                    error("${env.STATE_FILE} has no entry for ${name}")
                }
                if (state.services[name] == release) {
                    echo("${name} ${version} is already recorded for ${environment}")
                    return
                }

                state.services[name] = release
                writeYaml(file: env.STATE_FILE, data: state, overwrite: true)
                sh '''
                  git add "$STATE_FILE"
                  git -c user.name=lab-delivery -c user.email=delivery@lab.test \
                    commit --quiet --message "$STATE_MESSAGE"
                  git push origin HEAD:main
                '''
            }
        }
    }
}

// A pull request that changes a service must raise its app version (the
// chart's version) above the target branch's. A service new to the target
// branch has nothing to compare against.
void requireVersionBump(String chart, String target) {
    withEnv(["CHART_YAML=${chart}/Chart.yaml", "TARGET=${target}"]) {
        withCredentials([gitUsernamePassword(credentialsId: 'github-creds')]) {
            sh '''
              git fetch --no-tags origin "$TARGET"
              current="$(sed -n 's/^version: *//p' "$CHART_YAML")"
              base="$(git show "FETCH_HEAD:$CHART_YAML" 2>/dev/null | sed -n 's/^version: *//p')"
              if [ -z "$base" ]; then
                echo "PASS | $CHART_YAML is new; version $current"
              elif [ "$current" != "$base" ] &&
                [ "$(printf '%s\n%s\n' "$base" "$current" | sort -V | tail -n 1)" = "$current" ]; then
                echo "PASS | version $base -> $current"
              else
                echo "FAIL | $CHART_YAML version $current must be greater than $TARGET's $base" >&2
                exit 1
              fi
            '''
        }
    }
}

// A service is defined by its chart: the chart name is the Helm release, the
// state entry and the published chart's name, and image.repository is the only
// image repository that release may consume.
Map service(String chart) {
    if (!chart) {
        error('service chart path is required')
    }

    Map metadata = readYaml(file: "${chart}/Chart.yaml")
    Map values = readYaml(file: "${chart}/values.yaml")
    String name = metadata?.name as String
    String version = metadata?.version as String
    String repository = values?.image?.repository as String

    if (!name || !version || !repository) {
        error("${chart}: Chart.yaml needs a name and version, values.yaml an image.repository")
    }

    [name: name, version: version, repository: repository]
}

// Materialize the library's shell resources into the workspace. The pipeline
// invokes each resulting script explicitly; sourcing is used only for the
// side-effect-free registry functions.
void installScripts() {
    List<String> scripts = [
        'build-image.sh',
        'scan-image.sh',
        'publish-image.sh',
        'validate-release.sh',
        'deploy.sh',
        'publish-chart.sh',
        'registry.sh'
    ]

    for (String name in scripts) {
        writeFile(
            file: ".delivery/${name}",
            text: libraryResource("lab/delivery/${name}")
        )
    }
    sh 'chmod +x .delivery/*.sh'
}
