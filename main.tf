terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

provider "azurerm" {
  features {}
}

# -------------------------
# VARIABLES
# -------------------------
variable "admin_password" {
  type      = string
  sensitive = true
}

# -------------------------
# RESOURCE GROUP
# -------------------------
resource "azurerm_resource_group" "rg" {
  name     = "suraj-azure-project-rg"
  location = "Central US"
}

# -------------------------
# NETWORKING
# -------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "suraj-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "public" {
  name                 = "public-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# -------------------------
# NETWORK SECURITY GROUP
# -------------------------
resource "azurerm_network_security_group" "nsg" {
  name                = "nginx-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule" "allow_ssh" {
  name                        = "Allow-SSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_network_security_rule" "allow_http" {
  name                        = "Allow-HTTP"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_subnet_network_security_group_association" "nsg_assoc" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# -------------------------
# PUBLIC IP
# -------------------------

resource "azurerm_public_ip" "public_ip" {
  name                = "nginx-public-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  allocation_method = "Static"
  sku               = "Standard"
}


# -------------------------
# NETWORK INTERFACE
# -------------------------
resource "azurerm_network_interface" "nic" {
  name                = "nginx-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.public_ip.id
  }
}

# -------------------------
# STORAGE FOR WEBSITE.ZIP
# -------------------------
resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false   # ✅ IMPORTANT
  numeric = true
  special = false
}

resource "azurerm_storage_account" "website" {
  name                     = "surajweb${random_string.suffix.result}"
  location                 = azurerm_resource_group.rg.location
  resource_group_name      = azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  #allow_blob_public_access = true
}

resource "azurerm_storage_container" "website" {
  name                  = "website"
  storage_account_name  = azurerm_storage_account.website.name
  container_access_type = "blob"
}

resource "azurerm_storage_blob" "website_zip" {
  name                   = "website.zip"
  storage_account_name   = azurerm_storage_account.website.name
  storage_container_name = azurerm_storage_container.website.name
  type                   = "Block"
  source                 = "${path.module}/website.zip"
}

# -------------------------
# LINUX VM (NGINX)
# -------------------------
resource "azurerm_linux_virtual_machine" "vm" {
  name                = "nginxserver"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = "Standard_D2s_v3"

  admin_username                  = "azureuser"
  admin_password                  = var.admin_password
  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.nic.id
  ]

  depends_on = [
    azurerm_storage_blob.website_zip
  ]

  custom_data = base64encode(<<EOF
#cloud-config
package_update: true
packages:
  - nginx
  - unzip

runcmd:
  - systemctl enable nginx
  - systemctl start nginx
  - rm -rf /var/www/html/*
  - cd /tmp
  - wget https://${azurerm_storage_account.website.name}.blob.core.windows.net/${azurerm_storage_container.website.name}/website.zip
  - unzip -o website.zip -d /var/www/html
  - chown -R www-data:www-data /var/www/html
  - chmod -R 755 /var/www/html
  - systemctl restart nginx
EOF
)

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts"
    version   = "latest"
  }
}

# -------------------------
# OUTPUTS
# -------------------------
output "public_ip" {
  description = "Public IP of the Azure VM"
  value       = azurerm_public_ip.public_ip.ip_address
}

output "nginx_url" {
  description = "Open this URL in your browser"
  value       = "http://${azurerm_public_ip.public_ip.ip_address}"
}
