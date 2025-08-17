output "api_gateway_url" {
  description = "Invoke URL for the code execution API"
  value       = aws_api_gateway_stage.prod.invoke_url
}

output "efs_id" {
  description = "ID of the EFS file system"
  value       = aws_efs_file_system.code.id
}

output "api_lambda_arn" {
  description = "ARN of the API Lambda"
  value       = aws_lambda_function.api.arn
}

output "python_lambda_arn" {
  description = "ARN of the Python execution Lambda"
  value       = aws_lambda_function.python.arn
}
