locals {
  name       = "experiment"
  aws_region = "us-east-1"
}

# Provider
provider "aws" {
  region = local.aws_region
}

# Network
module "network" {
  source = "./modules/aws-network"

  name                 = local.name
  enable_dns_support   = true
  enable_dns_hostnames = true

  cidr_block = "10.10.0.0/16"

  public_subnets = {
    "us-east-1a" = { cidr = "10.10.1.0/24", map_public_ip_on_launch = true },
    "us-east-1b" = { cidr = "10.10.2.0/24", map_public_ip_on_launch = true }
  }

  private_subnets = {
    "us-east-1a" = { cidr = "10.10.10.0/24" },
    "us-east-1b" = { cidr = "10.10.20.0/24" }
  }
}

# Bastion host
module "bastion" {
  source = "./modules/aws-instance"

  name = local.name
  instances = {
    "bastion" = {
      vpc_id        = module.network.vpc.id,
      subnet_id     = module.network.public_subnets["us-east-1a"].id,
      instance_type = "t2.micro"
      ami           = "ami-06ca3ca175f37dd66",
      ingress = [
        { protocol = "tcp", from_port = 22, to_port = 22, cidr_blocks = ["0.0.0.0/0"] }
      ]
    }
  }
}

# Load balancer
module "load_balancer" {
  source = "./modules/aws-alb"

  name       = local.name
  vpc_id     = module.network.vpc.id
  subnet_ids = [for key, subnet in module.network.public_subnets : subnet.id]

  ingress = [
    { protocol = "tcp", from_port = 80, to_port = 80, cidr_blocks = ["0.0.0.0/0"] }
  ]
}

# Service discovery
module "service_discovery" {
  source = "./modules/aws-service-discovery"

  name   = local.name
  vpc_id = module.network.vpc.id

  domain   = "internal"
  services = ["nginx"]
}

# App Mesh
module "app_mesh" {
  source = "./modules/aws-app-mesh"

  name          = local.name
  egress_filter = "ALLOW_ALL"

  virtual_nodes = {
    "nginx" = {
      cloud_map_namespace = module.service_discovery.namespace.name
      cloud_map_service   = module.service_discovery.services["nginx"].name

      istener_protocol = "http"
      listener_port    = 80
    }
  }

  virtual_services = {
    "nginx.internal" = {
      virtual_node = "nginx"
    }
  }
}

# CloudWatch log group
resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/ecs/nginx"
  retention_in_days = 7
}

# Secrets Manager example
resource "aws_secretsmanager_secret" "nginx_secret_example" {
  name = "/ecs/nginx/example"
}

resource "aws_secretsmanager_secret_version" "nginx_secret_example_value" {
  secret_id     = aws_secretsmanager_secret.nginx_secret_example.id
  secret_string = "Secret value"
}

resource "aws_iam_policy" "nginx_secret_example_policy" {
  name = "${local.name}-nginx-secret-example-policy"

  tags = {
    Name = "${local.name}-nginx-secret-example-policy"
  }

  policy = <<-DATA
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": ["secretsmanager:GetSecretValue"],
          "Resource": ["${aws_secretsmanager_secret.nginx_secret_example.arn}"]
        }
      ]
    }
  DATA
}

# ECS
module "ecs" {
  source = "./modules/aws-ecs"

  name = local.name

  task_definitions = {
    "nginx" = {
      requires_compatibilities = ["FARGATE"],
      network_mode             = "awsvpc",
      cpu                      = 512,
      memory                   = 1024,
      extra_policy_arn         = aws_iam_policy.nginx_secret_example_policy.arn,
      app_mesh = {
        container_name = "nginx",
        container_port = "80"
      },
      container_definitions = jsonencode(
        [
          # Nginx with custom config
          {
            "name":  "nginx",
            "image": "nginx:1.25.1",
            "cpu":    256,
            "memory": 512,
            "portMappings" : [{"containerPort": 80, "hostPort": 80}],
            "entryPoint": ["/bin/sh", "-c"],
            "command": ["echo \"$NGINX_CONFIG\" > /etc/nginx/nginx.conf && echo \"$NGINX_JS\" > /etc/nginx/nginx.js && exec nginx -g 'daemon off;'"],
            "environment": [
              {"name": "NGINX_CONFIG", "Value": file("./files/nginx.conf")},
              {"name": "NGINX_JS", "Value": file("./files/nginx.js")}
            ],
            "secrets": [
              {
                "name": "NGINX_SECRET_EXAMPLE",
                "valueFrom": "${aws_secretsmanager_secret.nginx_secret_example.arn}:::${aws_secretsmanager_secret_version.nginx_secret_example_value.version_id}"
              }
            ],
            "healthCheck": {
              "command": ["CMD-SHELL", "curl --fail http://localhost || exit 1"],
              "startPeriod": 5,
              "interval": 30,
              "timeout": 15,
              "retries": 3
            },
            "logConfiguration": {
              "logDriver": "awslogs",
              "options": {
                "awslogs-region": local.aws_region,
                "awslogs-group": aws_cloudwatch_log_group.nginx.name,
                "awslogs-stream-prefix": "nginx"
              }
            }
          },
          # Envoy (for App Mesh)
          {
              "essential": true,
              "name": "envoy",
              "image": "840364872350.dkr.ecr.us-east-1.amazonaws.com/aws-appmesh-envoy:v1.25.4.0-prod",
              "environment": [{"name": "APPMESH_VIRTUAL_NODE_NAME", "value": "mesh/experiments-mesh/virtualNode/nginx"}],
              "cpu": 256,
              "memory": 512,
              "user": "1337",
              "healthCheck": {
                "command": ["CMD-SHELL", "curl -s http://localhost:9901/server_info | grep state | grep -q LIVE"],
                "startPeriod": 10,
                "interval": 5,
                "timeout": 2,
                "retries": 3
              },
              "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                  "awslogs-region": local.aws_region,
                  "awslogs-group": aws_cloudwatch_log_group.nginx.name,
                  "awslogs-stream-prefix": "envoy"
                }
              }
            }
        ]
      )
    }
  }

  services = {
    "nginx" = {
      task_definition        = "nginx",
      launch_type            = "FARGATE",
      enable_execute_command = true,
      vpc_id                 = module.network.vpc.id,
      subnet_ids             = [for key, subnet in module.network.private_subnets : subnet.id],
      service_registry_arn   = module.service_discovery.services["nginx"].arn,
      load_balancer = {
        target_group_arn = module.load_balancer.alb_target_group.arn
        container_name   = "nginx"
        container_port   = 80
      },
      ingress = [
        { protocol = "tcp", from_port = 80, to_port = 80, cidr_blocks = ["0.0.0.0/0"] }
      ]
    }
  }
}
