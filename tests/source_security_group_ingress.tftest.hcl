# Optional source-SG ingress: ingress_source_security_group_ids opens a port
# range (default 1024-65535) on the devbox SG to the members of the SGs passed
# in, for each protocol in ingress_source_protocols (default TCP + UDP).
# The load-bearing properties: it is a no-op by default, it references the SOURCE
# SG (not a CIDR), it opens ONLY the configured range on the configured
# protocols, and it never widens the human/coordinator ports that have their own
# knobs.

mock_provider "aws" {
  # The wrong-VPC postcondition compares the source SG's real VPC to var.vpc_id,
  # so the mocked read has to land in the same VPC for the happy paths below.
  mock_data "aws_security_group" {
    defaults = {
      vpc_id = "vpc-0123456789abcdef0"
    }
  }
}
mock_provider "random" {}

variables {
  vpc_id             = "vpc-0123456789abcdef0"
  subnet_cidrs       = ["10.4.16.0/20"]
  availability_zones = ["us-east-2a"]
  route_table_id     = "rtb-0123456789abcdef0"
  ssh_ingress_cidrs  = ["203.0.113.0/24"]
}

run "no_source_sg_rule_by_default" {
  command = plan

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = (
      length(data.aws_security_group.ingress_source) == 0 &&
      length(aws_vpc_security_group_ingress_rule.source_security_group) == 0
    )
    error_message = "With ingress_source_security_group_ids unset, no source-SG rule (and no SG lookup) may exist."
  }
}

# Default protocols are TCP *and* UDP: one rule each, same range, same source SG.
run "source_sg_opens_tcp_and_udp_1024_to_max_by_default" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.source_security_group) == 2 &&
      toset([
        for rule in aws_vpc_security_group_ingress_rule.source_security_group : rule.ip_protocol
      ]) == toset(["tcp", "udp"]) &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.source_security_group :
        rule.from_port == 1024 &&
        rule.to_port == 65535 &&
        rule.referenced_security_group_id == "sg-0aaaaaaaaaaaaaaaa" &&
        rule.cidr_ipv4 == null
      ])
    )
    error_message = "A source SG must open TCP and UDP 1024-65535, referenced by SG id (not by CIDR)."
  }

  # The whole point of the 1024 floor: enabling this must not touch the
  # human/coordinator ports, which keep their own flags and CIDRs. Nebula's
  # UDP rule is likewise untouched by adding UDP here.
  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.ssh_webpty) == 1 &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.ssh_webpty : rule.from_port == 22
      ]) &&
      length(aws_vpc_security_group_ingress_rule.coordinator) == 0 &&
      length(aws_vpc_security_group_ingress_rule.nebula) == 1 &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.nebula :
        rule.from_port == 51820 && rule.to_port == 51820 && rule.cidr_ipv4 == "0.0.0.0/0"
      ])
    )
    error_message = "Source-SG ingress must not open or widen the SSH / web-PTY / coordinator ports, nor alter the Nebula rule."
  }
}

run "protocols_can_be_narrowed_to_tcp_only" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_protocols          = ["tcp"]
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.source_security_group) == 1 &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.source_security_group :
        rule.ip_protocol == "tcp"
      ])
    )
    error_message = "ingress_source_protocols = [\"tcp\"] must create the TCP rule only."
  }
}

run "protocols_can_be_narrowed_to_udp_only" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_protocols          = ["udp"]
    ingress_source_from_port          = 5000
    ingress_source_to_port            = 5010
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.source_security_group) == 1 &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.source_security_group :
        rule.ip_protocol == "udp" && rule.from_port == 5000 && rule.to_port == 5010
      ])
    )
    error_message = "ingress_source_protocols = [\"udp\"] must create the UDP rule only, over the configured range."
  }
}

run "custom_port_range_is_applied_to_every_source_sg_and_protocol" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa", "sg-0bbbbbbbbbbbbbbbb"]
    ingress_source_from_port          = 8080
    ingress_source_to_port            = 8090
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  # 2 SGs x 2 protocols, each keyed "<protocol>-<sg>" so the pairs are distinct.
  assert {
    condition = (
      length(aws_vpc_security_group_ingress_rule.source_security_group) == 4 &&
      toset(keys(aws_vpc_security_group_ingress_rule.source_security_group)) == toset([
        "tcp-sg-0aaaaaaaaaaaaaaaa",
        "udp-sg-0aaaaaaaaaaaaaaaa",
        "tcp-sg-0bbbbbbbbbbbbbbbb",
        "udp-sg-0bbbbbbbbbbbbbbbb",
      ]) &&
      alltrue([
        for rule in aws_vpc_security_group_ingress_rule.source_security_group :
        rule.from_port == 8080 && rule.to_port == 8090
      ])
    )
    error_message = "Every (protocol, source SG) pair must get one rule carrying the configured port range."
  }

  # Each rule must reference the SG from its own key, not another one's.
  assert {
    condition = alltrue([
      for key, rule in aws_vpc_security_group_ingress_rule.source_security_group :
      rule.referenced_security_group_id == trimprefix(trimprefix(key, "tcp-"), "udp-")
    ])
    error_message = "Each rule must reference the source SG named in its own key."
  }
}

run "single_port_range_is_allowed" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_from_port          = 3000
    ingress_source_to_port            = 3000
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  assert {
    condition = alltrue([
      for rule in aws_vpc_security_group_ingress_rule.source_security_group :
      rule.from_port == 3000 && rule.to_port == 3000
    ])
    error_message = "A one-port range (from == to) must be accepted."
  }
}

run "inverted_port_range_fails" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_from_port          = 9000
    ingress_source_to_port            = 8000
  }

  expect_failures = [var.ingress_source_to_port]
}

run "out_of_range_port_fails" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_to_port            = 70000
  }

  expect_failures = [var.ingress_source_to_port]
}

run "non_security_group_id_fails" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["10.0.20.0/24"]
  }

  expect_failures = [var.ingress_source_security_group_ids]
}

# A port range is meaningless for ICMP and illegal for the "-1" wildcard, so the
# protocol list is closed rather than passed through to the provider.
run "unsupported_protocol_fails" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_protocols          = ["tcp", "icmp"]
  }

  expect_failures = [var.ingress_source_protocols]
}

run "wildcard_protocol_fails" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_protocols          = ["-1"]
  }

  expect_failures = [var.ingress_source_protocols]
}

run "uppercase_protocol_fails" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_protocols          = ["TCP"]
  }

  expect_failures = [var.ingress_source_protocols]
}

# An empty list would silently drop the rules a caller asked for by passing SGs.
run "empty_protocol_list_fails" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_protocols          = []
  }

  expect_failures = [var.ingress_source_protocols]
}

run "duplicate_protocol_fails" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
    ingress_source_protocols          = ["tcp", "tcp"]
  }

  expect_failures = [var.ingress_source_protocols]
}

# A wrong-VPC source SG has to fail at PLAN time with our message; AWS would
# otherwise reject the rule at apply with an opaque error.
run "source_sg_in_another_vpc_fails" {
  command = plan

  variables {
    ingress_source_security_group_ids = ["sg-0aaaaaaaaaaaaaaaa"]
  }

  override_data {
    target = data.aws_security_group.ingress_source["sg-0aaaaaaaaaaaaaaaa"]
    values = {
      id     = "sg-0aaaaaaaaaaaaaaaa"
      vpc_id = "vpc-0999999999999999f"
    }
  }

  override_resource {
    target = aws_security_group.this
    values = {
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  expect_failures = [data.aws_security_group.ingress_source]
}

# Passing the module's own devbox SG back in would be a box-to-box self-rule.
# Checked with `apply`: on a create the devbox SG's id is unknown at plan time,
# so the precondition that compares against it is deferred to apply.
run "self_reference_fails" {
  command = apply

  variables {
    ingress_source_security_group_ids = ["sg-0123456789abcdef0"]
  }

  override_data {
    target = data.aws_security_group.ingress_source["sg-0123456789abcdef0"]
    values = {
      id     = "sg-0123456789abcdef0"
      vpc_id = "vpc-0123456789abcdef0"
    }
  }

  override_resource {
    target = aws_security_group.this
    values = {
      id  = "sg-0123456789abcdef0"
      arn = "arn:aws:ec2:us-east-2:123456789012:security-group/sg-0123456789abcdef0"
    }
  }

  expect_failures = [aws_vpc_security_group_ingress_rule.source_security_group]
}
