provider "aws" {
  //region = local.region
}

terraform {
  backend "s3" {}
}

data "aws_availability_zones" "available" {}

locals {
  name   = "ex-${basename(path.cwd)}"
  //region = "eu-west-3"

  vpc1_cidr              = "10.10.0.0/16"
  vpc2_cidr              = "10.20.0.0/16"
  secondary_cidr_blocks = ["100.64.0.0/16"]
  azs                   = slice(data.aws_availability_zones.available.names, 0, 3)


}

################################################################################
# VPC Module
################################################################################

module "vpc1" {
  source = "terraform-aws-modules/vpc/aws"

  name = local.name
  cidr = local.vpc1_cidr

  secondary_cidr_blocks = local.secondary_cidr_blocks 

}

module "vpc2" {
  source = "terraform-aws-modules/vpc/aws"

  name = local.name
  cidr = local.vpc2_cidr

  secondary_cidr_blocks = local.secondary_cidr_blocks 

}

# create a subnet
resource "aws_subnet" "vpc1SubnetRoutable" {
  cidr_block        =  cidrsubnet(module.vpc1.vpc_cidr_block, 8, 0)
  availability_zone  = data.aws_availability_zones.available.names[0]
  vpc_id            =  module.vpc1.vpc_id
  tags = {
    Name = "${local.name}-vpc1SubnetRoutable"
  }
}

resource "aws_subnet" "vpc1SubnetNonRoutable" {
  cidr_block        =  cidrsubnet(element(module.vpc1.vpc_secondary_cidr_blocks,0), 8, 0)
  availability_zone  = data.aws_availability_zones.available.names[0]
  vpc_id            =  module.vpc1.vpc_id
  tags = {
    Name = "${local.name}-vpc1SubnetNonRoutable"
  }
}

# create a subnet
resource "aws_subnet" "vpc2SubnetRoutable" {
  cidr_block        =  cidrsubnet(module.vpc2.vpc_cidr_block, 8, 0)
  availability_zone  = data.aws_availability_zones.available.names[0]
  vpc_id            =  module.vpc2.vpc_id
  tags = {
    Name = "${local.name}-vpc2SubnetRoutable"
  }
}

resource "aws_subnet" "vpc2SubnetNonRoutable" {
  cidr_block        =  cidrsubnet(element(module.vpc2.vpc_secondary_cidr_blocks,0), 8, 0)
  availability_zone  = data.aws_availability_zones.available.names[0]
  vpc_id            =  module.vpc2.vpc_id
  tags = {
    Name = "${local.name}-vpc2SubnetNonRoutable"
  }
}


resource "aws_ec2_transit_gateway" "tgw" {
  description                     = "Transit Gateway testing scenario with 4 VPCs, 2 subnets each"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = {
    Name = "${local.name}-tgw"
  }
}

resource "aws_ec2_transit_gateway_route_table" "tgw-rt" {
  transit_gateway_id = "${aws_ec2_transit_gateway.tgw.id}"
  tags               = {
    Name = "${local.name}-tgw-rt"
  }
  depends_on = [aws_ec2_transit_gateway.tgw]
}



resource "aws_ec2_transit_gateway_vpc_attachment" "tgw-att-vpc-1" {
  subnet_ids         = ["${aws_subnet.vpc1SubnetNonRoutable.id}"]
  transit_gateway_id = "${aws_ec2_transit_gateway.tgw.id}"
  vpc_id             = "${module.vpc1.vpc_id}"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags               = {
    Name             = "${local.name}-tgw-attch-vpc1"
  }
  depends_on = [aws_ec2_transit_gateway.tgw]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "tgw-att-vpc-2" {
  subnet_ids         = ["${aws_subnet.vpc2SubnetNonRoutable.id}"]
  transit_gateway_id = "${aws_ec2_transit_gateway.tgw.id}"
  vpc_id             = "${module.vpc2.vpc_id}"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags               = {
    Name             = "${local.name}-tgw-attch-vpc2"
  }
  depends_on = [aws_ec2_transit_gateway.tgw]
}

resource "aws_ec2_transit_gateway_route_table_association" "tgw-rt-vpc-1-assoc" {
  transit_gateway_attachment_id  = "${aws_ec2_transit_gateway_vpc_attachment.tgw-att-vpc-1.id}"
  transit_gateway_route_table_id = "${aws_ec2_transit_gateway_route_table.tgw-rt.id}"
}

resource "aws_ec2_transit_gateway_route_table_association" "tgw-rt-vpc-2-assoc" {
  transit_gateway_attachment_id  = "${aws_ec2_transit_gateway_vpc_attachment.tgw-att-vpc-2.id}"
  transit_gateway_route_table_id = "${aws_ec2_transit_gateway_route_table.tgw-rt.id}"
}

# create a transit gateway route
resource "aws_ec2_transit_gateway_route" "tgw-route-1" {
  destination_cidr_block         = local.vpc1_cidr
  transit_gateway_attachment_id  = "${aws_ec2_transit_gateway_vpc_attachment.tgw-att-vpc-1.id}"
  transit_gateway_route_table_id = "${aws_ec2_transit_gateway_route_table.tgw-rt.id}"
  depends_on = [ aws_ec2_transit_gateway_vpc_attachment.tgw-att-vpc-1 ]
}

resource "aws_ec2_transit_gateway_route" "tgw-route-2" {
  destination_cidr_block         = local.vpc2_cidr
  transit_gateway_attachment_id  = "${aws_ec2_transit_gateway_vpc_attachment.tgw-att-vpc-2.id}"
  transit_gateway_route_table_id = "${aws_ec2_transit_gateway_route_table.tgw-rt.id}"
  depends_on = [ aws_ec2_transit_gateway_vpc_attachment.tgw-att-vpc-2 ]
}

# create vpc route table
resource "aws_route_table" "vpc1RT" {
  vpc_id =  module.vpc1.vpc_id
  tags = {
    Name = "${local.name}-vpc1RT"
  }
}

resource "aws_route_table" "vpc2RT" {
  vpc_id =  module.vpc2.vpc_id
  tags = {
    Name = "${local.name}-vpc2RT"
  }
}

resource "aws_route" "vpc1-route-to-vpc2" {
  route_table_id         = aws_route_table.vpc1RT.id
  destination_cidr_block = local.vpc2_cidr
  transit_gateway_id     = "${aws_ec2_transit_gateway.tgw.id}"
  depends_on             = [aws_ec2_transit_gateway_route.tgw-route-2]
}

resource "aws_route" "vpc2-route-to-vpc1" {
route_table_id         = aws_route_table.vpc2RT.id
  destination_cidr_block = local.vpc1_cidr
  transit_gateway_id     = "${aws_ec2_transit_gateway.tgw.id}"
  depends_on             = [aws_ec2_transit_gateway_route.tgw-route-1]
}

resource "aws_route_table_association" "vpc1-route-to-vpc2-ass1" {
  subnet_id      = aws_subnet.vpc1SubnetRoutable.id
  route_table_id = aws_route_table.vpc1RT.id
}
resource "aws_route_table_association" "vpc1-route-to-vpc2-ass2" {
  subnet_id      = aws_subnet.vpc1SubnetNonRoutable.id
  route_table_id = aws_route_table.vpc1RT.id
}

resource "aws_route_table_association" "vpc2-route-to-vpc1-ass1" {
  subnet_id      = aws_subnet.vpc2SubnetRoutable.id
  route_table_id = aws_route_table.vpc2RT.id
}
resource "aws_route_table_association" "vpc2-route-to-vpc1-ass2" {
  subnet_id      = aws_subnet.vpc2SubnetNonRoutable.id
  route_table_id = aws_route_table.vpc2RT.id
}


