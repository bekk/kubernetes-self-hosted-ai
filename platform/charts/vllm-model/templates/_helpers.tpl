{{- define "vllm-model.name" -}}
vllm-{{ required "key is required" .Values.key }}
{{- end -}}

{{- define "vllm-model.labels" -}}
app.kubernetes.io/name: vllm
app.kubernetes.io/instance: {{ include "vllm-model.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
ai.bekk.no/model: {{ .Values.key }}
{{- end -}}

{{- define "vllm-model.selectorLabels" -}}
app.kubernetes.io/name: vllm
app.kubernetes.io/instance: {{ include "vllm-model.name" . }}
{{- end -}}
