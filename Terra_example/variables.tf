variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-2"
}

variable "name_prefix" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "tf-vm-example"
}

variable "instance_type" {
  description = "EC2 instance type for the example VM"
  type        = string
  default     = "t3.micro"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to reach the VM on SSH/HTTP/HTTPS. Open (0.0.0.0/0) by default for a friction-free example — narrow this to your own IP for anything real."
  type        = string
  default     = "0.0.0.0/0"
}

variable "tags" {
  description = "Tags applied to all taggable resources"
  type        = map(string)
  default = {
    Project     = "terra-vm-example"
    Environment = "test"
    ManagedBy   = "terraform"
  }
}
