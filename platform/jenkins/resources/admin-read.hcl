path "secret/data/jenkins/admin" {
  capabilities = ["read"]
}

path "secret/data/ci/dockerhub" {
  capabilities = ["read"]
}

path "secret/data/ci/github" {
  capabilities = ["read"]
}

path "secret/data/ci/cosign" {
  capabilities = ["read"]
}
