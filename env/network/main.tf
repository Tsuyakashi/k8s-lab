module "k8s_cp_network" {
  source = "../../mod/sdn-network"

  zone_id = "k8scp"
  vnet_id = "k8svncp"

  nodes = local.node_names
  peers = local.node_ips
  mtu   = 1450

  controller_id  = "k8sevpn"
  controller_asn = 65000

  vrf_vxlan         = 10000
  vni_tag           = 100
  exit_nodes        = local.node_names
  primary_exit_node = "bare-pve"

  subnet_cidr    = "10.100.0.0/24"
  subnet_gateway = "10.100.0.1"
  subnet_snat    = true
}
