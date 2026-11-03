{{/*
Base name: resource prefix and app.kubernetes.io/name.
*/}}
{{- define "app.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Name of a component resource. Input: dict "root" $ "component" <name>.
*/}}
{{- define "app.componentName" -}}
{{- printf "%s-%s" (include "app.name" .root) .component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.version" -}}
{{- .Values.image.tag | default .Chart.AppVersion | default "unknown" | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.configMapName" -}}
{{- printf "%s-config" (include "app.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "app.name" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Image reference: repo:tag, repo@digest or repo:tag@digest.
*/}}
{{- define "app.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- if .Values.image.tag -}}
{{- printf "%s:%s@%s" $repo .Values.image.tag .Values.image.digest -}}
{{- else -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- end -}}
{{- else -}}
{{- printf "%s:%s" $repo (required "image.tag (or image.digest) is required" .Values.image.tag) -}}
{{- end -}}
{{- end -}}

{{/*
"true" unless the map has enabled: false.
*/}}
{{- define "app.isEnabled" -}}
{{- if hasKey . "enabled" -}}
{{- if .enabled -}}true{{- end -}}
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
Selector labels: stable, never change after the first deploy.
Input: dict "root" $ ["component" <name>].
*/}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" .root }}
{{- with .component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
{{- end -}}

{{/*
Metadata labels for every resource. Input: dict "root" $ ["component" <name>].
*/}}
{{- define "app.labels" -}}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/version: {{ include "app.version" .root | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ include "app.chart" .root }}
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Pod template labels. Input: dict "root" $ "component" <name> ["extra" <map>].
*/}}
{{- define "app.podLabels" -}}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/version: {{ include "app.version" .root | quote }}
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- with .root.Values.podLabels }}
{{ toYaml . }}
{{- end }}
{{- with .extra }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Pod template annotations. Input: dict "root" $ ["extra" <map>].
*/}}
{{- define "app.podAnnotations" -}}
{{- if .root.Values.config }}
checksum/config: {{ include (print .root.Template.BasePath "/configmap.yaml") .root | sha256sum }}
{{- end }}
{{- with .root.Values.podAnnotations }}
{{ toYaml . }}
{{- end }}
{{- with .extra }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Service port number for a named port (first port when name is empty).
Input: dict "ports" <list> "port" <name>.
*/}}
{{- define "app.servicePort" -}}
{{- $want := .port | default "" -}}
{{- $found := "" -}}
{{- range .ports -}}
{{- if and (not $found) (or (not $want) (eq .name $want)) -}}
{{- $found = (.servicePort | default .containerPort) | toString -}}
{{- end -}}
{{- end -}}
{{- required (printf "port %q not found in workload ports" $want) $found -}}
{{- end -}}

{{/*
NetworkPolicy ports for a list of container ports.
*/}}
{{- define "app.networkPolicyPorts" -}}
{{- range . }}
- port: {{ .name }}
  protocol: {{ .protocol | default "TCP" }}
{{- end }}
{{- end -}}

{{/*
NetworkPolicy ingress rules for one workload. Input: dict "root" $ "spec" <workload>.
*/}}
{{- define "app.networkPolicyRules" -}}
{{- $np := .root.Values.networkPolicy -}}
{{- $w := .spec -}}
{{- $ing := $w.ingress | default dict -}}
{{- $route := $w.route | default dict -}}
{{- $wnp := $w.networkPolicy | default dict -}}
{{- if $w.ports }}
{{- if $np.allowSameNamespace }}
- from:
    - podSelector: {}
  ports:
    {{- include "app.networkPolicyPorts" $w.ports | trim | nindent 4 }}
{{- end }}
{{- if and (or $ing.enabled $route.enabled) $np.ingressControllerNamespaces }}
- from:
    {{- range $np.ingressControllerNamespaces }}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ . }}
    {{- end }}
  ports:
    {{- include "app.networkPolicyPorts" $w.ports | trim | nindent 4 }}
{{- end }}
{{- end }}
{{- with $np.extraIngress }}
{{ toYaml . }}
{{- end }}
{{- with $wnp.extraIngress }}
{{ toYaml . }}
{{- end }}
{{- end -}}
