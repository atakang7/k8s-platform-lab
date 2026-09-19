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

// This repository represents one environment. Fail here when its contract is
// malformed so every consumer sees the same validated configuration.
Map environment() {
    Map target = readYaml(file: 'environment.yaml')

    if (!isDnsLabel(target?.name as String)) {
        error('environment.yaml: name must be a DNS label of at most 63 characters')
    }
    if (!isDnsLabel(target?.namespace as String)) {
        error('environment.yaml: namespace must be a DNS label of at most 63 characters')
    }
    if (!(target?.approval instanceof Boolean)) {
        error('environment.yaml: approval must be true or false')
    }
    if (!isOciRepository(target?.chartRegistry as String)) {
        error('environment.yaml: chartRegistry must use an explicit registry host, e.g. oci://registry.example.com/team')
    }

    target
}

// A service is defined by its chart: the chart name is the Helm release and
// image.repository is the only image repository that release may consume.
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
// side-effect-free Helm registry function.
void installScripts() {
    List<String> scripts = [
        'build-image.sh',
        'scan-image.sh',
        'publish-image.sh',
        'validate-release.sh',
        'deploy.sh',
        'publish-chart.sh',
        'helm-registry-login.sh'
    ]

    for (String name in scripts) {
        writeFile(
            file: ".delivery/${name}",
            text: libraryResource("lab/delivery/${name}")
        )
    }
    sh 'chmod +x .delivery/*.sh'
}
