{{- /* Defaults; an app chart's values override any of them. */}}
{{- define "service.defaults" -}}
image:
  repository: ""   # the app's image repository
  digest: ""       # set by delivery for every release
  pullPolicy: IfNotPresent
replicas: 1
autoscaling:        # when enabled, an HPA owns the replica count and `replicas` is ignored
  enabled: false
  minReplicas: 1
  maxReplicas: 4
  targetCPUUtilization: 70   # percent of the CPU request
containerPort: 8080
probes: {}         # startup / readiness / liveness, as Kubernetes probe specs (port: http)
resources: {}
env: []
podSecurityContext:  # with securityContext, meets the restricted Pod Security standard apps namespaces enforce
  seccompProfile:
    type: RuntimeDefault
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
automountServiceAccountToken: false
enableServiceLinks: false
terminationGracePeriodSeconds: 30
strategy: {}
imagePullSecrets:
  - name: registry-pull   # provisioned per environment by platform/environment
nodeAffinity: {}
spreadAcrossNodes: true
podDisruptionBudget:
  enabled: false
  minAvailable: 1
service:
  port: 80
ingress:
  enabled: false
  className: nginx
  host: ""          # TLS uses the ingress controller's default wildcard certificate
  canaryWeight: 0   # >0 makes this Ingress an ingress-nginx canary for the host taking that % of traffic; set by delivery
metrics:
  enabled: false
  path: /metrics
  interval: 30s
  serviceMonitorLabels:
    release: observability   # label the platform Prometheus selects
smokeTest:
  enabled: true
  path: /           # one real request the service must answer with 2xx after every release
  image: curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777
configMaps: {}      # <key>: data, created as <release>-<key>; changes restart Pods
volumes: []         # rendered with tpl: "{{ .Release.Name }}" works
volumeMounts: []
sidecars: []
{{- end }}
