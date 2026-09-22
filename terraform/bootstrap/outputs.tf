output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_ROLE_ARN repository secret"
  value       = aws_iam_role.github_actions.arn
}
