output "repository_url" {
  description = "URL репозиторію ECR"
  value       = aws_ecr_repository.repo.repository_url
}
