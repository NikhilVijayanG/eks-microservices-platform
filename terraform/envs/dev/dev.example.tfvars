# Copy to dev.auto.tfvars (git-ignored) and fill in.
project         = "msplatform"
region          = "us-east-1"
cluster_version = "1.30"

# Lock the API endpoint down to your office/VPN + GitHub runner egress if known
api_allowed_cidrs = ["0.0.0.0/0"]

# Roles granted cluster-admin via EKS access entries – add the bootstrap output github_actions_role_arn
admin_role_arns = [
  # "arn:aws:iam::123456789012:role/msplatform-github-actions",
]

# Optional: public Grafana with TLS
grafana_host        = ""
acm_certificate_arn = ""

# Optional: Alertmanager -> Slack (prefer passing via TF_VAR_slack_webhook_url in CI)
slack_webhook_url = ""
