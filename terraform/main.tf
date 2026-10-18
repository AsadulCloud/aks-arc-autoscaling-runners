resource "azurerm_resource_group" "rg" { 
  name     = local.resource_group_name
  location = var.location 
} 
 
# Create the AKS Cluster 
resource "azurerm_kubernetes_cluster" "aks" { 
  name                = var.cluster_name 
  location            = azurerm_resource_group.rg.location 
  resource_group_name = azurerm_resource_group.rg.name 
  dns_prefix          = "arcrunners"
 
  default_node_pool { 
    name       = "default" 
    node_count = 2 
    vm_size    = "Standard_B2s_v2" 
  } 
 
  identity { 
    type = "SystemAssigned" 
  } 
  node_provisioning_profile {
    mode = "Manual"
  }
} 