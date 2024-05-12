#############################################################################
# VARIABLES
#############################################################################

variable "tenant_domain_name" {
  type        = string
  description = "A tenant's domain name in Entra ID is a unique, customizable domain that represents the organization's identity namespace for user sign-in and email addresses within the tenant (e.g: contoso.org or contoso.onmicrosoft.com)"
}

variable "entraid_user_name" {
	type        = string
	description = "A user is an entity that represents an individual user account and associated attributes within the Entra ID identity and access management service"
}

variable "entraid_user_password" {
	type		    = string
	description	= "Password associated with the previously created Entra ID user"
}

variable "resource_group" {
  type        = string
  description = "A resource group is a logical container that groups together related Azure resources for management & access control purposes"
}

variable "virtual_network_name" {
	type        = string
	description = "A virtual network is a logically isolated network infrastructure that enables secure communication between resources (in Azure, on-prem, ...)"
}

variable "storage_account_name" {
	type		    = string
	description = "A storage account represents a globally unique namespace within Azure, responsible for storing data objects, such as blobs, files and more"
}

variable "storage_container_name" {
	type		    = string
	description = "A storage container is a representation of a folder within a storage account, where it is possible to store files"
}

variable "linux_virtual_machine_name" {
	type        = string
	description = "A virtual machine running linux"
}

variable "linux_vm_admin_user" {
  type        = string
  description = "Local admin user account on the previosuly created VM"
}

variable "linux_vm_admin_user_password" {
  type        = string
  description = "Password associated with the previously created local admin account"
}

variable "linux_vm_managed_identity_name" {
	type        = string
	description = "A managed identity can be associated with Azure resources (like VMs, Functions, ...), enabling them to authenticate securely with other Azure services without requiring explicit credentials"
}

#############################################################################
# DATA
#############################################################################

data "azurerm_subscription" "current" {}

data "azurerm_resource_group" "current" {
  name = var.resource_group
}

#############################################################################
# PROVIDERS
#############################################################################

provider "azurerm" {
  features {}
}

provider "azuread" {
}


#############################################################################
# RESOURCES
#############################################################################

## ENTRA ID USER ##

resource "azuread_user" "user" {
  user_principal_name = "${var.entraid_user_name}@${var.tenant_domain_name}"
  display_name        = var.entraid_user_name
  password            = var.entraid_user_password
}

resource "azuread_application" "scenario1App" {
  display_name = "scenario1App"
  owners = [azuread_user.user.object_id]
}

resource "azuread_service_principal" "scenario1SPN" {
  client_id               = azuread_application.scenario1App.client_id
  owners                       = [azuread_user.user.id]
}

## AZURE LINUX VIRTUAL MACHINE ##

resource "azurerm_virtual_network" "main" {
  name                = var.virtual_network_name
  address_space       = ["10.0.0.0/16"]
  location            =  data.azurerm_resource_group.current.location
  resource_group_name = data.azurerm_resource_group.current.name
}

resource "azurerm_subnet" "internal" {
  name                 = "internal"
  resource_group_name  = data.azurerm_resource_group.current.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}


resource "azurerm_user_assigned_identity" "uai" {
  name                = var.linux_vm_managed_identity_name
  resource_group_name = data.azurerm_resource_group.current.name
  location            = data.azurerm_resource_group.current.location
}

resource "azurerm_network_interface" "linux" {
  name                = var.linux_virtual_machine_name
  resource_group_name = data.azurerm_resource_group.current.name
  location            = data.azurerm_resource_group.current.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "main" {
  name                            = var.linux_virtual_machine_name
  resource_group_name             = data.azurerm_resource_group.current.name
  location                        = data.azurerm_resource_group.current.location
  size                            = "Standard_B2s"
  admin_username                  = var.linux_vm_admin_user
  admin_password                  = var.linux_vm_admin_user_password
  disable_password_authentication = false
  network_interface_ids = [
    azurerm_network_interface.linux.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.uai.id]
  }
}

## AZURE STORAGE ACCOUNT ##
resource "azurerm_storage_account" "main" {
  name                     = var.storage_account_name
  resource_group_name      = data.azurerm_resource_group.current.name
  location                 = data.azurerm_resource_group.current.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "main" {
  name                  = var.storage_container_name
  storage_account_name  = azurerm_storage_account.main.name
  container_access_type = "private"
}

resource "azurerm_storage_blob" "file" {
  name                   = "secret.txt"
  storage_account_name   = azurerm_storage_account.main.name
  storage_container_name = azurerm_storage_container.main.name
  type                   = "Block"
  source                 = "secret.txt"
}


## AZURE ROLE AND ROLE ASSIGNMENT ##

resource "azurerm_role_definition" "run-command-on-vm" {
  name     = "Run Command Role Scenario 1"
  scope    = data.azurerm_subscription.current.id
  description = "This role allow to run command on vm"

  permissions {
    actions     = ["Microsoft.Compute/virtualMachines/read", "Microsoft.Compute/virtualMachines/runCommand/action"]
    not_actions = []
  }

  assignable_scopes = [
    data.azurerm_subscription.current.id,
  ]
}

resource "azurerm_role_assignment" "run-command-on-linux-vm" {
  scope              = azurerm_linux_virtual_machine.main.id
  role_definition_id = split("|", azurerm_role_definition.run-command-on-vm.id)[0]
  principal_id       = azuread_service_principal.scenario1SPN.id
}

resource "azurerm_role_definition" "read-blobs" {
  name     = "Read Blobs Role Scenario 1"
  scope    = data.azurerm_subscription.current.id
  description = "This role allow to download blobs from storage account"

  permissions {
    actions     = ["Microsoft.Storage/storageAccounts/read", "Microsoft.Storage/storageAccounts/blobServices/containers/read"]
    data_actions = ["Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read"]
    not_actions = []
  }

  assignable_scopes = [
    data.azurerm_subscription.current.id,
  ]
}

resource "azurerm_role_assignment" "read-blobs" {
  scope              = azurerm_storage_account.main.id
  role_definition_id = split("|", azurerm_role_definition.read-blobs.id)[0]
  principal_id       = azurerm_user_assigned_identity.uai.principal_id
}

## Output
output "username"{
  value = azuread_user.user.user_principal_name
}

output "password" {
  value = azuread_user.user.password
  sensitive = true
}
