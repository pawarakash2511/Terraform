aws_region  = "eu-west-2"
name_prefix = "tf-vm-example"

instance_type    = "t3.micro"
allowed_ssh_cidr = "0.0.0.0/0"

tags = {
  Project     = "terra-vm-example"
  Environment = "test"
  ManagedBy   = "terraform"
}
