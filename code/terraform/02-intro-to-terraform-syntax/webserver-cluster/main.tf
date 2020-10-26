// Deploy cluster of webservers using:
// Auto Scale Group
// Elastic Load Balancer (Application Load Balancer) 

terraform {
  required_version = ">= 0.12, < 0.13"
}

provider "aws" {
  region = "us-east-2"

  # Allow any 2.x version of the AWS provider
  version = "~> 2.0"
}

// The first step in creating an ASG is to create a launch configuration,
// which specifies how to configure each EC2Instance in the ASG.
// Uses almost exactly the same parameters as aws_instance
// Requires Security Group as well

resource "aws_launch_configuration" "example" {
  image_id        = "ami-0c55b159cbfafe1f0"
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.instance.id]

  user_data = <<-EOF
              #!/bin/bash
              echo "Hello, World" > index.html
              nohup busybox httpd -f -p ${var.server_port} &
              EOF

  # Required when using a launch configuration with an auto scaling group.
  # https://www.terraform.io/docs/providers/aws/r/launch_configuration.html
  # Create new resource then destroy old resource
  lifecycle {
    create_before_destroy = true
  }
}

# Now create ASG itself
# Note ASG uses reference to fill in the launch configuration name
# This means launch configurations are immutable, so if you change any parameter of your
# launch configuration, terraform will try to replace it (delete old, replace with new)
# But because ASG now has a reference to the old resource, terraform won't be able to delete it
# To solve this problem, you can use lifecycle setting in the aws launch_configuration
# ASG requires subnet_ids (vpc_zone_identifier) which VPC subnets the EC2 instances should
# be deployed into
# Each subnet lives in an insolated AWS AZ, by deploying across multiple subnets you ensure
# that your service can keep running even if some of the AZ have an outage

resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier  = data.aws_subnet_ids.default.ids

  target_group_arns = [aws_lb_target_group.asg.arn]

  # You should also update the health_check_type to "ELB". 
  # The default health_check_type is "EC2", which is a minimal health check that considers an 
  # Instance unhealthy only if the AWS hypervisor says the VM is completely downor unreachable. 
  # The "ELB" health check is more robust, because it instructs the ASG to use the target group’s 
  # healthcheck to determine whether an Instance is healthy and to automatically replace Instances 
  # if the target group reportsthem as unhealthy. That way, Instances will be replaced not only if 
  # they are completely down, but also if, for example,they’ve stopped serving requests because 
  # they ran out of memory or a critical process crashed.
  health_check_type = "ELB"

  min_size = 2
  max_size = 10

  tag {
    key                 = "Name"
    value               = "terraform-asg-example"
    propagate_at_launch = true
  }
}

# Security Group used in the ASG Launch Configuration

resource "aws_security_group" "instance" {
  name = var.instance_security_group_name

  ingress {
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Note that with data sources, the arguments you pass in are typically search filters that 
# indicate to the data source what information you’re looking for
# With the aws_vpc data source, the only filter you need is default = true, which
# directs Terraform to look up the Default VPC in your AWS account

data "aws_vpc" "default" {
  default = true
}

# Get the ID of the VPC from the aws_vpc data source
# Finally, you can pull the subnet IDs out of the aws_subnet_ids data source and tell your ASG 
# to use those subnets via the (somewhat oddly named) vpc_zone_identifier argument:

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

# At this point, you can deploy your ASG, but you’ll have a small problem: you now have
# multiple servers, each with its own IP address, but you typically want to give of your end users 
# only a single IP touse.One way to solve this problem is to deploy a load balancer to distribute 
# traffic across your servers and to give allyour users the IP (actually, the DNS name) of the load balancer. 


# Create Application Load Balancer
# ALB consists of:
# 1. Listener: Listens on a specific port (e.g., 80) and protocol (e.g., HTTP).
# 2. Listener Rule: Takes requests that come into a listener and sends those that match specific 
#   paths (e.g., /foo and/bar) or hostnames (e.g., foo.example.com and bar.example.com)
#   to specific target groups. 
# 3. Target Groups: One or more servers that receive requests from the load balancer. The target 
#   group also performs health checks on these servers and only sends requests to healthy nodes
# Note that the subnets parameter configures the load balancer to use all the subnets in 
# your Default VPC by using theaws_subnet_ids data source

resource "aws_lb" "example" {

  name               = var.alb_name

  load_balancer_type = "application"
  subnets            = data.aws_subnet_ids.default.ids
  security_groups    = [aws_security_group.alb.id]
}

# The next step is to define a listener for this ALB using the aws_lb_listener resource:

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = 80
  protocol          = "HTTP"

  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

# Next, you need to create a target group for your ASG using the aws_lb_target_group resource
# Note that this target group will health check your Instances by periodically sending an HTTP 
# request to each Instanceand will consider the Instance “healthy” only if the Instance returns a 
# response that matches the configured matcher(e.g., you can configure a matcher to look for a 
# 200 OK response)
# How does the target group know which EC2 Instances to send requests to? You could attach a 
# static list of EC2 Instancesto the target group using the aws_lb_target_group_attachment 
# resource, but with an ASG, Instances can launch orterminate at any time, so a static list 
# won’t work.Instead, you can take advantage of the first-class integration between the ASG and 
# the ALB. 
# Go back to theaws_autoscaling_group resource and set its target_group_arns argument to point at your new target group

resource "aws_lb_target_group" "asg" {

  name = var.alb_name

  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# code adds a listener rule that send requests that match any path  to the target group that contains your ASG

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

# Note that, by default, all AWS resources, including ALBs, don’t allow any 
# incoming or outgoing traffic, so you need to create a new security group specifically for the ALB
# This security group should allow incoming requests on port 80 so that you can access the 
# load balancer over HTTP, and outgoing requests on all ports so that the load balancer can performhealth checks:
# You’ll need to tell the aws_lb resource to use this security group via the security_groups argument

resource "aws_security_group" "alb" {

  name = var.alb_security_group_name

  # Allow inbound HTTP requests
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound requests
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

