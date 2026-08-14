{{- define "iscsi-longhorn.fullname" -}}
{{- .Release.Name }}-iscsi-target
{{- end -}}

{{- define "iscsi-longhorn.chapSecretName" -}}
{{- .Values.chap.existingSecret | default (printf "%s-chap" (include "iscsi-longhorn.fullname" .)) -}}
{{- end -}}
