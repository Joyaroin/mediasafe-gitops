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

{{/* Every address but private, shared and link-local ranges: the cluster and Linode's metadata
service stay out of reach. */}}
{{- define "mediasafe.internet" -}}
ipBlock:
  cidr: 0.0.0.0/0
  except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16]
{{- end }}
