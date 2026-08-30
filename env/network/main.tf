module "k8s_cp_network" {
  source = "../../mod/sdn-network"

  zone_id = "k8scp"
  vnet_id = "k8svncp"

  nodes   = local.node_names
  peers   = local.node_ips
  mtu     = 1450
  vni_tag = 100

  subnet_cidr    = "10.100.0.0/24"
  subnet_gateway = "10.100.0.1"
  subnet_snat    = true
}
