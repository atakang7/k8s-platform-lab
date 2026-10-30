// Shared, repository-level delivery helpers. Every shell step runs in the
// ci-tools container, the one image with all delivery tools (git, jq, curl, helm,
// cosign). Configuration is checked once,
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
    if (!(config.clusterEnvironment in targets*.name)) {
        error('environments.yaml: clusterEnvironment must name one of the environments')
    }
    if (!(config?.chartRegistry as String)?.startsWith('oci://')) {
        error('environments.yaml: chartRegistry must be an oci:// reference')
    }
    if (targets.any { it.canary } && !config.metrics) {
        error('environments.yaml: canary environments need metrics, the Prometheus URL')
    }
    for (Map target in targets.findAll { it.canary }) {
        if (!(target.canary.weight in 1..100) || !(target.canary.minutes > 0) || !(target.canary.maxErrorRate instanceof Number)) {
            error("environments.yaml: ${target.name} canary needs weight (1-100), minutes and maxErrorRate")
        }
    }
    if (!(config?.releases instanceof List)) {
        error('environments.yaml: releases must list the services the deploy job releases')
    }

    config
}

// The environment this cluster runs (clusterEnvironment in environments.yaml).
Map clusterTarget(Map config) {
    config.environments.find { it.name == config.clusterEnvironment }
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
        String history
        container('ci-tools') {
            history = sh(
                returnStdout: true,
                script: 'git log --format=%H -S "$IMAGE_DIGEST" -- "$PREVIOUS_STATE"'
            ).trim()
        }
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
                container('ci-tools') {
                    sh 'git fetch --no-tags origin main && git checkout --detach FETCH_HEAD'
                }
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
                container('ci-tools') {
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
}

// Tags the commit a healthy environment was released from as
// <environment>-<yyyy.MM.dd>.<n>, unless its state is unchanged since the
// environment's last tag. A tag names everything that ran together, and is
// what a rollback restores (delivery/README.md, Release flow).
void tagRelease(String environment) {
    withEnv(["ENVIRONMENT=${environment}"]) {
        withCredentials([gitUsernamePassword(credentialsId: 'github-creds')]) {
            container('ci-tools') {
                sh '''
                  git fetch --no-tags origin "+refs/tags/$ENVIRONMENT-*:refs/tags/$ENVIRONMENT-*"
                  last="$(git tag --list "$ENVIRONMENT-*" --sort=-v:refname | head -n 1)"
                  if [ -n "$last" ] && git diff --quiet "$last" HEAD -- "state/$ENVIRONMENT.yaml"; then
                    echo "PASS | $ENVIRONMENT still runs $last"
                    exit 0
                  fi
                  day="$(date -u +%Y.%m.%d)"
                  # One past the highest number, not the count: a deleted tag leaves a gap.
                  tag="$ENVIRONMENT-$day.$(git tag --list "$ENVIRONMENT-$day.*" | awk -F. '$NF > n { n = $NF } END { print n + 1 }')"
                  git -c user.name=lab-delivery -c user.email=delivery@lab.test \
                    tag --annotate --message "Release $tag" "$tag" HEAD
                  git push origin "refs/tags/$tag"
                  echo "PASS | tagged $tag"
                '''
            }
        }
    }
}

// Opens, or refreshes, the pull request that promotes each release running in
// `environment` to the next environment, where it does not run yet. Merging
// it is the promotion: review and the deploy job's checks gate it.
void openPromotions(Map config, String environment) {
    List<String> names = config.environments*.name
    int position = names.indexOf(environment)
    if (position == names.size() - 1) {
        return
    }

    String next = names[position + 1]
    Map current = releases(environment)
    Map promoted = releases(next)
    for (String name in current.keySet()) {
        if (current[name] != null && current[name] != promoted[name]) {
            openPromotion(next, name, current[name])
        }
    }
}

// One promotion pull request, on branch promote/<environment>/<service>: main's
// state/<environment>.yaml with this release. The branch is force-pushed, so
// a newer release replaces the one an open pull request proposes.
private void openPromotion(String environment, String name, Map release) {
    String worktree = ".promote/${environment}-${name}"
    withEnv([
        "BRANCH=promote/${environment}/${name}",
        "WORKTREE=${worktree}",
        "STATE_PATH=state/${environment}.yaml",
        "TITLE=Promote ${name} ${release.version} to ${environment}",
        "BODY=Deploys ${name} ${release.version} (${release.image}) to ${environment}. The deploy job verifies it on this pull request; merging deploys it."
    ]) {
        withCredentials([
            gitUsernamePassword(credentialsId: 'github-creds'),
            usernamePassword(credentialsId: 'github-creds', usernameVariable: 'GITHUB_USER', passwordVariable: 'GITHUB_TOKEN')
        ]) {
            container('ci-tools') {
                sh '''
                  git fetch --no-tags origin main
                  rm -rf "$WORKTREE"
                  git worktree add --force --detach "$WORKTREE" FETCH_HEAD
                '''
            }
            Map state = readYaml(file: "${worktree}/state/${environment}.yaml")
            state.services[name] = release
            writeYaml(file: "${worktree}/state/${environment}.yaml", data: state, overwrite: true)
            container('ci-tools') {
                sh '''
                  if git -C "$WORKTREE" diff --quiet; then
                    echo "PASS | main already promotes this release"
                  else
                    git -C "$WORKTREE" -c user.name=lab-delivery -c user.email=delivery@lab.test \
                      commit --quiet --message "$TITLE" -- "$STATE_PATH"
                    git -C "$WORKTREE" push --force origin "HEAD:refs/heads/$BRANCH"
                    repository="$(git config --get remote.origin.url | sed -E 's#^https://github.com/##; s#\\.git$##')"
                    status="$(jq -n --arg title "$TITLE" --arg head "$BRANCH" --arg body "$BODY" \
                        '{title: $title, head: $head, base: "main", body: $body}' |
                      curl --silent --show-error --output .promote/response.json --write-out '%{http_code}' \
                        --request POST \
                        --header "Authorization: Bearer $GITHUB_TOKEN" \
                        --header 'Accept: application/vnd.github+json' \
                        --data @- \
                        "https://api.github.com/repos/$repository/pulls")"
                    case "$status" in
                      201) echo "PASS | opened $(jq -r .html_url .promote/response.json)" ;;
                      422) jq -e '.errors[]?.message | select(test("already exists"))' .promote/response.json >/dev/null ||
                             { echo "FAIL | GitHub refused the pull request: $(cat .promote/response.json)" >&2; exit 1; }
                           # The branch now proposes a newer release: retitle the open
                           # pull request so reviewers approve what it really deploys.
                           # ${repository%%/*} is the repository owner.
                           number="$(curl --silent --show-error --fail \
                               --header "Authorization: Bearer $GITHUB_TOKEN" \
                               --header 'Accept: application/vnd.github+json' \
                               "https://api.github.com/repos/$repository/pulls?state=open&head=${repository%%/*}:$BRANCH" |
                             jq -er '.[0].number')"
                           jq -n --arg title "$TITLE" --arg body "$BODY" '{title: $title, body: $body}' |
                             curl --silent --show-error --fail --output /dev/null \
                               --request PATCH \
                               --header "Authorization: Bearer $GITHUB_TOKEN" \
                               --header 'Accept: application/vnd.github+json' \
                               --data @- \
                               "https://api.github.com/repos/$repository/pulls/$number"
                           echo "PASS | refreshed pull request #$number for $BRANCH" ;;
                      *) echo "FAIL | GitHub returned $status: $(cat .promote/response.json)" >&2; exit 1 ;;
                    esac
                  fi
                  git worktree remove --force "$WORKTREE"
                '''
            }
        }
    }
}

// A pull request that changes a service must raise its app version (the
// chart's version) above the target branch's. A service new to the target
// branch has nothing to compare against, and a pull request that leaves the
// service untouched (a promotion, which only edits state/) owes no bump.
void requireVersionBump(String chart, String target, String path) {
    withEnv(["CHART_YAML=${chart}/Chart.yaml", "TARGET=${target}", "SERVICE_PATH=${path}"]) {
        withCredentials([gitUsernamePassword(credentialsId: 'github-creds')]) {
            container('ci-tools') {
                sh '''
                  git fetch --no-tags origin "$TARGET"
                  if git diff --quiet FETCH_HEAD -- "$SERVICE_PATH"; then
                    echo "PASS | $SERVICE_PATH is unchanged since $TARGET"
                    exit 0
                  fi
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

// The public half of the delivery signing key, which publish-image.sh signs
// with. It ships in this library, which always loads from main, so a branch
// cannot change the key its images are verified against.
void installSigningKey() {
    String key
    try {
        key = libraryResource('lab/delivery/cosign.pub')
    } catch (Exception missing) {
        error("delivery signing key is missing: commit cosign.pub to delivery/pipeline/resources/lab/delivery/ (README.md, Load external credentials): ${missing.message}")
    }
    writeFile(file: '.delivery/cosign.pub', text: key)
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
