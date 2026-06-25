{{/*
===========================================================================
  ai-datacenter — Template Helpers
===========================================================================
*/}}

{{/*
Chart name, truncated to 63 chars (Kubernetes name limit).
*/}}
{{- define "ai-datacenter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully-qualified app name.
Uses the release name unless a fullnameOverride is set.
Truncated to 63 chars to comply with Kubernetes naming constraints.
*/}}
{{- define "ai-datacenter.fullname" -}}
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
Standard Kubernetes / Helm labels.
Applied to every resource this chart creates directly.
*/}}
{{- define "ai-datacenter.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "ai-datacenter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | default .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Database host.
Returns the in-cluster PostgreSQL service name when postgresql.enabled is true,
otherwise returns a placeholder indicating the external database is configured
via the Secret referenced in .Values.externalDatabase.
*/}}
{{- define "ai-datacenter.dbHost" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "%s-postgresql" .Release.Name -}}
{{- else -}}
{{- printf "external (see Secret '%s')" .Values.externalDatabase.existingSecret -}}
{{- end -}}
{{- end }}
