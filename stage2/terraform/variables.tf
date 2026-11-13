variable "region" {
  type    = string
  default = "us-east-1"
}

variable "az" {
  type    = string
  default = "us-east-1a"
}

variable "admin_cidrs" {
  type = list(string)
}

variable "admin_ssh_public_key" {
  type = string
}

variable "ami_name" {
  type    = string
  default = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-20261108"
}

variable "node_type" {
  type    = string
  default = "c7i-flex.large"
}

variable "runner_type" {
  type    = string
  default = "t3.small"
}

variable "worker_count" {
  type    = number
  default = 3
}
