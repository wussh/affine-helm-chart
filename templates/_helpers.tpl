{{- define "affine.name" -}}{{ .Chart.Name }}{{- end }}
{{- define "affine.fullname" -}}{{ .Release.Name }}{{- end }}
{{- define "affine.serviceAccountName" -}}{{ default (include "affine.fullname" .) .Values.serviceAccount.name }}{{- end }}
{{- define "affine.image" -}}{{ .Values.image.repository }}@{{ .Values.image.digest }}{{- end }}
{{- define "affine.databaseSecretName" -}}{{ required "secrets.database.name is required" .Values.secrets.database.name }}{{- end }}
{{- define "affine.redisSecretName" -}}{{ required "secrets.redis.name is required" .Values.secrets.redis.name }}{{- end }}
{{- define "affine.validateSecrets" -}}
{{- $_ := include "affine.databaseSecretName" . -}}
{{- $_ := include "affine.redisSecretName" . -}}
{{- if eq .Values.secrets.mode "create" }}
{{- range $key := list "DATABASE_URL" }}
{{- $_ := required (printf "secrets.database.data.%s is required" $key) (index $.Values.secrets.database.data $key) -}}
{{- end }}
{{- range $key := list "REDIS_SERVER_HOST" "REDIS_SERVER_PORT" "REDIS_SERVER_USERNAME" "REDIS_SERVER_PASSWORD" "REDIS_SERVER_DATABASE" }}
{{- $_ := required (printf "secrets.redis.data.%s is required" $key) (index $.Values.secrets.redis.data $key) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.prerequisites.enabled (eq .Values.secrets.mode "create") -}}
{{- $_ := required "secrets.database.data.POSTGRES_USERNAME is required when creating prerequisites" .Values.secrets.database.data.POSTGRES_USERNAME -}}
{{- $_ := required "secrets.database.data.POSTGRES_PASSWORD is required when creating prerequisites" .Values.secrets.database.data.POSTGRES_PASSWORD -}}
{{- end -}}
{{- end }}
