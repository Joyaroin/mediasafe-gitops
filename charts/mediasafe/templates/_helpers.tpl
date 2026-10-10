{{- define "mediasafe.labels" -}}
app.kubernetes.io/part-of: mediasafe
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mediasafe.required" -}}
{{- $_ := required "environment is required" .Values.environment -}}
{{- $_ := required "hostname is required" .Values.hostname -}}
{{- $_ := required "gatewayListener is required" .Values.gatewayListener -}}
{{- $_ := required "image.tag is required (the commit SHA)" .Values.image.tag -}}
{{- end }}
