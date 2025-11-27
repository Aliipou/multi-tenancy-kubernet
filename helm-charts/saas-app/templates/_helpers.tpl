{{/*
Expand the name of the chart.
*/}}
{{- define "saas-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "saas-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "saas-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "saas-app.labels" -}}
helm.sh/chart: {{ include "saas-app.chart" . }}
{{ include "saas-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/tenant: {{ .Values.tenant.id | quote }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "saas-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "saas-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Auth Service labels
*/}}
{{- define "saas-app.authService.labels" -}}
{{ include "saas-app.labels" . }}
app.kubernetes.io/component: auth-service
{{- end }}

{{/*
Auth Service selector labels
*/}}
{{- define "saas-app.authService.selectorLabels" -}}
{{ include "saas-app.selectorLabels" . }}
app.kubernetes.io/component: auth-service
{{- end }}

{{/*
Dashboard Service labels
*/}}
{{- define "saas-app.dashboardService.labels" -}}
{{ include "saas-app.labels" . }}
app.kubernetes.io/component: dashboard-service
{{- end }}

{{/*
Dashboard Service selector labels
*/}}
{{- define "saas-app.dashboardService.selectorLabels" -}}
{{ include "saas-app.selectorLabels" . }}
app.kubernetes.io/component: dashboard-service
{{- end }}

{{/*
API Service labels
*/}}
{{- define "saas-app.apiService.labels" -}}
{{ include "saas-app.labels" . }}
app.kubernetes.io/component: api-service
{{- end }}

{{/*
API Service selector labels
*/}}
{{- define "saas-app.apiService.selectorLabels" -}}
{{ include "saas-app.selectorLabels" . }}
app.kubernetes.io/component: api-service
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "saas-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "saas-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper image name for auth service
*/}}
{{- define "saas-app.authService.image" -}}
{{- $registryName := .Values.global.imageRegistry -}}
{{- $repositoryName := .Values.authService.image.repository -}}
{{- $tag := .Values.authService.image.tag | toString -}}
{{- if $registryName }}
{{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- else }}
{{- printf "%s:%s" $repositoryName $tag -}}
{{- end }}
{{- end }}

{{/*
Return the proper image name for dashboard service
*/}}
{{- define "saas-app.dashboardService.image" -}}
{{- $registryName := .Values.global.imageRegistry -}}
{{- $repositoryName := .Values.dashboardService.image.repository -}}
{{- $tag := .Values.dashboardService.image.tag | toString -}}
{{- if $registryName }}
{{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- else }}
{{- printf "%s:%s" $repositoryName $tag -}}
{{- end }}
{{- end }}

{{/*
Return the proper image name for api service
*/}}
{{- define "saas-app.apiService.image" -}}
{{- $registryName := .Values.global.imageRegistry -}}
{{- $repositoryName := .Values.apiService.image.repository -}}
{{- $tag := .Values.apiService.image.tag | toString -}}
{{- if $registryName }}
{{- printf "%s/%s:%s" $registryName $repositoryName $tag -}}
{{- else }}
{{- printf "%s:%s" $repositoryName $tag -}}
{{- end }}
{{- end }}
