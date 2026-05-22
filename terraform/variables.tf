variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "westeurope"
}

variable "project_name" {
  description = "Base name used for resource naming"
  type        = string
  default     = "az-alerting-poc"
}

variable "environment" {
  description = "Environment tag (dev, staging, prod)"
  type        = string
  default     = "poc"
}

variable "teams_webhook_url" {
  description = "Microsoft Teams incoming webhook URL for alert notifications"
  type        = string
  sensitive   = true
}

variable "function_app_subnet_prefix" {
  description = "Not used in POC — placeholder for future VNet integration"
  type        = string
  default     = "10.0.1.0/24"
}
