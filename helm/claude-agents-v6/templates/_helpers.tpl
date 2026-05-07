{{/*
claude-agents/templates/_helpers.tpl
Reusable template fragments used across all agent templates.
*/}}

{{/*
Expand the chart name
*/}}
{{- define "claude-agents.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full release name
*/}}
{{- define "claude-agents.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource
*/}}
{{- define "claude-agents.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
{{- end }}

{{/*
Labels for a specific agent
Usage: include "claude-agents.agentLabels" (dict "agent" "architect" "root" .)
*/}}
{{- define "claude-agents.agentLabels" -}}
{{ include "claude-agents.labels" .root }}
app.kubernetes.io/name: {{ .agent }}-agent
app.kubernetes.io/component: agent
claude-agents/role: {{ .agent }}
{{- end }}

{{/*
Standard environment variables injected into every agent container
*/}}
{{- define "claude-agents.agentEnv" -}}
- name: ANTHROPIC_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.apiKeySecret }}
      key: ANTHROPIC_API_KEY
- name: CLAUDE_MODEL
  value: {{ .Values.global.model | quote }}
- name: MEMORY_PATH
  value: {{ .Values.memory.mountPath | quote }}
- name: AGENT_ROLE
  valueFrom:
    fieldRef:
      fieldPath: metadata.labels['claude-agents/role']
{{- end }}

{{/*
Standard volume mounts for every agent container
*/}}
{{- define "claude-agents.agentVolumeMounts" -}}
- name: agent-memory
  mountPath: {{ .Values.memory.mountPath }}
- name: agent-config
  mountPath: /etc/agent
  readOnly: true
- name: project-context
  mountPath: /memory/CLAUDE.md
  subPath: CLAUDE.md
  readOnly: true
{{- end }}

{{/*
Standard volumes for every agent pod
Usage: include "claude-agents.agentVolumes" (dict "agent" "architect" "root" .)
*/}}
{{- define "claude-agents.agentVolumes" -}}
- name: agent-memory
  persistentVolumeClaim:
    claimName: {{ include "claude-agents.fullname" .root }}-memory
- name: agent-config
  configMap:
    name: {{ include "claude-agents.fullname" .root }}-{{ .agent }}-config
- name: project-context
  configMap:
    name: {{ include "claude-agents.fullname" .root }}-project-context
{{- end }}

{{/*
Standard resource limits block
*/}}
{{- define "claude-agents.resources" -}}
resources:
  requests:
    cpu: {{ .Values.global.resources.requests.cpu }}
    memory: {{ .Values.global.resources.requests.memory }}
  limits:
    cpu: {{ .Values.global.resources.limits.cpu }}
    memory: {{ .Values.global.resources.limits.memory }}
{{- end }}

{{/*
Full image reference for agent containers.
Uses global.image.repository directly — no internal registry helper.
Usage: include "claude-agents.agentImage" (dict "name" "claude-agent" "root" .)
*/}}
{{- define "claude-agents.agentImage" -}}
{{ .root.Values.global.image.repository }}:{{ .root.Values.global.image.tag }}
{{- end }}
