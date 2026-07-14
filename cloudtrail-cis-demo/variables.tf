variable "aws_region" {
  default = "ap-south-1"
}

variable "project_name" {
  default = "cis-demo"
}

variable "notification_email" {
  description = "Email address for SNS subscription"
  type        = string
}
