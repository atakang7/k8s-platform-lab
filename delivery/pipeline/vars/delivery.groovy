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

// Writes the library's step scripts to .delivery/ in the workspace.
void installScripts() {
    for (String name in ['build-image.sh', 'scan-image.sh', 'publish-image.sh', 'validate-release.sh',
                         'deploy.sh', 'publish-chart.sh', 'helm-registry-login.sh']) {
        writeFile(file: ".delivery/${name}", text: libraryResource("lab/delivery/${name}"))
    }
    sh 'chmod +x .delivery/*.sh'
}
