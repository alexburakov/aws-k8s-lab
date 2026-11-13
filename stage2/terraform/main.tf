data "aws_ami" "ubuntu" {
  owners = ["099720109477"]

  filter {
    name   = "name"
    values = [var.ami_name]
  }
}

locals {
  subnet_cidr = "10.42.1.0/24"
  nodes = merge(
    { cp1 = cidrhost(local.subnet_cidr, 10) },
    { for i in range(1, var.worker_count + 1) : "worker${i}" => cidrhost(local.subnet_cidr, 10 + i) },
  )
  runner_ip = cidrhost(local.subnet_cidr, 5)
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "k8s-lab" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "k8s-lab" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = local.subnet_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = true
  tags                    = { Name = "k8s-lab-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "k8s-lab-public" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "lab" {
  name   = "k8s-lab"
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "k8s-lab" }
}

resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.lab.id
  referenced_security_group_id = aws_security_group.lab.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  for_each = {
    for pair in setproduct(var.admin_cidrs, [22, 80, 443, 6443]) : "${pair[0]}-${pair[1]}" => pair
  }
  security_group_id = aws_security_group.lab.id
  cidr_ipv4         = each.value[0]
  from_port         = each.value[1]
  to_port           = each.value[1]
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.lab.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_key_pair" "admin" {
  key_name   = "k8s-lab-admin"
  public_key = var.admin_ssh_public_key
}

resource "tls_private_key" "cluster" {
  algorithm = "ED25519"
}

resource "aws_iam_role" "ssm" {
  name = "k8s-lab-ssm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "k8s-lab-ssm"
  role = aws_iam_role.ssm.name
}

resource "aws_instance" "node" {
  for_each = local.nodes

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.node_type
  subnet_id              = aws_subnet.public.id
  private_ip             = each.value
  vpc_security_group_ids = [aws_security_group.lab.id]
  key_name               = aws_key_pair.admin.key_name
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  user_data = templatefile("${path.module}/cloud-init-node.yaml.tftpl", {
    hostname       = each.key
    cluster_pubkey = trimspace(tls_private_key.cluster.public_key_openssh)
  })

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = each.key }
}

resource "aws_instance" "runner" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.runner_type
  subnet_id              = aws_subnet.public.id
  private_ip             = local.runner_ip
  vpc_security_group_ids = [aws_security_group.lab.id]
  key_name               = aws_key_pair.admin.key_name
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  user_data = file("${path.module}/cloud-init-runner.yaml")

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "runner" }
}

resource "local_sensitive_file" "cluster_key" {
  content         = tls_private_key.cluster.private_key_openssh
  filename        = "${path.module}/../.secrets/cluster_ed25519"
  file_permission = "0600"
}

resource "local_file" "hosts" {
  content = templatefile("${path.module}/hosts.yaml.tftpl", {
    nodes   = local.nodes
    workers = [for name in keys(local.nodes) : name if name != "cp1"]
  })
  filename = "${path.module}/../inventory/hosts.yaml"
}
