terraform {
  # Root configurations pin exact versions; commit .terraform.lock.hcl alongside this file.
  required_version = "1.17.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.70.0"
    }
  }

  # State lives in this environment's account.
  backend "s3" {
    bucket       = "example-terraform-state-prd"
    key          = "cluster1/database/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  environment  = "prd"
  account_id   = "333333333333"
  region       = "us-east-1"
  cluster_name = "cluster1-prd"
}

# Authentication is OIDC only, with no static access keys. CI exchanges its GitHub OIDC token for
# a short-lived session in this environment's account (.github/workflows/terraform.yml).
# allowed_account_ids stops a run against the wrong account.
provider "aws" {
  region              = local.region
  allowed_account_ids = [local.account_id]

  default_tags {
    tags = {
      Cluster     = "cluster1"
      Environment = local.environment
      ManagedBy   = "terraform"
    }
  }
}

# VPC and private subnets from terraform-aws-networking, found by its tags.
data "aws_vpc" "this" {
  tags = { Name = local.cluster_name }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }

  tags = { "kubernetes.io/role/internal-elb" = "1" }
}

# EKS cluster from terraform-aws-compute. Its nodes and pods use the cluster security group.
data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

module "database" {
  # Consumers should pin a released tag, e.g.
  # source = "git::https://github.com/<org>/terraform-aws-database.git?ref=v1.0.0"
  source = "../../.."

  name       = "${local.cluster_name}-app"
  vpc_id     = data.aws_vpc.this.id
  subnet_ids = sort(data.aws_subnets.private.ids)

  # Plans that would destroy or replace the database fail. See README.
  protection = "strict"

  # Only the app's cluster can connect. Add your VPN or bastion range to allowed_cidr_blocks.
  allowed_security_group_ids = [data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  allowed_cidr_blocks        = ["10.255.0.0/16"]

  engine_version = "17"
  database_name  = "app"

  instance_class        = "db.m7g.large"
  multi_az              = true
  allocated_storage     = 100
  max_allocated_storage = 500

  backup_retention_days = 14

  # Read traffic goes to the replica. Backups are copied to us-west-1 for a regional outage.
  read_replicas      = { read1 = {} }
  backup_replication = { region = "us-west-1", retention_days = 14 }
}
