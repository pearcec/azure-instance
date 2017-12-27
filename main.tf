# variables
variable "computer_name"  { type = "string" }
variable "ssh_keys"       { type = "map" }
variable "cloud_shell_ip" { type = "string" }

# Authentication via az login Azure Cloud shell by default
# Configure the Azure Provider
provider "azurerm" { }

# Cloud Shell storage account
terraform {
  backend "azurerm" {
    storage_account_name = "cs2677a0daaf239x4c4dxb00"
    container_name       = "tfstate"
    key                  = "azure-instance.terraform.tfstate"
    # Authentication via export ARM_ACCESS_KEY
  }
}

# Create a resource group
resource "azurerm_resource_group" "rg" {
  name     = "azure-instance"
  location = "East US"
}

# Create a virtual network within the resource group
resource "azurerm_virtual_network" "network" {
  name                = "10.11.0.0_16"
  address_space       = ["10.11.0.0/16"]
  location            = "${azurerm_resource_group.rg.location}"
  resource_group_name = "${azurerm_resource_group.rg.name}"
}

resource "azurerm_subnet" "subnet" {
  name                 = "10.11.12.0_24"
  resource_group_name  = "${azurerm_resource_group.rg.name}"
  virtual_network_name = "${azurerm_virtual_network.network.name}"
  address_prefix       = "10.11.12.0/24"
}

resource "azurerm_network_security_group" "sg" {
  name                = "Open"
  location            = "${azurerm_resource_group.rg.location}"
  resource_group_name = "${azurerm_resource_group.rg.name}"
}

resource "azurerm_network_security_rule" "outbound" {
  name                        = "all"
  priority                    = 200
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = "${azurerm_resource_group.rg.name}"
  network_security_group_name = "${azurerm_network_security_group.sg.name}"
}

resource "azurerm_network_security_rule" "inbound" {
  name                        = "ssh"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "TCP"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "${var.cloud_shell_ip}/32"
  destination_address_prefix  = "*"
  resource_group_name         = "${azurerm_resource_group.rg.name}"
  network_security_group_name = "${azurerm_network_security_group.sg.name}"
}

resource "azurerm_public_ip" "public_ip" {
  name                         = "${var.computer_name}"
  location                     = "East US"
  resource_group_name          = "${azurerm_resource_group.rg.name}"
  public_ip_address_allocation = "dynamic"
  domain_name_label            = "${var.computer_name}"

  tags {
    environment = "prod"
  }
}

resource "azurerm_network_interface" "azure-instance" {
  name                      = "nic"
  location                  = "East US"
  resource_group_name       = "${azurerm_resource_group.rg.name}"
  network_security_group_id = "${azurerm_network_security_group.sg.id}"

  ip_configuration {
    name                          = "azure-instanceconfiguration1"
    subnet_id                     = "${azurerm_subnet.subnet.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${azurerm_public_ip.public_ip.id}"
  }
}

resource "azurerm_virtual_machine" "azure-instance" {
  name                  = "${var.computer_name}"
  location              = "East US"
  resource_group_name   = "${azurerm_resource_group.rg.name}"
  network_interface_ids = ["${azurerm_network_interface.azure-instance.id}"]
  vm_size               = "Standard_B1S"

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  # delete_os_disk_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name              = "myosdisk1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
    disk_size_gb      = "256"
  }

  os_profile {
    computer_name  = "${var.computer_name}"
    admin_username = "launchadmin"
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys                        = ["${var.ssh_keys}"]
  }

  tags {
    environment = "prod"
  }
}

resource "azurerm_template_deployment" "rsv" {
  name                = "tf-rsv-deployment"
  resource_group_name = "${azurerm_resource_group.rg.name}"

  parameters {
    name     = "vault"
  }

  template_body   = "${file("./rsv.json")}"
  deployment_mode = "Incremental"
}

resource "azurerm_template_deployment" "ConfigureVMProtection" {
  name                = "tf-ConfigureVMProtection"
  resource_group_name = "${azurerm_resource_group.rg.name}"
  depends_on          = ["azurerm_template_deployment.rsv"]

  parameters {
    vaultName            = "vault"
    protectionContainers = "iaasvmcontainer;iaasvmcontainerv2;${azurerm_resource_group.rg.name};${azurerm_virtual_machine.azure-instance.name}"
    protectedItems       = "vm;iaasvmcontainerv2;${azurerm_resource_group.rg.name};${azurerm_virtual_machine.azure-instance.name}"
    sourceResourceIds    = "${azurerm_virtual_machine.azure-instance.id}"
  }

  template_body   = "${file("./ConfigureVMProtection.json")}"
  deployment_mode = "Incremental"
}

