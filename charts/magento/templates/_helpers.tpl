{{/* Common name helpers */}}
{{- define "magento.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "magento.fullname" -}}
{{- printf "%s" (include "magento.name" .) -}}
{{- end -}}

{{- define "magento.labels" -}}
app.kubernetes.io/name: {{ include "magento.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Per-component selector labels */}}
{{- define "magento.selectorLabels" -}}
app.kubernetes.io/name: {{ include "magento.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Resolve the effective StorageClass (empty string => cluster default) */}}
{{- define "magento.storageClass" -}}
{{- with .Values.global.storageClass }}
storageClassName: {{ . | quote }}
{{- end }}
{{- end -}}

{{/* Stable service DNS names used across templates */}}
{{- define "magento.mariadbHost" -}}mariadb{{- end -}}
{{- define "magento.opensearchHost" -}}opensearch{{- end -}}
{{- define "magento.redisHost" -}}redis{{- end -}}
{{- define "magento.webService" -}}magento-web{{- end -}}
