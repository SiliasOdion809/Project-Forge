output "db_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "secret_arn" {
  value = aws_secretsmanager_secret.db.arn
}