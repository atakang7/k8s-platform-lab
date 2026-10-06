{{- /* Entry point for app charts: every manifest of the service. */}}
{{- define "service.manifests" -}}
{{- $values := mergeOverwrite (fromYaml (include "service.defaults" .)) (deepCopy .Values) -}}
{{- $ctx := dict "Values" $values "Release" .Release "Chart" .Chart "Template" .Template "Capabilities" .Capabilities -}}
{{- include "service.deployment" $ctx }}
---
{{ include "service.service" $ctx }}
{{- if $values.podDisruptionBudget.enabled }}
---
{{ include "service.pdb" $ctx }}
{{- end }}
{{- if $values.ingress.enabled }}
---
{{ include "service.ingress" $ctx }}
{{- end }}
{{- if $values.autoscaling.enabled }}
---
{{ include "service.hpa" $ctx }}
{{- end }}
{{- if $values.metrics.enabled }}
---
{{ include "service.servicemonitor" $ctx }}
{{- end }}
{{- if $values.smokeTest.enabled }}
---
{{ include "service.smoketest" $ctx }}
{{- end }}
{{- range $key, $data := $values.configMaps }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $.Release.Name }}-{{ $key }}
  namespace: {{ $.Release.Namespace }}
  labels:
    {{- include "service.labels" $ctx | nindent 4 }}
data:
  {{- toYaml $data | nindent 2 }}
{{- end }}
{{- end }}

{{- define "service.selectorLabels" -}}
app.kubernetes.io/name: {{ .Release.Name }}
{{- end }}

{{- define "service.labels" -}}
{{ include "service.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "service.image" -}}
{{- if not .Values.image.repository }}
{{- fail "image.repository is required" }}
{{- end }}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" .Values.image.digest) }}
{{- fail (printf "image.digest must be sha256:<64 hex>, got %q" .Values.image.digest) }}
{{- end }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- end }}

{{- define "service.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "service.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicas }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "service.selectorLabels" . | nindent 6 }}
  {{- with .Values.strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  template:
    metadata:
      labels:
        {{- include "service.labels" . | nindent 8 }}
      {{- with .Values.configMaps }}
      annotations:
        checksum/config: {{ toYaml . | sha256sum }}
      {{- end }}
    spec:
      automountServiceAccountToken: {{ .Values.automountServiceAccountToken }}
      enableServiceLinks: {{ .Values.enableServiceLinks }}
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
      {{- with .Values.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.nodeAffinity }}
      affinity:
        nodeAffinity:
          {{- toYaml . | nindent 10 }}
      {{- end }}
      {{- if .Values.spreadAcrossNodes }}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              {{- include "service.selectorLabels" . | nindent 14 }}
          matchLabelKeys:
            - pod-template-hash
      {{- end }}
      {{- with .Values.volumes }}
      volumes:
        {{- tpl (toYaml .) $ | nindent 8 }}
      {{- end }}
      containers:
        - name: app
          image: {{ include "service.image" . }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.containerPort }}
          {{- range $field, $key := dict "env" "env" "securityContext" "securityContext" "resources" "resources" "volumeMounts" "volumeMounts" }}
          {{- with index $.Values $key }}
          {{ $field }}:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- end }}
          {{- range $probe, $field := dict "startup" "startupProbe" "readiness" "readinessProbe" "liveness" "livenessProbe" }}
          {{- with index $.Values.probes $probe }}
          {{ $field }}:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- end }}
        {{- with .Values.sidecars }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
{{- end }}

{{- define "service.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "service.labels" . | nindent 4 }}
spec:
  type: ClusterIP
  selector:
    {{- include "service.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
{{- end }}

{{- define "service.pdb" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "service.labels" . | nindent 4 }}
spec:
  minAvailable: {{ .Values.podDisruptionBudget.minAvailable }}
  selector:
    matchLabels:
      {{- include "service.selectorLabels" . | nindent 6 }}
{{- end }}

{{- /* Needs metrics-server: the HPA reads pod CPU from the Metrics API. */}}
{{- define "service.hpa" -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "service.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ .Release.Name }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilization }}
{{- end }}

{{- define "service.ingress" -}}
{{- if not .Values.ingress.host }}
{{- fail "ingress.host is required when ingress.enabled" }}
{{- end }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "service.labels" . | nindent 4 }}
  {{- if gt (int .Values.ingress.canaryWeight) 0 }}
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: {{ .Values.ingress.canaryWeight | quote }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  tls:
    - hosts:
        - {{ .Values.ingress.host }}
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  name: http
{{- end }}

{{- define "service.servicemonitor" -}}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "service.labels" . | nindent 4 }}
    {{- with .Values.metrics.serviceMonitorLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  selector:
    matchLabels:
      {{- include "service.selectorLabels" . | nindent 6 }}
  namespaceSelector:
    matchNames:
      - {{ .Release.Namespace }}
  endpoints:
    - port: http
      path: {{ .Values.metrics.path }}
      interval: {{ .Values.metrics.interval }}
{{- end }}

{{- /* Helm test: one real request through the Service. Delivery runs
`helm test` after every release and rolls the release back when it fails.
Its labels differ from the selector labels so the Service never routes to it. */}}
{{- define "service.smoketest" -}}
apiVersion: v1
kind: Pod
metadata:
  name: {{ .Release.Name }}-smoke-test
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/name: {{ .Release.Name }}-smoke-test
    app.kubernetes.io/managed-by: {{ .Release.Service }}
    helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
  annotations:
    helm.sh/hook: test
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  {{- with .Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: smoke-test
      image: {{ .Values.smokeTest.image }}
      args:
        - --fail
        - --silent
        - --show-error
        - --max-time
        - "10"
        - --retry
        - "3"
        - --retry-all-errors
        - http://{{ .Release.Name }}:{{ .Values.service.port }}{{ .Values.smokeTest.path }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 32Mi}
{{- end }}
