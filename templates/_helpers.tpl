{{- define "affine.name" -}}{{ .Chart.Name }}{{- end }}
{{- define "affine.fullname" -}}{{ .Release.Name }}{{- end }}
{{- define "affine.serviceAccountName" -}}{{ default (include "affine.fullname" .) .Values.serviceAccount.name }}{{- end }}
{{- define "affine.image" -}}{{ .Values.image.repository }}@{{ .Values.image.digest }}{{- end }}
{{- define "affine.databaseSecretName" -}}{{ required "secrets.database.name is required" .Values.secrets.database.name }}{{- end }}
{{- define "affine.redisSecretName" -}}{{ required "secrets.redis.name is required" .Values.secrets.redis.name }}{{- end }}
{{- define "affine.databaseBootstrapSecretName" -}}{{- if .Values.prerequisites.database.secret.create -}}{{ .Values.prerequisites.database.secret.name }}{{- else -}}{{ .Values.prerequisites.database.userSecretName }}{{- end -}}{{- end }}
{{- define "affine.databaseAdminSecretName" -}}{{ default (include "affine.databaseBootstrapSecretName" .) .Values.databaseProvisioning.admin.secretName }}{{- end }}
{{- define "affine.databaseApplicationSecretName" -}}{{ include "affine.databaseSecretName" . }}{{- end }}
{{- define "affine.databaseProvisioningChecksum" -}}
{{- toJson (dict "image" .Values.prerequisites.database.container.image "provisioning" .Values.databaseProvisioning "adminSecret" (include "affine.databaseAdminSecretName" .) "applicationSecret" (include "affine.databaseApplicationSecretName" .)) | sha256sum | trunc 8 -}}
{{- end }}
{{- define "affine.databaseProvisioningJobName" -}}{{ include "affine.fullname" . }}-database-provision-{{ include "affine.databaseProvisioningChecksum" . }}{{- end }}
{{- define "affine.validateInlineSecrets" -}}
{{- if .Values.prerequisites.database.secret.create }}
{{- $_ := required "prerequisites.database.secret.username is required when creating database bootstrap Secret" .Values.prerequisites.database.secret.username -}}
{{- $_ := required "prerequisites.database.secret.password is required when creating database bootstrap Secret" .Values.prerequisites.database.secret.password -}}
{{- end }}
{{- if .Values.secrets.database.secret.create }}
{{- if or (not .Values.databaseProvisioning.enabled) (eq .Values.prerequisites.database.mode "external") }}
{{- $_ := required "secrets.database.data.DATABASE_URL is required when creating AFFiNE database Secret" .Values.secrets.database.data.DATABASE_URL -}}
{{- end }}
{{- $_ := required "secrets.database.data.POSTGRES_USERNAME is required when creating AFFiNE database Secret" .Values.secrets.database.data.POSTGRES_USERNAME -}}
{{- $_ := required "secrets.database.data.POSTGRES_PASSWORD is required when creating AFFiNE database Secret" .Values.secrets.database.data.POSTGRES_PASSWORD -}}
{{- end }}
{{- if .Values.secrets.redis.secret.create }}
{{- range $key := list "REDIS_SERVER_HOST" "REDIS_SERVER_PORT" "REDIS_SERVER_USERNAME" "REDIS_SERVER_PASSWORD" "REDIS_SERVER_DATABASE" }}
{{- $_ := required (printf "secrets.redis.data.%s is required when creating Redis Secret" $key) (index $.Values.secrets.redis.data $key) -}}
{{- end }}
{{- end }}
{{- end }}
{{- define "affine.validateSecrets" -}}
{{- $_ := include "affine.databaseSecretName" . -}}
{{- $_ := include "affine.redisSecretName" . -}}
{{- end }}
{{- define "affine.migrationChecksum" -}}
{{- toJson (dict "image" .Values.image.digest "migration" .Values.migration "resources" .Values.migrationResources "databaseSecret" .Values.secrets.database.name "redisSecret" .Values.secrets.redis.name) | sha256sum | trunc 8 -}}
{{- end }}
