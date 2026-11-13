{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "apisix.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "apisix.fullname" -}}
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
{{- define "apisix.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "apisix.labels" -}}
helm.sh/chart: {{ include "apisix.chart" . }}
{{ include "apisix.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "apisix.selectorLabels" -}}
{{- if .Values.service.labelsOverride }}
{{- tpl (.Values.service.labelsOverride | toYaml) . }}
{{- else }}
app.kubernetes.io/name: {{ include "apisix.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "apisix.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "apisix.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Renders a value that contains template.
Usage:
{{ include "apisix.tplvalues.render" ( dict "value" .Values.path.to.the.Value "context" $) }}
*/}}
{{- define "apisix.tplvalues.render" -}}
    {{- if typeIs "string" .value }}
        {{- tpl .value .context }}
    {{- else }}
        {{- tpl (.value | toYaml) .context }}
    {{- end }}
{{- end -}}

{{- define "apisix.basePluginAttrs" -}}
{{- if .Values.apisix.prometheus.enabled }}
prometheus:
  export_addr:
    ip: 0.0.0.0
    port: {{ .Values.apisix.prometheus.containerPort }}
  export_uri: {{ .Values.apisix.prometheus.path }}
  metric_prefix: {{ .Values.apisix.prometheus.metricPrefix }}
{{- end }}
{{- if .Values.apisix.customPlugins.enabled }}
{{- range $plugin := .Values.apisix.customPlugins.plugins }}
{{- if $plugin.attrs }}
{{ $plugin.name }}: {{- $plugin.attrs | toYaml | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "apisix.pluginAttrs" -}}
{{- merge .Values.apisix.pluginAttrs (include "apisix.basePluginAttrs" . | fromYaml) | toYaml -}}
{{- end -}}

{{/*
Scheme to use while connecting etcd
*/}}
{{- define "apisix.etcd.auth.scheme" -}}
{{- if .Values.etcd.auth.tls.enabled }}
{{- "https" }}
{{- else }}
{{- "http" }}
{{- end }}
{{- end }}

{{/*
Return true when etcd client certificates are configured, otherwise an empty string.
Validate the credentials used by the generated APISIX configuration.
*/}}
{{- define "apisix.etcd.tls.clientCertEnabled" -}}
{{- $tls := .Values.etcd.auth.tls -}}
{{- if and $tls.enabled (or $tls.certFilename $tls.certKeyFilename) -}}
{{- if not (and $tls.certFilename $tls.certKeyFilename) -}}
{{- fail "etcd.auth.tls.certFilename and etcd.auth.tls.certKeyFilename must be set together" -}}
{{- end -}}
{{- if not $tls.existingSecret -}}
{{- fail "etcd.auth.tls.existingSecret is required when configuring etcd client certificates" -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{/*
Return the name of etcd password secret
*/}}
{{- define "apisix.etcd.secretName" -}}
{{- if and .Values.etcd.enabled .Values.etcd.auth.rbac.create }}
{{- template "common.names.fullname" .Subcharts.etcd }}
{{- else if .Values.externalEtcd.existingSecret }}
{{- print .Values.externalEtcd.existingSecret }}
{{- else if .Values.externalEtcd.user }}
{{- printf "etcd-%s" (include "apisix.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end -}}

{{/*
Return the password key name of etcd secret
*/}}
{{- define "apisix.etcd.secretPasswordKey" -}}
{{- if .Values.etcd.enabled }}
{{- print "etcd-root-password" }}
{{- else }}
{{- print .Values.externalEtcd.secretPasswordKey }}
{{- end }}
{{- end -}}

{{/*
Key to use to fetch admin token from secret
*/}}
{{- define "apisix.admin.credentials.secretAdminKey" -}}
{{- if .Values.apisix.admin.credentials.secretAdminKey }}
{{- .Values.apisix.admin.credentials.secretAdminKey }}
{{- else }}
{{- "admin" }}
{{- end }}
{{- end }}

{{/*
Key to use to fetch viewer token from secret
*/}}
{{- define "apisix.admin.credentials.secretViewerKey" -}}
{{- if .Values.apisix.admin.credentials.secretViewerKey }}
{{- .Values.apisix.admin.credentials.secretViewerKey }}
{{- else }}
{{- "viewer" }}
{{- end }}
{{- end }}

{{/*
The deployment role APISIX runs with. mode "standalone" is file-driven
standalone: rules come from the mounted apisix.yaml, which APISIX reads as a
data plane with the yaml config provider. With the default traditional role on
the etcd provider that combination could never start (no etcd is configured in
standalone mode), so it is rendered as a data plane. A traditional role on the
yaml provider (API-driven standalone) is kept as configured; a control plane
needs etcd and cannot run standalone.
*/}}
{{- define "apisix.deployment.role" -}}
{{- $role := .Values.apisix.deployment.role -}}
{{- if eq .Values.apisix.deployment.mode "standalone" -}}
{{- if eq $role "control_plane" -}}
{{- fail "apisix.deployment.mode \"standalone\" cannot run with apisix.deployment.role \"control_plane\": a control plane needs etcd" -}}
{{- end -}}
{{- if and (eq $role "traditional") (ne (default "etcd" .Values.apisix.deployment.role_traditional.config_provider) "yaml") -}}
{{- $role = "data_plane" -}}
{{- end -}}
{{- end -}}
{{- $role -}}
{{- end -}}

{{/*
The config provider APISIX runs with, following the config_provider values
that configmap.yaml renders for each role.
*/}}
{{- define "apisix.deployment.configProvider" -}}
{{- $role := include "apisix.deployment.role" . -}}
{{- if eq $role "traditional" -}}
{{- default "etcd" .Values.apisix.deployment.role_traditional.config_provider -}}
{{- else if eq $role "data_plane" -}}
{{- eq .Values.apisix.deployment.mode "standalone" | ternary "yaml" "etcd" -}}
{{- else -}}
{{- "etcd" -}}
{{- end -}}
{{- end -}}

{{/*
The keys of the keyring that APISIX uses when none is configured. They are
published in the APISIX source code, so data encrypted with them is not
protected.
*/}}
{{- define "apisix.dataEncryption.publicKeys" -}}
{{- list "qeddd145sfvddff3" "edd1c9f0985e76a2" | toJson -}}
{{- end -}}

{{/*
Fail on apisix.dataEncryption values that cannot work. APISIX encrypts with the
first key of the keyring, so that key must not be a public one. The public keys
may follow it, so that data encrypted with them can still be decrypted.
*/}}
{{- define "apisix.dataEncryption.validate" -}}
{{- $encryption := .Values.apisix.dataEncryption -}}
{{- if and $encryption.secretName $encryption.keyring -}}
{{- fail "apisix.dataEncryption: set either keyring or secretName, not both" -}}
{{- end -}}
{{- if and $encryption.secretName (not $encryption.secretKeys) -}}
{{- fail "apisix.dataEncryption.secretKeys must list the keys of the Secret that hold the keyring" -}}
{{- end -}}
{{- if and $encryption.keyring .Values.apisix.fullCustomConfig.enabled -}}
{{- fail "apisix.dataEncryption.keyring is not used with apisix.fullCustomConfig: set data_encryption in apisix.fullCustomConfig.config, or use secretName and refer to the APISIX_DATA_ENCRYPTION_KEY_<n> variables there" -}}
{{- end -}}
{{- if and $encryption.keyring (not (kindIs "slice" $encryption.keyring)) -}}
{{- fail "apisix.dataEncryption.keyring must be a list of keys" -}}
{{- end -}}
{{- range $index, $key := $encryption.keyring -}}
{{- if not (kindIs "string" $key) -}}
{{- fail (printf "apisix.dataEncryption.keyring: entry %d is not a string. Quote it, so that YAML keeps the key exactly as written" (add1 $index)) -}}
{{- end -}}
{{- if not (has (len $key) (list 16 32)) -}}
{{- fail (printf "apisix.dataEncryption.keyring: entry %d is %d bytes long; APISIX accepts keys of 16 or 32 bytes" (add1 $index) (len $key)) -}}
{{- end -}}
{{- end -}}
{{- if and $encryption.keyring (has (first $encryption.keyring) (include "apisix.dataEncryption.publicKeys" . | fromJsonArray)) -}}
{{- fail "apisix.dataEncryption.keyring: the first key, which APISIX encrypts with, is one of the built-in keys of APISIX. They are public and do not protect the data. Put a new key first; you can keep the built-in keys after it to decrypt the data stored so far" -}}
{{- end -}}
{{- end -}}
