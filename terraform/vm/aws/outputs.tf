output "instance_id" {
  value = aws_instance.this.id
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "public_ip" {
  value = var.public_ip ? aws_instance.this.public_ip : ""
}

output "image_version" {
  description = "Image version the instance was built from"
  value       = aws_instance.this.tags_all["ImageVersion"]
}

output "ami_id" {
  value = local.deployed_ami
}

output "ssh" {
  value = "ssh ${var.admin_username}@${var.public_ip ? aws_instance.this.public_ip : aws_instance.this.private_ip}"
}

output "ssm" {
  description = "Shell without SSH or a public IP (AWS CLI + Session Manager plugin)"
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.this.id}"
}
