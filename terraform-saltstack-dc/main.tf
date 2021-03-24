variable "pb_user" {
  description = "Username for basic authentication of API"
  default     = "benjamin.schmidt@profitbricks.com"
}

variable "pb_password" {
  description = "Password for basic authentication of API"
  default     = "<password>"
}

variable "console_password" {
  description = "Password for root user via console"
  default     = "<password>"
}

variable "ssh_public_keys" {
  description = "List of SSH keys to be added to the VMs"
  default     = [".ssh/id_rsa.pub",]
}

variable "ssh_private_key" {
  description = "Private SSH key to connect to VMs"
  default     = ".ssh/id_rsa"
}



provider "profitbricks" {
 username = "${var.pb_user}"
 password = "${var.pb_password}"
}

///////////////////////////////////////////////////////////
// Virtual Data Center
///////////////////////////////////////////////////////////

resource "profitbricks_datacenter" "dev-01" {
 name        = "dev-01"
 location    = "de/fra"
 description = "VDC managed by Terraform - do not edit manually"
}



///////////////////////////////////////////////////////////
// Public LAN
///////////////////////////////////////////////////////////

resource "profitbricks_lan" "public_lan" {
  datacenter_id = "${profitbricks_datacenter.dev-01.id}"
  public        = true
  name          = "publicLAN"
}

///////////////////////////////////////////////////////////
// DMZ LAN
///////////////////////////////////////////////////////////

resource "profitbricks_lan" "dmz_lan" {
  datacenter_id = "${profitbricks_datacenter.dev-01.id}"
  public        = false
  name          = "dmzLAN"
}

///////////////////////////////////////////////////////////
// Management  LAN
///////////////////////////////////////////////////////////

resource "profitbricks_lan" "mgm_lan" {
  datacenter_id = "${profitbricks_datacenter.dev-01.id}"
  public        = false
  name          = "mgmLAN"
}

///////////////////////////////////////////////////////////
// Data LAN
///////////////////////////////////////////////////////////

resource "profitbricks_lan" "data_lan" {
  datacenter_id = "${profitbricks_datacenter.dev-01.id}"
  public        = false
  name          = "dataLAN"
}




///////////////////////////////////////////////////////////
// Firewall
///////////////////////////////////////////////////////////

resource "profitbricks_server" "fw-01" {
  name              = "fw-01"
  datacenter_id     = "${profitbricks_datacenter.dev-01.id}"
  cores             = 2
  ram               = 2048
  cpu_family        = "AMD_OPTERON"
  availability_zone = "ZONE_1"

  volume {
    name              = "fw-01-system"
    image_name        = "3a0656d6-4d83-4d8d-acd1-62ec7b779b4b"
    size              = 10
    disk_type         = "HDD"
   availability_zone = "AUTO"
  }

  nic {
    name = "public"
    lan  = "${profitbricks_lan.public_lan.id}"
    dhcp = true
  }
}

///////////////////////////////////////////////////////////
// DMZ NIC fw-01
///////////////////////////////////////////////////////////

resource "profitbricks_nic" "fw-01_dmz_nic" {
  datacenter_id = "${profitbricks_datacenter.dev-01.id}"
  server_id     = "${profitbricks_server.fw-01.id}"
  lan           = "${profitbricks_lan.dmz_lan.id}"
  name          = "dmzNIC"
 dhcp          = true
}

///////////////////////////////////////////////////////////
// Data NIC fw-01
///////////////////////////////////////////////////////////

resource "profitbricks_nic" "fw-01_data_nic" {
  datacenter_id = "${profitbricks_datacenter.dev-01.id}"
  server_id     = "${profitbricks_server.fw-01.id}"
  lan           = "${profitbricks_lan.data_lan.id}"
  name          = "dataNIC"
 dhcp          = true
}

///////////////////////////////////////////////////////////
// Management NIC fw-01
///////////////////////////////////////////////////////////

resource "profitbricks_nic" "fw-01_mgm_nic" {
  datacenter_id = "${profitbricks_datacenter.dev-01.id}"
  server_id     = "${profitbricks_server.fw-01.id}"
  lan           = "${profitbricks_lan.mgm_lan.id}"
  name          = "mgmNIC"
 dhcp          = true
}





///////////////////////////////////////////////////////////
// Bastion server
///////////////////////////////////////////////////////////

resource "profitbricks_server" "bastion" {
  name              = "bastion"
  datacenter_id     = "${profitbricks_datacenter.dev-01.id}"
  cores             = 1
  ram               = 1024
  cpu_family        = "AMD_OPTERON"
  availability_zone = "ZONE_1"

  volume {
    name              = "bastion-system"
    image_name        = "centos:latest"
    size              = 5
    disk_type         = "HDD"
    availability_zone = "AUTO"
    ssh_key_path      = ["${var.ssh_public_keys}"]
   image_password    = "${var.console_password}"
  }

  nic {
    name = "public"
    lan  = "${profitbricks_lan.public_lan.id}"
    dhcp = true
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf",
      "sysctl -p",
      "firewall-cmd --permanent --direct --passthrough ipv4 -t nat -I POSTROUTING -o eth0 -j MASQUERADE",
      "firewall-cmd --permanent --direct --passthrough ipv4 -I FORWARD -i eth1 -j ACCEPT",
      "firewall-cmd --reload",
    ]

    connection {
      private_key = "${file(var.ssh_private_key)}"
      host        = "${profitbricks_server.bastion.primary_ip}"
      user        = "root"
    }
  }
}

///////////////////////////////////////////////////////////
// Private NIC bastion server
///////////////////////////////////////////////////////////

resource "profitbricks_nic" "bastion_mgm_nic" {
  datacenter_id = "${profitbricks_datacenter.dev-01.id}"
  server_id     = "${profitbricks_server.bastion.id}"
  lan           = "${profitbricks_lan.mgm_lan.id}"
  name          = "mgmNIC"
  dhcp          = true
}



//////////////////////////////////////////
// Salt Master
//////////////////////////////////////////

resource "profitbricks_server" "saltmaster" {
  depends_on        = ["profitbricks_nic.bastion_mgm_nic"]
  name              = "master"
  datacenter_id     = "${profitbricks_datacenter.dev-01.id}"
  cores             = 1
  ram               = 1024
  availability_zone = "ZONE_1"
  cpu_family        = "AMD_OPTERON"
  licence_type      = "LINUX"

  volume = [
    {
      name           = "salt-system"
      image_name     = "centos:latest"
      size           = 20
      disk_type      = "HDD"
      ssh_key_path   = ["${var.ssh_public_keys}"]
      image_password = "${var.console_password}"
      licence_type   = "LINUX"
    },
  ]

  nic = [
    {
      lan  = "${profitbricks_lan.mgm_lan.id}"
      dhcp = true
      name = "mgmNIC"
    },
  ]

  connection {
    private_key         = "${file(var.ssh_private_key)}"
    bastion_host        = "${profitbricks_server.bastion.primary_ip}"
    bastion_user        = "root"
    bastion_private_key = "${file(var.ssh_private_key)}"
    timeout             = "4m"
  }
}

///////////////////////////////////////////////////////////
// Salt master config
///////////////////////////////////////////////////////////
resource "null_resource" "saltmaster_config" {
  depends_on = ["profitbricks_server.saltmaster"]

  triggers = {
    saltmasterid = "${profitbricks_server.saltmaster.id}"
  }

  connection {
    private_key         = "${file(var.ssh_private_key)}"
    host                = "${profitbricks_server.saltmaster.primary_ip}"
    bastion_host        = "${profitbricks_server.bastion.primary_ip}"
    bastion_user        = "root"
    bastion_private_key = "${file(var.ssh_private_key)}"
    timeout             = "4m"
  }

 # add salt master to hosts file
 provisioner "local-exec" {
   command = "grep -q '${profitbricks_server.saltmaster.name}' salt/srv/salt/common/hosts && sed -i '' 's/^${profitbricks_server.saltmaster.primary_ip}.*/${profitbricks_server.saltmaster.primary_ip} ${profitbricks_server.saltmaster.name}/' salt/srv/salt/common/hosts || echo '${profitbricks_server.saltmaster.primary_ip} ${profitbricks_server.saltmaster.name}' >> salt/srv/salt/common/hosts"
 }

 # make the magic happen on salt master
 provisioner "remote-exec" {
   inline = [
     "echo master > /etc/hostname",
     "hostnamectl set-hostname master --static",
     "hostnamectl set-hostname master --pretty",
     "hostnamectl set-hostname master --transient",
     "echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf",
     "sysctl -p",

     "ip route add default via ${profitbricks_nic.bastion_mgm_nic.ips.0}",

     "echo 'supersede routers ${profitbricks_nic.bastion_mgm_nic.ips.0};' >> /etc/dhcp/dhclient.conf",
     "echo nameserver 8.8.8.8 > /etc/resolv.conf",
     "firewall-cmd --permanent --add-port=4505-4506/tcp",
     "firewall-cmd --reload",
     "echo -e  'y\n'| ssh-keygen -b 2048 -t rsa -P '' -f /root/.ssh/id_rsa -q",
     "wget -O /tmp/bootstrap-salt.sh https://bootstrap.saltstack.com",
     "sh /tmp/bootstrap-salt.sh -M -L -X -A master",
     "mkdir -p /etc/salt/pki/master/minions",
     "salt-key --gen-keys=minion --gen-keys-dir=/etc/salt/pki/minion",
     "cp /etc/salt/pki/minion/minion.pub /etc/salt/pki/master/minions/master",
     "mkdir /srv/salt",

     "systemctl start salt-master",
     "systemctl start salt-minion",
     "systemctl enable salt-master",
     "systemctl enable salt-minion",
     "sleep 10",
     "salt '*' test.ping",
   ]
 }




 //////////////////////////////////////////
 // Salt Config
 //////////////////////////////////////////
resource "null_resource" "salt" {
  depends_on = ["null_resource.saltmaster_config"]

  connection {
    private_key         = "${file(var.ssh_private_key)}"
    host                = "${profitbricks_server.saltmaster.primary_ip}"
    bastion_host        = "${profitbricks_server.bastion.primary_ip}"
    bastion_user        = "root"
    bastion_private_key = "${file(var.ssh_private_key)}"
   timeout             = "4m"
  }

  provisioner "local-exec" {
    command = "tar cvfz salt/srv_salt.tar.gz -C salt/srv/salt ."
  }

  provisioner "file" {
    source      = "salt/srv_salt.tar.gz"
    destination = "/srv/srv_salt.tar.gz"
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir /srv/salt_bak",
      "cp -R /srv/salt/* /srv/salt_bak || echo 'cannot perform backup'",
      "rm -r /srv/salt/*",
      "tar oxvfz /srv/srv_salt.tar.gz -C /srv/salt/",
     "salt '*' state.highstate",
    ]
  }
}




//////////////////////////////////////////
// Webserver
//////////////////////////////////////////

resource "profitbricks_server" "web" {
 depends_on        = ["null_resource.saltmaster_config","null_resource.salt"]
 count             = 2
 name              = "${format("web-%02d", count.index +1)}"
 datacenter_id     = "${profitbricks_datacenter.dev-01.id}"
 cores             = 1
 ram               = 1024
 availability_zone = "AUTO"
 cpu_family        = "AMD_OPTERON"
 licence_type      = "LINUX"

 volume = [
   {
     name           = "${format("web-%02d", count.index +1)}-system"
     image_name     = "centos:latest"
     size           = 20
     disk_type      = "HDD"
     ssh_key_path   = ["${var.ssh_public_keys}"]
     image_password = "${var.console_password}"
     licence_type   = "LINUX"
   },
 ]

 nic = [
   {
     lan  = "${profitbricks_lan.mgm_lan.id}"
     dhcp = true
     name = "mgmNIC"
   },
 ]

 connection {
   private_key         = "${file(var.ssh_private_key)}"
   bastion_host        = "${profitbricks_server.bastion.primary_ip}"
   bastion_user        = "root"
   bastion_private_key = "${file(var.ssh_private_key)}"
   timeout             = "4m"
 }
}

///////////////////////////////////////////////////////////
// DMZ NIC Webserver
///////////////////////////////////////////////////////////

resource "profitbricks_nic" "web_dmz_nic" {
 count         = "${profitbricks_server.web.count}"
 datacenter_id = "${profitbricks_datacenter.dev-01.id}"
 server_id     = "${element(profitbricks_server.web.*.id, count.index)}"
 lan           = "${profitbricks_lan.dmz_lan.id}"
 name          = "dmzNIC"
 dhcp          = true
}

///////////////////////////////////////////////////////////
// Webserver config
///////////////////////////////////////////////////////////
resource "null_resource" "web_config" {
 depends_on = ["profitbricks_nic.web_dmz_nic"]
 count      = "${profitbricks_server.web.count}"

 connection {
   private_key         = "${file(var.ssh_private_key)}"
   host                = "${element(profitbricks_server.web.*.primary_ip, count.index)}"
   bastion_host        = "${profitbricks_server.bastion.primary_ip}"
   bastion_user        = "root"
   bastion_private_key = "${file(var.ssh_private_key)}"
   timeout             = "4m"
 }

 # copy etc/hosts file to web server
 provisioner "file" {
   source      = "salt/srv/salt/common/hosts"
   destination = "/etc/hosts"
 }

 # make the magic happen on web server
 provisioner "remote-exec" {
   inline = [

     "echo ${format("web-%02d", count.index +1)} > /etc/hostname",
     "hostnamectl set-hostname ${format("web-%02d", count.index +1)} --static",
     "hostnamectl set-hostname ${format("web-%02d", count.index +1)} --pretty",
     "hostnamectl set-hostname ${format("web-%02d", count.index +1)} --transient",
     "ip route add default via ${profitbricks_nic.fw-01_dmz_nic.ips.0}",
     "echo 'supersede routers ${profitbricks_nic.fw-01_dmz_nic.ips.0};' >> /etc/dhcp/dhclient.conf",
     "echo nameserver 8.8.8.8 > /etc/resolv.conf",

     "echo -e  'y\n'| ssh-keygen -b 2048 -t rsa -P '' -f /root/.ssh/id_rsa -q",

     "wget -O /tmp/bootstrap-salt.sh https://bootstrap.saltstack.com",
     "sh /tmp/bootstrap-salt.sh -L -X -A ${profitbricks_server.saltmaster.primary_ip}",
     "echo '${format("web-%02d", count.index +1)}' > /etc/salt/minion_id",
     "systemctl restart salt-minion",
     "systemctl enable salt-minion",
   ]
 }
 # Accept minion key on master
 provisioner "remote-exec" {
   inline = [
     "salt-key -y -a ${element(profitbricks_server.web.*.name, count.index)}",
   ]

   connection {
     private_key         = "${file(var.ssh_private_key)}"
     host                = "${profitbricks_server.saltmaster.primary_ip}"
     bastion_host        = "${profitbricks_server.bastion.primary_ip}"
     bastion_user        = "root"
     bastion_private_key = "${file(var.ssh_private_key)}"
     timeout             = "4m"
   }
 }
 # Add or update web server host name to local hosts file
 provisioner "local-exec" {
   command = "grep -q '${element(profitbricks_server.web.*.name, count.index)}' salt/srv/salt/common/hosts && sed -i '' 's/^${element(profitbricks_server.web.*.primary_ip, count.index)}.*/${element(profitbricks_server.web.*.primary_ip, count.index)} ${element(profitbricks_server.web.*.name, count.index)}/' salt/srv/salt/common/hosts || echo '${element(profitbricks_server.web.*.primary_ip, count.index)} ${element(profitbricks_server.web.*.name, count.index)}' >> salt/srv/salt/common/hosts"
 }
 # delete minion key on master when destroying
 provisioner "remote-exec" {
   when = "destroy"

   inline = [
     "salt-key -y -d '${element(profitbricks_server.web.*.name, count.index)}*'",
   ]

   connection {
     private_key         = "${file(var.ssh_private_key)}"
     host                = "${profitbricks_server.saltmaster.primary_ip}"
     bastion_host        = "${profitbricks_server.bastion.primary_ip}"
     bastion_user        = "root"
     bastion_private_key = "${file(var.ssh_private_key)}"
     timeout             = "4m"
   }
 }

 # delete host from local hosts file when destroying
 provisioner "local-exec" {
   when    = "destroy"
   command = "sed -i '' '/${element(profitbricks_server.web.*.name, count.index)}/d' salt/srv/salt/common/hosts"
 }
}




#Database Server

//////////////////////////////////////////
// Database
//////////////////////////////////////////

resource "profitbricks_server" "db" {
 depends_on        = ["null_resource.saltmaster_config","null_resource.salt"]
 count             = 2
 name              = "${format("db-%02d", count.index +1)}"
 datacenter_id     = "${profitbricks_datacenter.dev-01.id}"
 cores             = 1
 ram               = 1024
 availability_zone = "AUTO"
 cpu_family        = "AMD_OPTERON"
 licence_type      = "LINUX"

 volume = [
   {
     name           = "${format("db-%02d", count.index +1)}-system"
     image_name     = "centos:latest"
     size           = 20
     disk_type      = "HDD"
     ssh_key_path   = ["${var.ssh_public_keys}"]
     image_password = "${var.console_password}"
     licence_type   = "LINUX"
   },
 ]

 nic = [
   {
     lan  = "${profitbricks_lan.mgm_lan.id}"
     dhcp = true
     name = "mgmNIC"
   },
 ]

 connection {
   private_key         = "${file(var.ssh_private_key)}"
   bastion_host        = "${profitbricks_server.bastion.primary_ip}"
   bastion_user        = "root"
   bastion_private_key = "${file(var.ssh_private_key)}"
   timeout             = "4m"
 }
}

///////////////////////////////////////////////////////////
// DMZ NIC Database
///////////////////////////////////////////////////////////

resource "profitbricks_nic" "db_data_nic" {
 count         = "${profitbricks_server.db.count}"
 datacenter_id = "${profitbricks_datacenter.dev-01.id}"
 server_id     = "${element(profitbricks_server.db.*.id, count.index)}"
 lan           = "${profitbricks_lan.data_lan.id}"
 name          = "dataNIC"
 dhcp          = true
}

///////////////////////////////////////////////////////////
// Database config
///////////////////////////////////////////////////////////
resource "null_resource" "db_config" {
 depends_on = ["profitbricks_nic.db_data_nic"]
 count      = "${profitbricks_server.db.count}"


 connection {
   private_key         = "${file(var.ssh_private_key)}"
   host                = "${element(profitbricks_server.db.*.primary_ip, count.index)}"
   bastion_host        = "${profitbricks_server.bastion.primary_ip}"
   bastion_user        = "root"
   bastion_private_key = "${file(var.ssh_private_key)}"
   timeout             = "4m"
 }

 # copy etc/hosts file to database server
 provisioner "file" {
   source      = "salt/srv/salt/common/hosts"
   destination = "/etc/hosts"
 }

 # make the magic happen on database server
 provisioner "remote-exec" {
   inline = [
     "echo ${format("db-%02d", count.index +1)} > /etc/hostname",
     "hostnamectl set-hostname ${format("db-%02d", count.index +1)} --static",
     "hostnamectl set-hostname ${format("db-%02d", count.index +1)} --pretty",
     "hostnamectl set-hostname ${format("db-%02d", count.index +1)} --transient",
     "ip route add default via ${profitbricks_nic.fw-01_data_nic.ips.0}",
     "echo 'supersede routers ${profitbricks_nic.fw-01_data_nic.ips.0};' >> /etc/dhcp/dhclient.conf",
     "echo nameserver 8.8.8.8 > /etc/resolv.conf",

     "echo -e  'y\n'| ssh-keygen -b 2048 -t rsa -P '' -f /root/.ssh/id_rsa -q",

     "wget -O /tmp/bootstrap-salt.sh https://bootstrap.saltstack.com",
     "sh /tmp/bootstrap-salt.sh -L -X -A ${profitbricks_server.saltmaster.primary_ip}",
     "echo '${format("db-%02d", count.index +1)}' > /etc/salt/minion_id",
     "systemctl restart salt-minion",
     "systemctl enable salt-minion",
   ]
 }
 # Accept minion key on master
 provisioner "remote-exec" {
   inline = [
     "salt-key -y -a ${element(profitbricks_server.db.*.name, count.index)}",
   ]

   connection {
     private_key         = "${file(var.ssh_private_key)}"
     host                = "${profitbricks_server.saltmaster.primary_ip}"
     bastion_host        = "${profitbricks_server.bastion.primary_ip}"
     bastion_user        = "root"
     bastion_private_key = "${file(var.ssh_private_key)}"
     timeout             = "4m"
   }
 }
 # Add or update database hostname to local hosts file
 provisioner "local-exec" {
   command = "grep -q '${element(profitbricks_server.db.*.name, count.index)}' salt/srv/salt/common/hosts && sed -i '' 's/^${element(profitbricks_server.db.*.primary_ip, count.index)}.*/${element(profitbricks_server.db.*.primary_ip, count.index)} ${element(profitbricks_server.db.*.name, count.index)}/' salt/srv/salt/common/hosts || echo '${element(profitbricks_server.db.*.primary_ip, count.index)} ${element(profitbricks_server.db.*.name, count.index)}' >> salt/srv/salt/common/hosts"
 }
 # delete minion key on master when destroying
 provisioner "remote-exec" {
   when = "destroy"

   inline = [
     "salt-key -y -d '${element(profitbricks_server.db.*.name, count.index)}*'",
   ]

   connection {
     private_key         = "${file(var.ssh_private_key)}"
     host                = "${profitbricks_server.saltmaster.primary_ip}"
     bastion_host        = "${profitbricks_server.bastion.primary_ip}"
     bastion_user        = "root"
     bastion_private_key = "${file(var.ssh_private_key)}"
     timeout             = "4m"
   }
 }

 # delete host from local hosts file when destroying
 provisioner "local-exec" {
   when    = "destroy"
   command = "sed -i '' '/${element(profitbricks_server.db.*.name, count.index)}/d' salt/srv/salt/common/hosts"
 }
}

#Top File

