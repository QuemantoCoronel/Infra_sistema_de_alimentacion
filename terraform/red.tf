data "aws_availability_zones" "disponibles" {
  state = "available"
}

locals {
  zonas_worker = slice(data.aws_availability_zones.disponibles.names, 0, 2)
}

resource "aws_vpc" "worker" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.nombre}-vpc-worker"
  }
}

resource "aws_default_security_group" "worker" {
  vpc_id = aws_vpc.worker.id
}

resource "aws_internet_gateway" "worker" {
  vpc_id = aws_vpc.worker.id

  tags = {
    Name = "${local.nombre}-igw-worker"
  }
}

resource "aws_subnet" "publica" {
  count                   = length(local.zonas_worker)
  vpc_id                  = aws_vpc.worker.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone       = local.zonas_worker[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.nombre}-subred-publica-${local.zonas_worker[count.index]}"
  }
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.worker.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.worker.id
  }

  tags = {
    Name = "${local.nombre}-rutas-publicas"
  }
}

resource "aws_route_table_association" "publica" {
  count          = length(aws_subnet.publica)
  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}
