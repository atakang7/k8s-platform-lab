// Shared steps of the platform delivery library, called as delivery.<step>().

// This repository's environment (environment.yaml at the repository root).
Map environment() {
    readYaml(file: 'environment.yaml')
}

// A service is its chart: the release is the chart name and the image
// repository is the chart's image.repository value.
Map service(String chart) {
    Map metadata = readYaml(file: "${chart}/Chart.yaml")
    Map values = readYaml(file: "${chart}/values.yaml")
    if (!(metadata.name ==~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/)) { error("${chart}: chart name must be a DNS label") }
    if (!values.image?.repository) { error("${chart}/values.yaml: image.repository is required") }
    [name: metadata.name, repository: values.image.repository]
}

// True when files under any of paths changed since base (markdown ignored).
// Without a usable base (first build, rewritten history) everything has changed.
boolean changedSince(String base, List<String> paths) {
    if (!(base ==~ /^[0-9a-f]{40}$/) || sh(script: "git cat-file -e ${base}^{commit}", returnStatus: true) != 0) {
        return true
    }
    touches(sh(script: "git diff --name-only ${base} HEAD", returnStdout: true).tokenize('\n'), paths)
}

@NonCPS
boolean touches(List<String> files, List<String> paths) {
    files.findAll { !it.endsWith('.md') }.any { file ->
        paths.any { String path -> file == path || file.startsWith(path.endsWith('/') ? path : "${path}/") }
    }
}

@NonCPS
String githubRepository(String remoteUrl) {
    def match = remoteUrl =~ /github\.com[:\/]([^\/]+\/[^\/]+?)(\.git)?$/
    match ? match[0][1] : null
}

// Writes the library's step scripts to .delivery/ in the workspace.
void installScripts() {
    for (String name in ['build-image.sh', 'scan-image.sh', 'publish-image.sh', 'validate-release.sh', 'deploy.sh',
                         'publish-chart.sh', 'github-status.sh', 'check-shell-syntax.sh', 'helm-registry-login.sh']) {
        writeFile(file: ".delivery/${name}", text: libraryResource("lab/delivery/${name}"))
    }
    sh 'chmod +x .delivery/*.sh'
}

// Commit status on env.COMMIT_SHA of env.GITHUB_REPOSITORY. Never fails the build.
void githubStatus(String state, String context, String description) {
    withEnv(["STATUS_STATE=${state}", "STATUS_CONTEXT=${context}", "STATUS_DESCRIPTION=${description}"]) {
        container('ci-tools') {
            withCredentials([usernamePassword(credentialsId: 'github-creds', usernameVariable: 'GITHUB_USER', passwordVariable: 'GITHUB_TOKEN')]) {
                sh 'sh .delivery/github-status.sh "$STATUS_STATE" "$STATUS_CONTEXT" "$STATUS_DESCRIPTION" "$COMMIT_SHA" || true'
            }
        }
    }
}

// GitHub 'error' marks an interrupted run (timeout, abort, rejected approval); 'failure' a red one.
String failureState() {
    currentBuild.currentResult == 'ABORTED' ? 'error' : 'failure'
}
