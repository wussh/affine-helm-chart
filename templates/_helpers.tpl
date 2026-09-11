{{/* Chart name and release-scoped names. */}}
{{- define "affine.name" -}}
{{ .Chart.Name }}
{{- end }}

{{- define "affine.fullname" -}}
{{ .Release.Name }}
{{- end }}

{{- define "affine.serviceAccountName" -}}
{{ default (include "affine.fullname" .) .Values.serviceAccount.name }}
{{- end }}

{{- define "affine.image" -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- end }}

{{/* Standard labels for every namespaced resource. */}}
{{- define "affine.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "affine.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels: the smallest stable set, kept identical to the 0.2.0 hardcoded
selectors. Deployment .spec.selector is immutable, so adding
app.kubernetes.io/instance here would make every 0.2.0 -> 0.2.1 upgrade fail
with "field is immutable" unless operators run a destructive `helm upgrade
--force`. Release-instance metadata still lands on the pod/resource labels
(affine.labels); it is just not part of the selector.
*/}}
{{- define "affine.selectorLabels" -}}
app.kubernetes.io/name: {{ include "affine.name" . }}
{{- end }}

{{- define "affine.redisSelectorLabels" -}}
app.kubernetes.io/name: {{ .Values.prerequisites.redis.name }}
{{- end }}

{{- define "affine.postgresSelectorLabels" -}}
app.kubernetes.io/name: {{ .Values.prerequisites.database.name }}
{{- end }}

{{- define "affine.redisLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .Values.prerequisites.redis.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: redis
{{- end }}

{{- define "affine.postgresLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .Values.prerequisites.database.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: database
{{- end }}

{{/* Workloads can only consume Secrets from their own namespace. */}}
{{- define "affine.databaseSecretName" -}}
{{- required "secrets.database.name is required when application.enabled or migration.enabled is true" .Values.secrets.database.name -}}
{{- end }}

{{- define "affine.redisSecretName" -}}
{{- required "secrets.redis.name is required when application.enabled or migration.enabled is true" .Values.secrets.redis.name -}}
{{- end }}

{{- define "affine.databaseSecretNamespace" -}}
{{ default .Release.Namespace .Values.secrets.database.namespace }}
{{- end }}

{{- define "affine.redisSecretNamespace" -}}
{{ default .Release.Namespace .Values.secrets.redis.namespace }}
{{- end }}

{{- define "affine.prerequisiteDatabaseNamespace" -}}
{{ default .Release.Namespace .Values.prerequisites.database.namespace }}
{{- end }}

{{- define "affine.databaseApplicationSecretName" -}}
{{ include "affine.databaseSecretName" . }}
{{- end }}

{{/* secrets.mode is the single switch for Secret lifecycle. */}}
{{- define "affine.databaseBootstrapSecretName" -}}
{{- if eq .Values.secrets.mode "create" -}}
{{- required "prerequisites.database.secret.name is required when secrets.mode=create" .Values.prerequisites.database.secret.name -}}
{{- else -}}
{{- required "prerequisites.database.userSecretName is required when secrets.mode=existing" .Values.prerequisites.database.userSecretName -}}
{{- end -}}
{{- end }}

{{- define "affine.databaseAdminSecretName" -}}
{{ default (include "affine.databaseBootstrapSecretName" .) .Values.databaseProvisioning.admin.secretName }}
{{- end }}

{{/*
True when the chart-managed bootstrap Job renders. This Job is the only chart
component that writes the application Secret, so it is also the only one that
gets write RBAC on it.

secrets.mode=create     -> the chart owns the Secret, so it may write it.
secrets.mode=existing   -> the Secret is external and read-only by default.
                           Writing it requires the explicit, deliberately named
                           opt-in secrets.database.allowBootstrapPatch=true,
                           which is semantically "chart may publish
                           DATABASE_URL into an external Secret", not "chart
                           owns the Secret".
*/}}
{{- define "affine.bootstrapActive" -}}
{{- $eligible := and .Values.prerequisites.enabled (ne .Values.prerequisites.database.mode "external") (or .Values.application.enabled .Values.migration.enabled) -}}
{{- $mayWrite := or (eq .Values.secrets.mode "create") .Values.secrets.database.allowBootstrapPatch -}}
{{- if and $eligible $mayWrite -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/* Claim names: chart-created (create=true) or externally managed (create=false). */}}
{{- define "affine.storageClaimName" -}}
{{- if .Values.persistence.storage.existingClaim -}}
{{- .Values.persistence.storage.existingClaim -}}
{{- else if .Values.persistence.storage.create -}}
{{- printf "%s-storage" (include "affine.fullname" .) -}}
{{- else -}}
{{- fail "persistence.storage.existingClaim is required when persistence.storage.create=false" -}}
{{- end -}}
{{- end }}

{{- define "affine.configClaimName" -}}
{{- if .Values.persistence.config.existingClaim -}}
{{- .Values.persistence.config.existingClaim -}}
{{- else if .Values.persistence.config.create -}}
{{- printf "%s-config" (include "affine.fullname" .) -}}
{{- else -}}
{{- fail "persistence.config.existingClaim is required when persistence.config.create=false" -}}
{{- end -}}
{{- end }}

{{- define "affine.redisClaimName" -}}
{{- if .Values.prerequisites.redis.persistence.existingClaim -}}
{{- .Values.prerequisites.redis.persistence.existingClaim -}}
{{- else if .Values.prerequisites.redis.persistence.create -}}
{{- .Values.prerequisites.redis.name -}}
{{- else -}}
{{- fail "prerequisites.redis.persistence.existingClaim is required when prerequisites.redis.persistence.create=false" -}}
{{- end -}}
{{- end }}

{{- define "affine.postgresClaimName" -}}
{{- if .Values.prerequisites.database.persistence.existingClaim -}}
{{- .Values.prerequisites.database.persistence.existingClaim -}}
{{- else if .Values.prerequisites.database.persistence.create -}}
{{- printf "%s-data" .Values.prerequisites.database.name -}}
{{- else -}}
{{- fail "prerequisites.database.persistence.existingClaim is required when prerequisites.database.persistence.create=false" -}}
{{- end -}}
{{- end }}

{{- define "affine.databaseProvisioningChecksum" -}}
{{- toJson (dict "image" .Values.prerequisites.database.container.image "provisioning" .Values.databaseProvisioning "adminSecret" (include "affine.databaseAdminSecretName" .) "applicationSecret" (include "affine.databaseApplicationSecretName" .)) | sha256sum | trunc 8 -}}
{{- end }}

{{- define "affine.databaseProvisioningJobName" -}}
{{ include "affine.fullname" . }}-database-provision-{{ include "affine.databaseProvisioningChecksum" . }}
{{- end }}

{{- define "affine.migrationChecksum" -}}
{{- toJson (dict "image" .Values.image.digest "migration" .Values.migration "resources" .Values.migrationResources "secretsMode" .Values.secrets.mode "databaseSecret" .Values.secrets.database.name "redisSecret" .Values.secrets.redis.name) | sha256sum | trunc 8 -}}
{{- end }}

{{- define "affine.migrationJobName" -}}
{{ include "affine.fullname" . }}-migration-{{ .Chart.AppVersion | replace "." "-" }}-{{ include "affine.migrationChecksum" . }}
{{- end }}

{{/*
Wait for required Secret keys through an optional secret volume.
The kubelet populates the mounted files from the same cache it uses to resolve
secretKeyRef environment variables, so passing this gate guarantees the main
container env references resolve without CreateContainerConfigError.
No Secret value is ever printed.
*/}}
{{- define "affine.waitForDependenciesScript" -}}
set -eu
: "${WAIT_INTERVAL_SECONDS:=5}"
: "${WAIT_TIMEOUT_SECONDS:=900}"
deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
wait_for() {
  path="$1"
  mode="$2"
  label="$3"
  while true; do
    if [ "$mode" = "nonempty" ]; then
      if [ -s "$path" ]; then
        echo "[INFO] ${label} is available" >&2
        return 0
      fi
    else
      if [ -e "$path" ]; then
        echo "[INFO] ${label} is available" >&2
        return 0
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "[ERROR] Timeout (${WAIT_TIMEOUT_SECONDS}s) waiting for ${label} at ${path}" >&2
      exit 1
    fi
    echo "[INFO] Waiting for ${label} ..." >&2
    sleep "$WAIT_INTERVAL_SECONDS"
  done
}
wait_for /run/affine-secret-wait/database/DATABASE_URL nonempty "Secret key DATABASE_URL"
wait_for /run/affine-secret-wait/redis/REDIS_SERVER_HOST exists "Secret key REDIS_SERVER_HOST"
wait_for /run/affine-secret-wait/redis/REDIS_SERVER_PORT exists "Secret key REDIS_SERVER_PORT"
wait_for /run/affine-secret-wait/redis/REDIS_SERVER_USERNAME exists "Secret key REDIS_SERVER_USERNAME"
wait_for /run/affine-secret-wait/redis/REDIS_SERVER_PASSWORD exists "Secret key REDIS_SERVER_PASSWORD"
wait_for /run/affine-secret-wait/redis/REDIS_SERVER_DATABASE exists "Secret key REDIS_SERVER_DATABASE"
echo "[INFO] All required Secret keys are available" >&2
{{- end }}

{{/*
Fail fast on invalid combinations. Called from templates/validate.yaml so it
always runs, including with default values.
*/}}
{{- define "affine.validateValues" -}}
{{- if not (has .Values.secrets.mode (list "create" "existing")) -}}
{{- fail (printf "secrets.mode=%q is invalid; must be \"create\" or \"existing\"" .Values.secrets.mode) -}}
{{- end -}}
{{- if .Values.databaseProvisioning.enabled -}}
  {{- if not (or .Values.application.enabled .Values.migration.enabled) -}}
    {{- fail "databaseProvisioning.enabled=true requires application.enabled=true or migration.enabled=true: nothing would consume the provisioned database." -}}
  {{- end -}}
  {{- if not .Values.prerequisites.enabled -}}
    {{- fail "databaseProvisioning.enabled=true requires prerequisites.enabled=true: the bootstrap Job that publishes DATABASE_URL only renders with prerequisites enabled." -}}
  {{- end -}}
  {{- if eq .Values.prerequisites.database.mode "external" -}}
    {{- fail "databaseProvisioning.enabled=true cannot be combined with prerequisites.database.mode=external. Disable databaseProvisioning and provide DATABASE_URL in the existing Secret." -}}
  {{- end -}}
  {{- if eq .Values.prerequisites.database.mode "container" -}}
    {{- fail "databaseProvisioning.enabled=true is not supported with prerequisites.database.mode=container because the built-in admin Secret has no pgbouncer host/port keys. Use databaseProvisioning.enabled=false for container mode." -}}
  {{- end -}}
  {{- /* Provisioning creates the application role/database, so DATABASE_URL can
         only exist after it runs: the chart must be allowed to publish it. In
         existing mode that write is opt-in, so the combination is invalid
         unless the operator explicitly allows the patch. */ -}}
  {{- if and (eq .Values.secrets.mode "existing") (not .Values.secrets.database.allowBootstrapPatch) -}}
    {{- fail (printf "databaseProvisioning.enabled=true with secrets.mode=existing requires secrets.database.allowBootstrapPatch=true, because the chart must publish the newly provisioned DATABASE_URL into the external Secret %s. Either set allowBootstrapPatch=true (the chart will only patch DATABASE_URL), or disable databaseProvisioning and pre-create DATABASE_URL in that Secret." .Values.secrets.database.name) -}}
  {{- end -}}
{{- end -}}
{{- if or .Values.application.enabled .Values.migration.enabled -}}
  {{- $_ := required "secrets.database.name is required when application.enabled or migration.enabled is true" .Values.secrets.database.name -}}
  {{- $_ := required "secrets.redis.name is required when application.enabled or migration.enabled is true" .Values.secrets.redis.name -}}
{{- end -}}
{{- if and .Values.prerequisites.enabled .Values.prerequisites.redis.enabled -}}
  {{- $_ := required "secrets.redis.name is required when prerequisites.redis.enabled is true" .Values.secrets.redis.name -}}
{{- end -}}
{{- if and .Values.secrets.database.namespace (ne .Values.secrets.database.namespace .Release.Namespace) -}}
  {{- fail (printf "secrets.database.namespace=%s must match the release namespace %s because Kubernetes secretKeyRef cannot reference a Secret in another namespace" .Values.secrets.database.namespace .Release.Namespace) -}}
{{- end -}}
{{- if and .Values.secrets.redis.namespace (ne .Values.secrets.redis.namespace .Release.Namespace) -}}
  {{- fail (printf "secrets.redis.namespace=%s must match the release namespace %s because Kubernetes secretKeyRef cannot reference a Secret in another namespace" .Values.secrets.redis.namespace .Release.Namespace) -}}
{{- end -}}
{{- if and .Values.prerequisites.enabled (eq .Values.prerequisites.database.mode "everest") (not .Values.prerequisites.database.name) -}}
  {{- fail "prerequisites.database.name is required when prerequisites.database.mode=everest" -}}
{{- end -}}
{{- if .Values.prerequisites.database.existing -}}
  {{- if not .Values.prerequisites.enabled -}}
    {{- fail "prerequisites.database.existing=true requires prerequisites.enabled=true: the chart still needs the database endpoint to wire DATABASE_URL." -}}
  {{- end -}}
  {{- if ne .Values.prerequisites.database.mode "everest" -}}
    {{- fail (printf "prerequisites.database.existing=true is only meaningful with prerequisites.database.mode=everest (a DatabaseCluster); mode=%s has no retained cluster to reuse." .Values.prerequisites.database.mode) -}}
  {{- end -}}
{{- end -}}
{{- range $name, $claim := dict "persistence.storage" .Values.persistence.storage "persistence.config" .Values.persistence.config -}}
  {{- if and (not $claim.create) (not $claim.existingClaim) -}}
    {{- fail (printf "%s.existingClaim is required when %s.create=false" $name $name) -}}
  {{- end -}}
{{- end -}}
{{- if and .Values.prerequisites.enabled .Values.prerequisites.redis.enabled (not .Values.prerequisites.redis.persistence.create) (not .Values.prerequisites.redis.persistence.existingClaim) -}}
  {{- fail "prerequisites.redis.persistence.existingClaim is required when prerequisites.redis.persistence.create=false" -}}
{{- end -}}
{{- if and .Values.prerequisites.enabled (eq .Values.prerequisites.database.mode "container") (not .Values.prerequisites.database.persistence.create) (not .Values.prerequisites.database.persistence.existingClaim) -}}
  {{- fail "prerequisites.database.persistence.existingClaim is required when prerequisites.database.persistence.create=false" -}}
{{- end -}}
{{- $bootstrapActive := eq (include "affine.bootstrapActive" .) "true" -}}
{{- $workloadsEnabled := or .Values.application.enabled .Values.migration.enabled -}}
{{- if eq .Values.secrets.mode "create" -}}
  {{- if and $workloadsEnabled $bootstrapActive .Values.databaseProvisioning.enabled -}}
    {{- $_ := required "secrets.database.data.POSTGRES_USERNAME is required when databaseProvisioning.enabled=true and secrets.mode=create" .Values.secrets.database.data.POSTGRES_USERNAME -}}
    {{- $_ := required "secrets.database.data.POSTGRES_PASSWORD is required when databaseProvisioning.enabled=true and secrets.mode=create" .Values.secrets.database.data.POSTGRES_PASSWORD -}}
  {{- end -}}
  {{- if and $workloadsEnabled (not $bootstrapActive) -}}
    {{- $_ := required "secrets.database.data.DATABASE_URL is required when secrets.mode=create and no chart-managed bootstrap can publish it. Enable prerequisites with an everest/container database, or provide DATABASE_URL." .Values.secrets.database.data.DATABASE_URL -}}
  {{- end -}}
  {{- if or $workloadsEnabled .Values.prerequisites.redis.enabled -}}
    {{- range $key := list "REDIS_SERVER_HOST" "REDIS_SERVER_PORT" "REDIS_SERVER_USERNAME" "REDIS_SERVER_DATABASE" -}}
      {{- $_ := required (printf "secrets.redis.data.%s is required when secrets.mode=create" $key) (index $.Values.secrets.redis.data $key) -}}
    {{- end -}}
  {{- end -}}
  {{- if and .Values.prerequisites.redis.enabled (not .Values.secrets.redis.data.REDIS_SERVER_PASSWORD) -}}
    {{- fail "secrets.redis.data.REDIS_SERVER_PASSWORD is required when prerequisites.redis.enabled=true and secrets.mode=create" -}}
  {{- end -}}
  {{- if and .Values.prerequisites.enabled (ne .Values.prerequisites.database.mode "external") -}}
    {{- $_ := required "prerequisites.database.secret.username is required when secrets.mode=create and the chart manages database prerequisites" .Values.prerequisites.database.secret.username -}}
    {{- $_ := required "prerequisites.database.secret.password is required when secrets.mode=create and the chart manages database prerequisites" .Values.prerequisites.database.secret.password -}}
  {{- end -}}
{{- end -}}
{{- if and $bootstrapActive (eq .Values.secrets.mode "existing") (not .Values.prerequisites.database.userSecretName) -}}
  {{- fail "prerequisites.database.userSecretName is required when secrets.mode=existing and the managed bootstrap reads database credentials" -}}
{{- end -}}
{{- end }}
