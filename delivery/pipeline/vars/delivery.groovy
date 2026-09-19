// Shared, repository-level delivery helpers. Keep validation here limited to
// configuration invariants; pipeline flow remains visible in the pipeline files.

boolean isDnsLabel(String value) {
    value && value.size() <= 63 && value ==~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/
}

boolean isRegistryHost(String value) {
    if (!value) {
        return false
    }
    value == 'localhost' ||
        value ==~ /^[a-z0-9.-]+\.[a-z0-9.-]+$/ ||
        value ==~ /^[a-z0-9.-]+:[0-9]+$/
}

boolean isImageRepository(String value) {
    if (!value) {
        return false
    }

    List<String> segments = value.tokenize('/')
    if (segments.size() < 2 || !isRegistryHost(segments[0])) {
        return false
    }

    segments.tail().every { String segment ->
        segment ==~ /^[a-z0-9]+(?:[._-][a-z0-9]+)*$/
    }
}

boolean isOciRepository(String value) {
    value?.startsWith('oci://') && isImageRepository(value.substring('oci://'.length()))
}

// The delivery environments in promotion order, the chart registry, and the
// releases the deploy job owns. Fail here when the contract is malformed so
// every consumer sees the same validated configuration.
Map environments() {
    Map config = readYaml(file: 'environments.yaml')
    List targets = config?.environments

    if (!(targets instanceof List) || targets.isEmpty()) {
        error('environments.yaml: environments must be a non-empty list')
    }
    for (Map target in targets) {
        if (!isDnsLabel(target?.name as String)) {
            error('environments.yaml: every environment name must be a DNS label of at most 63 characters')
        }
        if (!isDnsLabel(target?.namespace as String)) {
            error("environments.yaml: ${target.name} namespace must be a DNS label of at most 63 characters")
        }
    }
    if (targets*.name.unique(false).size() != targets.size()) {
        error('environments.yaml: environment names must be unique')
    }
    if (!isOciRepository(config?.chartRegistry as String)) {
        error('environments.yaml: chartRegistry must use an explicit registry host, e.g. oci://registry.example.com/team')
    }
    if (!(config?.releases instanceof Map)) {
        error('environments.yaml: releases must map state entries to chart paths')
    }

    config
}

// The digests desired in one environment, by state entry (state/<name>.yaml).
// A null digest means the service is not released there yet.
Map digests(String environment) {
    String file = "state/${environment}.yaml"
    Map state = readYaml(file: file)

    if (state?.environment != environment) {
        error("${file}: environment must be ${environment}")
    }
    if (!(state?.digests instanceof Map)) {
        error("${file}: digests must map state entries to digests")
    }
    for (String name in state.digests.keySet()) {
        String digest = state.digests[name]
        if (digest != null && !(digest ==~ /^sha256:[0-9a-f]{64}$/)) {
            error("${file}: ${name} digest must be null or sha256:<64 hex>")
        }
    }

    state.digests
}

// Every digest the state records, in promotion order: one entry per
// environment and state entry, with the environment it must have been in first
// (null for the first environment).
List<Map> recordedDigests(Map config) {
    List<Map> recorded = []
    Map previous = null

    for (Map target in config.environments) {
        Map environmentDigests = digests(target.name)
        for (String name in environmentDigests.keySet()) {
            String digest = environmentDigests[name]
            if (digest != null) {
                recorded << [target: target, previous: previous, name: name, digest: digest]
            }
        }
        previous = target
    }

    recorded
}

// A digest may enter an environment only after it was recorded in the previous
// one; the Git history of that environment's state file is the proof.
void requirePromoted(Map recorded) {
    if (recorded.previous == null) {
        return
    }

    withEnv(["DIGEST=${recorded.digest}", "PREVIOUS_STATE=state/${recorded.previous.name}.yaml"]) {
        String history = sh(
            returnStdout: true,
            script: 'git log --format=%H -S "$DIGEST" -- "$PREVIOUS_STATE"'
        ).trim()
        if (!history) {
            error("${recorded.name} ${recorded.digest} is in ${recorded.target.name} but was never in ${recorded.previous.name}")
        }
    }
}

// Commits a new digest to main's state/<environment>.yaml: that commit is the
// deploy. The push is retried because another service may record first.
void recordDigest(String environment, String name, String digest) {
    withEnv([
        "STATE_FILE=state/${environment}.yaml",
        "STATE_MESSAGE=Deploy ${name} ${digest} to ${environment}"
    ]) {
        withCredentials([gitUsernamePassword(credentialsId: 'github-creds')]) {
            retry(3) {
                sh 'git fetch --no-tags origin main && git checkout --detach FETCH_HEAD'
                Map state = readYaml(file: env.STATE_FILE)

                if (!state.digests.containsKey(name)) {
                    error("${env.STATE_FILE} has no entry for ${name}")
                }
                if (state.digests[name] == digest) {
                    echo("${name} ${digest} is already recorded for ${environment}")
                    return
                }

                state.digests[name] = digest
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

// Extracts a chart as it was at the commit an image was built from, so a
// release always pairs the image with the chart it was tested with. The commit
// must be in the checked-out history: images from unmerged commits never ship.
String chartAt(String revision, String chart) {
    withEnv(["REVISION=${revision}", "CHART=${chart}"]) {
        sh '''
          git merge-base --is-ancestor "$REVISION" HEAD || {
            echo "FAIL | commit $REVISION is not in this branch's history" >&2
            exit 1
          }
          mkdir -p ".release/$REVISION"
          git archive "$REVISION" "$CHART" | tar -x -C ".release/$REVISION"
        '''
    }

    ".release/${revision}/${chart}"
}

// A service is defined by its chart: the chart name is the Helm release and
// the state entry, and image.repository is the only image repository that release may consume.
Map service(String chart) {
    if (!chart) {
        error('service chart path is required')
    }

    Map metadata = readYaml(file: "${chart}/Chart.yaml")
    Map values = readYaml(file: "${chart}/values.yaml")
    String name = metadata?.name as String
    String repository = values?.image?.repository as String

    if (!isDnsLabel(name)) {
        error("${chart}/Chart.yaml: name must be a DNS label of at most 63 characters")
    }
    if (!isImageRepository(repository)) {
        error("${chart}/values.yaml: image.repository must use an explicit registry host, e.g. registry.example.com/team/service")
    }

    [name: name, repository: repository]
}

// Materialize the library's shell resources into the workspace. The pipeline
// invokes each resulting script explicitly; sourcing is used only for the
// side-effect-free registry login function.
void installScripts() {
    List<String> scripts = [
        'build-image.sh',
        'scan-image.sh',
        'publish-image.sh',
        'validate-release.sh',
        'deploy.sh',
        'image-revision.sh',
        'publish-chart.sh',
        'registry-login.sh'
    ]

    for (String name in scripts) {
        writeFile(
            file: ".delivery/${name}",
            text: libraryResource("lab/delivery/${name}")
        )
    }
    sh 'chmod +x .delivery/*.sh'
}
