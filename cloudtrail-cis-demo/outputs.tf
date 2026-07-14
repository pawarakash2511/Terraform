output "sns_topic_arn" {
  value = aws_sns_topic.security.arn
}

output "cloudtrail_name" {
  value = aws_cloudtrail.main.name
}
