# Cortex Lite: 3 Hetzner Cloud servers + private network + firewalls.
# srv-gpu (GEX44) is a Robot dedicated server, joined via vSwitch subnet.
# Note: Hetzner Cloud firewalls filter public interfaces only; private
# network traffic is filtered by nftables (see infra/ansible).

terraform {
  required_version = ">= 1.9"
  required_providers {
    hcloud = { source = "hetznercloud/hcloud", version = "~> 1.52" }
  }
}

provider "hcloud" { token = var.hcloud_token }

variable "hcloud_token" { sensitive = true }
variable "location"     { default = "fsn1" }
variable "vswitch_id"   { description = "Robot vSwitch id for srv-gpu" }
variable "headscale_authkey" { sensitive = true }

locals {
  servers = {
    "srv-app"  = { type = "ccx23", ip = "10.10.1.10", fw = "app" }
    "srv-data" = { type = "ccx33", ip = "10.10.1.20", fw = "private" }
    "srv-ops"  = { type = "cpx32", ip = "10.10.1.30", fw = "ops" }
  }
}

resource "hcloud_network" "main" {
  name     = "cortex"
  ip_range = "10.10.0.0/16"
}

resource "hcloud_network_subnet" "cloud" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.10.1.0/24"
}

resource "hcloud_network_subnet" "gpu" {
  network_id   = hcloud_network.main.id
  type         = "vswitch"
  network_zone = "eu-central"
  ip_range     = "10.10.2.0/24"
  vswitch_id   = var.vswitch_id
}

# Public ingress: app 443 only; ops 443 + 3478/udp (Headscale, DERP).
# Outbound rules present => all other outbound is dropped.
resource "hcloud_firewall" "fw" {
  for_each = {
    app     = [["tcp", "443"]]
    ops     = [["tcp", "443"], ["udp", "3478"]]
    private = []
  }
  name = "cortex-${each.key}"

  dynamic "rule" {
    for_each = each.value
    content {
      direction  = "in"
      protocol   = rule.value[0]
      port       = rule.value[1]
      source_ips = ["0.0.0.0/0", "::/0"]
    }
  }

  # Egress: HTTPS (registry, ACME, Smokescreen targets, Object Storage), DNS, NTP.
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "443"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "53"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "123"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "srv" {
  for_each     = local.servers
  name         = each.key
  server_type  = each.value.type
  image        = "ubuntu-24.04"
  location     = var.location
  firewall_ids = [hcloud_firewall.fw[each.value.fw].id]
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    headscale_authkey = var.headscale_authkey
    is_ops            = each.key == "srv-ops"
  })

  network {
    network_id = hcloud_network.main.id
    ip         = each.value.ip
  }
  depends_on = [hcloud_network_subnet.cloud]
}

# Object Storage bucket for pgBackRest: created via the S3 API
# (hcloud provider has no bucket resource, unverified). See runbook.

output "public_ips" { value = { for k, s in hcloud_server.srv : k => s.ipv4_address } }
