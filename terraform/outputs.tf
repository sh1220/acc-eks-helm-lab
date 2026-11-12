output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "운영진 PC 에 관리자 kubeconfig 등록"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --profile ${var.aws_profile}"
}

output "public_subnet_cidrs" {
  description = "ALB 가 있는 서브넷 (NetworkPolicy 를 쓰게 되면 허용 대상)"
  value       = module.vpc.public_subnets_cidr_blocks
}
