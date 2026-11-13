output "runner_public_ip" {
  value = aws_instance.runner.public_ip
}

output "runner_id" {
  value = aws_instance.runner.id
}

output "nodes" {
  value = {
    for name, inst in aws_instance.node : name => {
      id         = inst.id
      private_ip = inst.private_ip
      public_ip  = inst.public_ip
    }
  }
}
