locals {
  common_tags = {
    environment = var.environment
    project     = var.project_name
    owner       = var.bu
  }

  tags_critical = merge(local.common_tags, { severity_class = "critical" })
  tags_warning  = merge(local.common_tags, { severity_class = "warning" })
}
