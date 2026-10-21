terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project = "aurora-ha-maintenance"
      Owner   = var.owner
    }
  }
}

# ---------------------------------------------------------------------------
# Networking: the default VPC keeps this lab cheap and short.
# In production you would use private subnets and run the app inside the VPC.
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Aurora access for the availability probe"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "MySQL from the probe host only"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# Aurora cluster
# ---------------------------------------------------------------------------
resource "aws_rds_cluster" "this" {
  cluster_identifier          = var.name
  engine                      = "aurora-mysql"
  engine_version              = var.engine_version # null = current default
  database_name               = "appdb"
  master_username             = "admin"
  manage_master_user_password = true # password lives in Secrets Manager

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  preferred_maintenance_window = var.maintenance_window
  backup_retention_period      = 1
  skip_final_snapshot          = true
  deletion_protection          = false
  apply_immediately            = true
}

# Writer. promotion_tier 0 = highest priority if Aurora ever has to choose.
resource "aws_rds_cluster_instance" "writer" {
  identifier                   = "${var.name}-writer"
  cluster_identifier           = aws_rds_cluster.this.id
  engine                       = aws_rds_cluster.this.engine
  engine_version               = aws_rds_cluster.this.engine_version
  instance_class               = var.instance_class
  availability_zone            = data.aws_availability_zones.available.names[0]
  publicly_accessible          = var.publicly_accessible
  promotion_tier               = 0
  preferred_maintenance_window = var.maintenance_window
  apply_immediately            = true
}

# THE FIX: Aurora Replicas in other AZs.
#   reader_count = 0  -> the "before" state from the scenario (single instance)
#   reader_count >= 1 -> a failover target exists, so maintenance on the
#                        writer becomes a short failover instead of an outage
resource "aws_rds_cluster_instance" "reader" {
  count = var.reader_count

  identifier                   = "${var.name}-reader-${count.index + 1}"
  cluster_identifier           = aws_rds_cluster.this.id
  engine                       = aws_rds_cluster.this.engine
  engine_version               = aws_rds_cluster.this.engine_version
  instance_class               = var.instance_class
  availability_zone            = data.aws_availability_zones.available.names[(count.index + 1) % length(data.aws_availability_zones.available.names)]
  publicly_accessible          = var.publicly_accessible
  promotion_tier               = 1
  preferred_maintenance_window = var.maintenance_window
  apply_immediately            = true
}