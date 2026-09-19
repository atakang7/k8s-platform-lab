{{- /* Entry point for app charts: every manifest of the service. */}}
{{- define "service.manifests" -}}
{{- $values := mergeOverwrite (fromYaml (include "service.defaults" .)) (deepCopy .Values) -}}
{{- $ctx := dict "Values" $values "Release" .Release "Chart" .Chart "Template" .Template "Capabilities" .Capabilities -}}
{{- include "service.deployment" $ctx }}
---
{{ include "service.service" $ctx }}
{{- if $values.ingress.enabled }}
---
{{ include "service.ingress" $ctx }}
{{- end }}
{{- if $values.metrics.enabled }}
---
{{ include "service.servicemonitor" $ctx }}
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
  replicas: {{ .Values.replicas }}
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
