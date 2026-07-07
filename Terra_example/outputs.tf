output "instance_id" {
  description = "ID of the example EC2 instance"
  value       = aws_instance.vm.id
}

output "instance_public_ip" {
  description = "Public IP address of the example EC2 instance"
  value       = aws_instance.vm.public_ip
}

output "security_group_id" {
  description = "ID of the security group attached to the example VM"
  value       = aws_security_group.vm.id
}

output "ssh_private_key" {
  description = "PEM-encoded private key for SSH access. Retrieve with: terraform output -raw ssh_private_key > vm_key.pem"
  value       = tls_private_key.vm.private_key_pem
  sensitive   = true
}

output "ssh_connection_command" {
  description = "Ready-to-use SSH command once vm_key.pem has been extracted"
  value       = "ssh -i vm_key.pem -o StrictHostKeyChecking=no ec2-user@${aws_instance.vm.public_ip}"
}
