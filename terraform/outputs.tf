output "cluster_id" {
  value = aws_rds_cluster.this.id
}

output "writer_instance_id" {
  value = aws_rds_cluster_instance.writer.identifier
}

output "writer_instance_endpoint" {
  description = "What the app uses in the 'before' state. Pinned to ONE instance."
  value       = aws_rds_cluster_instance.writer.endpoint
}

output "cluster_endpoint" {
  description = "Always points at the current writer, follows failovers. Use for writes."
  value       = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  description = "Load-balances across replicas. Use for reads."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "master_secret_arn" {
  value = aws_rds_cluster.this.master_user_secret[0].secret_arn
}