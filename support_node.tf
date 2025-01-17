resource "macaddress" "k3s-support" {}

locals {
  support_node_ip = cidrhost(var.control_plane_subnet, 0)
}

locals {
  lan_subnet_cidr_bitnum = split("/", var.lan_subnet)[1]
}

resource "random_password" "pgadmin-user-password" {
  length  = 16
  special = true
}

resource "proxmox_vm_qemu" "k3s-support" {
  target_node = var.proxmox_node
  name        = join("-", [var.cluster_name, "support"])

  clone = var.node_templates["support"]

  pool = var.proxmox_resource_pool

  cores   = var.support_node_settings.cores
  sockets = var.support_node_settings.sockets
  memory  = var.support_node_settings.memory

  agent = 1
  disk {
    type    = var.support_node_settings.storage_type
    storage = var.support_node_settings.storage_id
    size    = var.support_node_settings.disk_size
  }

  network {
    bridge    = var.support_node_settings.network_bridge
    firewall  = true
    link_down = false
    macaddr   = upper(macaddress.k3s-support.address)
    model     = "virtio"
    queues    = 0
    rate      = 0
    tag       = var.support_node_settings.network_tag
  }

  lifecycle {
    ignore_changes = [
      ciuser,
      sshkeys,
      disk,
      network
    ]
  }

  os_type = "cloud-init"

  ciuser = var.support_node_settings.user

  ipconfig0 = "ip=${local.support_node_ip}/${local.lan_subnet_cidr_bitnum},gw=${var.network_gateway}"

  sshkeys = file(var.authorized_keys_file)

  nameserver = var.nameserver

  connection {
    type = "ssh"
    user = var.support_node_settings.user
    host = local.support_node_ip
  }

  provisioner "file" {
    destination = "/opt/install.sh"
    content = templatefile("${path.module}/scripts/install-support-apps.sh.tftpl", {
      root_password = random_password.support-db-password.result

      k3s_database = var.support_node_settings.db_name
      k3s_user     = var.support_node_settings.db_user
      k3s_password = random_password.k3s-master-db-password.result

      postgres_version = var.postgres_version
      pgadmin_version  = var.pgadmin_version
      pgadmin_email    = var.pgadmin_email
      pgadmin_password = coalesce(var.pgadmin_password, random_password.pgadmin-user-password.result)

      nginx_version = var.nginx_version

      http_proxy = var.http_proxy
    })
  }

  provisioner "remote-exec" {
    inline = [
      "chmod u+x /opt/install.sh",
      "/opt/install.sh",
      "rm -r /opt/install.sh",
    ]
  }
}

resource "random_password" "support-db-password" {
  length           = 16
  special          = false
  override_special = "_%@"
}

resource "random_password" "k3s-master-db-password" {
  length           = 16
  special          = false
  override_special = "_%@"
}

locals {
  k3s_server_nodes = [for ip in local.master_node_ips :
    "${ip}:6443"
  ]
  k3s_worker_nodes = concat(local.master_node_ips, [
    for node in local.listed_worker_nodes :
    node.ip
  ])
}

resource "null_resource" "k3s_nginx_config" {
  depends_on = [
    proxmox_vm_qemu.k3s-support
  ]

  triggers = {
    config_change    = filemd5("${path.module}/config/nginx.conf.tftpl")
    k3s_server_nodes = join(",", local.k3s_server_nodes)
    k3s_worker_nodes = join(",", local.k3s_worker_nodes)
  }

  connection {
    type = "ssh"
    user = var.support_node_settings.user
    host = local.support_node_ip
  }

  provisioner "file" {
    destination = "/opt/k3s-nginx/conf/nginx.conf"
    content = templatefile("${path.module}/config/nginx.conf.tftpl", {
      k3s_server_nodes = local.k3s_server_nodes
      k3s_worker_nodes = local.k3s_worker_nodes
    })
  }

  provisioner "remote-exec" {
    inline = [
      "sudo docker restart k3s-nginx",
    ]
  }
}
