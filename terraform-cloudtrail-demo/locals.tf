# ---------------------------------------------------------------------------
# locals.tf
#
# WHY THIS FILE EXISTS:
# Computed/derived values that are used in more than one place. Defining
# them once here avoids repeating the same expression (e.g. account ID
# interpolation, naming prefixes) across multiple resource files, which
# would risk them drifting out of sync if changed in only one place.
# ---------------------------------------------------------------------------

locals {
  # Consistent naming prefix applied to every resource name in this project.
  # Example result: "sec-monitoring-dev"
  name_prefix = "${var.project_name}-${var.environment}"

  # Convenience references used throughout iam.tf / s3.tf / cloudtrail.tf
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Common tags merged into default_tags scope where an individual resource
  # needs additional, resource-specific tags beyond the provider defaults.
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
