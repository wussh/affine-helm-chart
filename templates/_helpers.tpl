{{- define "affine.name" -}}{{ .Chart.Name }}{{- end }}
{{- define "affine.fullname" -}}{{ .Release.Name }}{{- end }}
{{- define "affine.serviceAccountName" -}}{{ default (include "affine.fullname" .) .Values.serviceAccount.name }}{{- end }}
{{- define "affine.image" -}}{{ .Values.image.repository }}@{{ .Values.image.digest }}{{- end }}
{{- define "affine.databaseSecretName" -}}{{ required "secrets.database.name is required" .Values.secrets.database.name }}{{- end }}
{{- define "affine.redisSecretName" -}}{{ required "secrets.redis.name is required" .Values.secrets.redis.name }}{{- end }}
{{- define "affine.validateSecrets" -}}
{{- $_ := include "affine.databaseSecretName" . -}}
{{- $_ := include "affine.redisSecretName" . -}}
{{- if and (eq .Values.secrets.mode "create") (eq .Values.prerequisites.database.mode "external") }}
{{- range $key := list "DATABASE_URL" }}
{{- $_ := required (printf "secrets.database.data.%s is required" $key) (index $.Values.secrets.database.data $key) -}}
{{- end }}
{{- range $key := list "REDIS_SERVER_HOST" "REDIS_SERVER_PORT" "REDIS_SERVER_USERNAME" "REDIS_SERVER_PASSWORD" "REDIS_SERVER_DATABASE" }}
{{- $_ := required (printf "secrets.redis.data.%s is required" $key) (index $.Values.secrets.redis.data $key) -}}
{{- end -}}
{{- end -}}
{{- if and .Values.prerequisites.enabled (eq .Values.secrets.mode "create") (ne .Values.prerequisites.database.mode "external") -}}
{{- $_ := required "secrets.database.data.POSTGRES_USERNAME is required when creating prerequisites" .Values.secrets.database.data.POSTGRES_USERNAME -}}
{{- $_ := required "secrets.database.data.POSTGRES_PASSWORD is required when creating prerequisites" .Values.secrets.database.data.POSTGRES_PASSWORD -}}
{{- end -}}
{{- end }}
{{- define "affine.migrationChecksum" -}}
{{- toJson (dict "image" .Values.image.digest "migration" .Values.migration "resources" .Values.migrationResources "databaseSecret" .Values.secrets.database.name "redisSecret" .Values.secrets.redis.name) | sha256sum | trunc 8 -}}
{{- end }}
