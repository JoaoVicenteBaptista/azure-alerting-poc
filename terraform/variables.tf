variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "uksouth"
}

variable "project_name" {
  description = "Base name used for resource naming"
  type        = string
  default     = "az-alerting"
}

variable "environment" {
  description = "Environment tag (dev, staging, prod). Operators must override per deployment; the dev default is intentional so an unconfigured apply does not silently land in a higher environment."
  type        = string
  default     = "dev"
}

variable "teams_webhook_url" {
  description = "Microsoft Teams incoming webhook URL for alert notifications"
  type        = string
  sensitive   = true
}

variable "notification_emails" {
  description = "Email addresses to notify on alerts. Acts as out-of-band backup to the Teams webhook so a webhook outage does not silence the pipeline."
  type        = list(string)
  default     = []
}

variable "bu" {
  description = "Business unit that owns these resources. Surfaces in tags and alert context."
  type        = string
  default     = ""
}

variable "runbook_base_url" {
  description = "Base URL for runbook links embedded in alert descriptions and tags. Per-alert slugs are appended."
  type        = string
  default     = "https://runbooks.example.com/azure-alerting"
}

variable "alert_thresholds" {
  description = "Alert thresholds tunable per environment. Defaults are dev-grade — looser so active development does not generate constant noise. Tighten in uat and prod via tfvars overrides; see README for suggested values."
  type = object({
    min_request_floor           = number
    failure_rate_pct            = number
    timeout_rate_pct            = number
    dependency_failure_rate_pct = number
    p95_response_time_ms        = number
    execution_spike_threshold   = number
    active_messages_threshold   = number
    send_failure_spike_count    = number
    dlq_growth_delta            = number
  })
  default = {
    min_request_floor           = 5
    failure_rate_pct            = 10
    timeout_rate_pct            = 10
    dependency_failure_rate_pct = 10
    p95_response_time_ms        = 3000
    execution_spike_threshold   = 100
    active_messages_threshold   = 10
    send_failure_spike_count    = 5
    dlq_growth_delta            = 0
  }
}

variable "log_analytics_retention_days" {
  description = "Log Analytics workspace retention in days. Free tier covers the first 31 days; longer retention incurs per-GB charges."
  type        = number
  default     = 30
}

variable "key_vault_soft_delete_retention_days" {
  description = "Key Vault soft-delete retention in days. Must be between 7 and 90 inclusive."
  type        = number
  default     = 7

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "Key Vault soft-delete retention must be between 7 and 90 days."
  }
}

variable "service_bus_message_ttl_days" {
  description = "Service Bus queue message time-to-live in days. Messages older than this are automatically dead-lettered or dropped."
  type        = number
  default     = 7
}

