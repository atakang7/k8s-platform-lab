// GitHub multibranch jobs: main and every pull request are built, and
// GitHub Branch Source posts the commit statuses. Onboarding a service is
// one entry here plus its chart and a two-line Jenkinsfile.
def services = [
  [name: 'sample-java-app', jenkinsfile: 'app/Jenkinsfile'],
  [name: 'resource-requests-webhook', jenkinsfile: 'policies/resource-requests-webhook/Jenkinsfile'],
]
def githubOwner = 'atakang7'
def githubRepository = 'k8s-platform-lab'

def githubMultibranch = { String name, String jenkinsfile ->
  multibranchPipelineJob(name) {
    branchSources {
      branchSource {
        source {
          github {
            id(name)
            repoOwner(githubOwner)
            repository(githubRepository)
            repositoryUrl("https://github.com/${githubOwner}/${githubRepository}")
            configuredByUrl(true)
            credentialsId('github-creds')
            traits {
              gitHubBranchDiscovery { strategyId(1) }          // branches that are not pull requests
              gitHubPullRequestDiscovery { strategyId(1) }     // pull requests from this repository, merged with their target
              // Build main and pull requests only: other branches reach CI
              // through their pull request.
              headWildcardFilter {
                includes('main PR-*')
                excludes('')
              }
            }
          }
        }
      }
    }
    factory { workflowBranchProjectFactory { scriptPath(jenkinsfile) } }
    // Jenkins is not reachable from GitHub, so branches are re-indexed instead of webhooks.
    triggers { periodicFolderTrigger { interval('1m') } }
    orphanedItemStrategy { discardOldItems { numToKeep(10) } }
  }
}

services.each { service -> githubMultibranch(service.name, service.jenkinsfile) }
githubMultibranch('platform', 'delivery/Jenkinsfile.platform')

// Releases every environment to its state/<name>.yaml (environments.yaml).
githubMultibranch('deploy', 'delivery/Jenkinsfile.deploy')

// Keep exactly one agent of each execution class warm. The Kubernetes
// plugin only provisions on demand; these tiny jobs provide that demand
// and then idleMinutes keeps the resulting Pod reusable.
def warmPipeline = { String name, String scriptBody ->
  pipelineJob(name) {
    properties {
      disableConcurrentBuilds()
      pipelineTriggers {
        triggers {
          cron { spec('* * * * *') }
        }
      }
    }
    logRotator(-1, 2)
    definition {
      cps {
        script(scriptBody)
        sandbox()
      }
    }
  }
}

warmPipeline('warm-ci-runner', """
  node('lab-ci-runner') {
    echo 'lab-ci-runner warm'
  }
""")

warmPipeline('warm-ci-light', """
  node('lab-ci-light') {
    echo 'lab-ci-light warm'
  }
""")

// This cluster runs dev (environments.yaml). CD must be warmed with the
// same environment-specific ServiceAccount the real deploy uses.
warmPipeline('warm-cd-runner-dev', """
  podTemplate(
    inheritFrom: 'cd-runner',
    label: 'lab-cd-runner-dev',
    serviceAccount: 'jenkins-deploy-dev',
    idleMinutes: 10
  ) {
    node('lab-cd-runner-dev') {
      echo 'lab-cd-runner-dev warm'
    }
  }
""")
