{{/*
Common labels applied to every resource in the umbrella chart.
*/}}
{{- define "omnifeed.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: omnifeed
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}
