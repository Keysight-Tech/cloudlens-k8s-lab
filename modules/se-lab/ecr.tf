# ============================================================================
# ECR REPOSITORIES (Conditional - only if EKS enabled)
# ============================================================================

# CloudLens Sensor Repository
resource "aws_ecr_repository" "cloudlens_sensor" {
  count = var.eks_enabled ? 1 : 0

  name                 = "${var.deployment_prefix}-cloudlens-sensor"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, {
    Name        = "${var.deployment_prefix}-cloudlens-sensor"
    Description = "CloudLens sensor container image"
  })
}

resource "aws_ecr_lifecycle_policy" "cloudlens_sensor" {
  count = var.eks_enabled ? 1 : 0

  repository = aws_ecr_repository.cloudlens_sensor[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Nginx Application Repository
resource "aws_ecr_repository" "nginx_app" {
  count = var.eks_enabled ? 1 : 0

  name                 = "${var.deployment_prefix}-nginx-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, {
    Name        = "${var.deployment_prefix}-nginx-app"
    Description = "Nginx sample application"
  })
}

resource "aws_ecr_lifecycle_policy" "nginx_app" {
  count = var.eks_enabled ? 1 : 0

  repository = aws_ecr_repository.nginx_app[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Apache Application Repository
resource "aws_ecr_repository" "apache_app" {
  count = var.eks_enabled ? 1 : 0

  name                 = "${var.deployment_prefix}-apache-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.common_tags, {
    Name        = "${var.deployment_prefix}-apache-app"
    Description = "Apache sample application"
  })
}

resource "aws_ecr_lifecycle_policy" "apache_app" {
  count = var.eks_enabled ? 1 : 0

  repository = aws_ecr_repository.apache_app[0].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 5 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 5
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Custom ECR policy for EKS nodes
resource "aws_iam_policy" "eks_ecr_custom" {
  count = var.eks_enabled ? 1 : 0

  name        = "${var.deployment_prefix}-eks-ecr-custom-policy"
  description = "Custom policy for EKS nodes to access ECR repositories"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
          "ecr:ListImages"
        ]
        Resource = [
          aws_ecr_repository.cloudlens_sensor[0].arn,
          aws_ecr_repository.nginx_app[0].arn,
          aws_ecr_repository.apache_app[0].arn
        ]
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.deployment_prefix}-eks-ecr-custom-policy"
  })
}

resource "aws_iam_role_policy_attachment" "eks_ecr_custom" {
  count = var.eks_enabled ? 1 : 0

  role       = aws_iam_role.eks_node[0].name
  policy_arn = aws_iam_policy.eks_ecr_custom[0].arn
}
