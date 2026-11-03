{{/*
Container spec shared by workloads, jobs and cronjobs.
Input: dict "root" $ "name" <component> "spec" <workload|job|cronjob>.
*/}}
{{- define "app.container" -}}
{{- $root := .root -}}
{{- $s := .spec -}}
{{- $d := $root.Values.defaults -}}
- name: {{ .name }}
  image: {{ include "app.image" $root | quote }}
  imagePullPolicy: {{ $root.Values.image.pullPolicy | default "IfNotPresent" }}
  {{- with $s.command }}
  command:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $s.args }}
  args:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with (concat ($root.Values.env | default (list)) ($s.env | default (list))) }}
  env:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if or $root.Values.secretRefs $root.Values.config $s.envFrom }}
  envFrom:
    {{- range $root.Values.secretRefs }}
    - secretRef:
        name: {{ . }}
    {{- end }}
    {{- if $root.Values.config }}
    - configMapRef:
        name: {{ include "app.configMapName" $root }}
    {{- end }}
    {{- with $s.envFrom }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- with $s.ports }}
  ports:
    {{- range . }}
    - name: {{ required "every port needs a name" .name }}
      containerPort: {{ required "every port needs a containerPort" .containerPort }}
      protocol: {{ .protocol | default "TCP" }}
    {{- end }}
  {{- end }}
  {{- $probes := $s.probes | default dict }}
  {{- with $probes.startup }}
  startupProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $probes.liveness }}
  livenessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $probes.readiness }}
  readinessProbe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $s.lifecycle }}
  lifecycle:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $root.Values.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with (hasKey $s "resources" | ternary $s.resources $d.resources) }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- $mounts := concat ($root.Values.volumeMounts | default (list)) ($s.volumeMounts | default (list)) }}
  {{- if or $root.Values.tmpVolume.enabled $mounts }}
  volumeMounts:
    {{- if $root.Values.tmpVolume.enabled }}
    - name: tmp
      mountPath: /tmp
    {{- end }}
    {{- with $mounts }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
{{- end -}}

{{/*
Pod spec shared by workloads, jobs and cronjobs.
Input: dict "root" $ "name" <component> "spec" <spec> ["restartPolicy" <p>] ["topology" true].
*/}}
{{- define "app.podSpec" -}}
{{- $root := .root -}}
{{- $s := .spec -}}
{{- $d := $root.Values.defaults -}}
serviceAccountName: {{ include "app.serviceAccountName" $root }}
automountServiceAccountToken: {{ $root.Values.serviceAccount.automount }}
{{- with .restartPolicy }}
restartPolicy: {{ . }}
{{- end }}
terminationGracePeriodSeconds: {{ hasKey $s "terminationGracePeriodSeconds" | ternary $s.terminationGracePeriodSeconds $d.terminationGracePeriodSeconds }}
{{- with ($s.priorityClassName | default $root.Values.priorityClassName) }}
priorityClassName: {{ . }}
{{- end }}
{{- with $root.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $root.Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
containers:
  {{- include "app.container" . | nindent 2 }}
{{- $volumes := concat ($root.Values.volumes | default (list)) ($s.volumes | default (list)) }}
{{- if or $root.Values.tmpVolume.enabled $volumes }}
volumes:
  {{- if $root.Values.tmpVolume.enabled }}
  - name: tmp
    {{- if $root.Values.tmpVolume.sizeLimit }}
    emptyDir:
      sizeLimit: {{ $root.Values.tmpVolume.sizeLimit }}
    {{- else }}
    emptyDir: {}
    {{- end }}
  {{- end }}
  {{- with $volumes }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
{{- with ($s.nodeSelector | default $root.Values.nodeSelector) }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with ($s.tolerations | default $root.Values.tolerations) }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with ($s.affinity | default $root.Values.affinity) }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if .topology }}
{{- $tsc := hasKey $s "topologySpreadConstraints" | ternary $s.topologySpreadConstraints $d.topologySpreadConstraints }}
{{- with $tsc }}
topologySpreadConstraints:
  {{- range . }}
  - maxSkew: {{ .maxSkew | default 1 }}
    topologyKey: {{ required "topologySpreadConstraints[].topologyKey is required" .topologyKey }}
    whenUnsatisfiable: {{ .whenUnsatisfiable | default "ScheduleAnyway" }}
    labelSelector:
      matchLabels:
        {{- include "app.selectorLabels" (dict "root" $root "component" $.name) | nindent 8 }}
    # Spread each rollout revision on its own, not old + new pods together.
    matchLabelKeys:
      - pod-template-hash
  {{- end }}
{{- end }}
{{- end }}
{{- end -}}
