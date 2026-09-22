# Observability stack: kube-prometheus-stack (Prometheus Operator, Prometheus, Alertmanager,
# Grafana, node-exporter, kube-state-metrics) + Loki/Promtail for logs.

terraform {
  required_providers {
    aws        = { source = "hashicorp/aws" }
    helm       = { source = "hashicorp/helm" }
    kubernetes = { source = "hashicorp/kubernetes" }
    random     = { source = "hashicorp/random" }
  }
}

data "aws_region" "current" {}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name   = var.namespace
    labels = { "pod-security.kubernetes.io/enforce" = "privileged" } # node-exporter needs host access
  }
}

# ---------------------------------------------------------------- Grafana admin credentials
resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.cluster_name}/grafana-admin"
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({ username = "admin", password = random_password.grafana.result })
}

resource "kubernetes_secret_v1" "grafana" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  data = { "admin-user" = "admin", "admin-password" = random_password.grafana.result }
}

# ---------------------------------------------------------------- Loki (logs) – single binary, S3-less filesystem mode for simplicity
resource "helm_release" "loki" {
  count      = var.enable_loki ? 1 : 0
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode({
    deploymentMode = "SingleBinary"
    loki = {
      auth_enabled = false
      commonConfig = { replication_factor = 1 }
      storage      = { type = "filesystem" }
      schemaConfig = {
        configs = [{
          from         = "2024-01-01"
          store        = "tsdb"
          object_store = "filesystem"
          schema       = "v13"
          index        = { prefix = "index_", period = "24h" }
        }]
      }
      limits_config = { retention_period = "${var.log_retention_days * 24}h" }
      compactor     = { retention_enabled = true, delete_request_store = "filesystem" }
    }
    singleBinary = {
      replicas    = 1
      persistence = { enabled = true, size = var.loki_storage_size, storageClass = "gp3" }
      resources = {
        requests = { cpu = "200m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
    }
    backend      = { replicas = 0 }
    read         = { replicas = 0 }
    write        = { replicas = 0 }
    gateway      = { enabled = false }
    test         = { enabled = false }
    lokiCanary   = { enabled = false }
    monitoring   = { selfMonitoring = { enabled = false, grafanaAgent = { installOperator = false } } }
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
  })]
}

resource "helm_release" "promtail" {
  count      = var.enable_loki ? 1 : 0
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = var.promtail_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  wait       = true

  values = [yamlencode({
    config = { clients = [{ url = "http://loki:3100/loki/api/v1/push" }] }
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
    tolerations = [{ operator = "Exists" }] # scrape every node incl. tainted ones
  })]
  depends_on = [helm_release.loki]
}

# ---------------------------------------------------------------- kube-prometheus-stack
locals {
  grafana_datasources = var.enable_loki ? [{
    name      = "Loki"
    type      = "loki"
    url       = "http://loki:3100"
    access    = "proxy"
    isDefault = false
  }] : []

  ingress_annotations = {
    "alb.ingress.kubernetes.io/scheme"           = var.ingress_scheme
    "alb.ingress.kubernetes.io/target-type"      = "ip"
    "alb.ingress.kubernetes.io/group.name"       = "platform"
    "alb.ingress.kubernetes.io/listen-ports"     = var.acm_certificate_arn != "" ? "[{\"HTTP\":80},{\"HTTPS\":443}]" : "[{\"HTTP\":80}]"
    "alb.ingress.kubernetes.io/ssl-redirect"     = var.acm_certificate_arn != "" ? "443" : null
    "alb.ingress.kubernetes.io/certificate-arn"  = var.acm_certificate_arn != "" ? var.acm_certificate_arn : null
    "alb.ingress.kubernetes.io/healthcheck-path" = "/api/health"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name
  wait       = true
  timeout    = 900

  values = [yamlencode({
    fullnameOverride = "kps"

    # -- Prometheus --------------------------------------------------------
    prometheus = {
      prometheusSpec = {
        retention     = "${var.metrics_retention_days}d"
        retentionSize = "${var.prometheus_storage_size_gb * 0.85}GB"
        replicas      = var.prometheus_replicas
        # Pick up ServiceMonitors/PodMonitors/PrometheusRules from ALL namespaces (not just Helm-labelled ones)
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        probeSelectorNilUsesHelmValues          = false
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "gp3"
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = "${var.prometheus_storage_size_gb}Gi" } }
            }
          }
        }
        resources = {
          requests = { cpu = "500m", memory = "2Gi" }
          limits   = { memory = "4Gi" }
        }
        podAntiAffinity = "soft"
        externalLabels  = { cluster = var.cluster_name }
      }
    }

    # -- Alertmanager ------------------------------------------------------
    alertmanager = {
      alertmanagerSpec = {
        replicas = var.alertmanager_replicas
        storage = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "gp3"
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = "5Gi" } }
            }
          }
        }
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
          limits   = { memory = "256Mi" }
        }
      }
      config = {
        global = { resolve_timeout = "5m" }
        route = {
          receiver        = var.slack_webhook_url != "" ? "slack" : "null"
          group_by        = ["alertname", "namespace", "severity"]
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "4h"
          routes = [
            { receiver = "null", matchers = ["alertname = Watchdog"] },
            { receiver = var.slack_webhook_url != "" ? "slack" : "null", matchers = ["severity =~ critical|warning"] },
          ]
        }
        receivers = concat(
          [{ name = "null" }],
          var.slack_webhook_url != "" ? [{
            name = "slack"
            slack_configs = [{
              api_url       = var.slack_webhook_url
              channel       = var.slack_channel
              send_resolved = true
              title         = "[{{ .Status | toUpper }}{{ if eq .Status \"firing\" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .CommonLabels.alertname }}"
              text          = "{{ range .Alerts }}*{{ .Labels.severity | toUpper }}* {{ .Annotations.summary }}\n{{ .Annotations.description }}\n{{ end }}"
            }]
          }] : []
        )
      }
    }

    # -- Grafana -----------------------------------------------------------
    grafana = {
      enabled = true
      admin = {
        existingSecret = kubernetes_secret_v1.grafana.metadata[0].name
        userKey        = "admin-user"
        passwordKey    = "admin-password"
      }
      persistence               = { enabled = true, size = "10Gi", storageClassName = "gp3" }
      defaultDashboardsEnabled  = true
      defaultDashboardsTimezone = "utc"
      "grafana.ini" = {
        server    = { root_url = var.grafana_host != "" ? "https://${var.grafana_host}" : "%(protocol)s://%(domain)s/" }
        analytics = { check_for_updates = false, reporting_enabled = false }
        users     = { viewers_can_edit = true }
      }
      additionalDataSources = local.grafana_datasources
      sidecar = {
        dashboards  = { enabled = true, searchNamespace = "ALL", label = "grafana_dashboard" }
        datasources = { enabled = true }
      }
      ingress = {
        enabled          = var.enable_ingress
        ingressClassName = "alb"
        annotations      = { for k, v in local.ingress_annotations : k => v if v != null }
        hosts            = var.grafana_host != "" ? [var.grafana_host] : []
        path             = "/"
      }
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }

    # -- exporters ---------------------------------------------------------
    nodeExporter     = { enabled = true }
    kubeStateMetrics = { enabled = true }
    prometheus-node-exporter = {
      tolerations = [{ operator = "Exists" }]
      resources = {
        requests = { cpu = "50m", memory = "32Mi" }
        limits   = { memory = "64Mi" }
      }
    }
    kube-state-metrics = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }

    # EKS hides these control-plane components; disable their scrape targets to avoid perma-firing alerts.
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeProxy             = { enabled = false }

    prometheusOperator = {
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }
  })]

  depends_on = [kubernetes_secret_v1.grafana]
}
