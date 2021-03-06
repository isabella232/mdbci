if node.attribute?('galera_3_enterprise') || node.attribute?('galera_4_enterprise')
  include_recipe "galera_ci::galera_repository"
else
  include_recipe "mariadb::galerarepos"
end
include_recipe "mariadb::mdberepos"
include_recipe "chrony::default"

# Turn off SElinux
if node[:platform] == "centos" and node["platform_version"].to_f >= 6.0
  # TODO: centos7 don't have selinux
  bash 'Turn off SElinux on CentOS >= 6.0' do
    code <<-EOF
    selinuxenabled && flag=enabled || flag=disabled
    if [[ $flag == 'enabled' ]];
    then
      /usr/sbin/setenforce 0
    else
      echo "SElinux already disabled!"
    fi
    EOF
  end

  cookbook_file 'selinux.config' do
    path "/etc/selinux/config"
    action :create
  end
end  # Turn off SElinux

# Remove mysql-libs
package 'mysql-libs' do
  action :remove
end

system 'echo Platform family: '+node[:platform_family]

# check and install iptables
case node[:platform_family]
  when "debian", "ubuntu"
    execute "Install iptables-persistent" do
      command "DEBIAN_FRONTEND=noninteractive apt-get -y install iptables-persistent"
    end
  when "rhel", "fedora", "centos"
    if %w[centos redhat].include?(node[:platform]) && node["platform_version"].to_f >= 7.0
      bash 'Install and configure iptables' do
      code <<-EOF
        yum --assumeyes install iptables-services
        systemctl start iptables
        systemctl enable iptables
      EOF
      end
    else
      bash 'Configure iptables' do
      code <<-EOF
        /sbin/service start iptables
        chkconfig iptables on
      EOF
      end
    end
  when "suse"
    package 'iptables'
end

# iptables rules
case node[:platform_family]
  when "debian", "ubuntu", "rhel", "fedora", "centos", "suse"
    execute "Opening MariaDB ports" do
      command "iptables -I INPUT -p tcp -m tcp --dport 3306 -j ACCEPT"
      command "iptables -I INPUT -p tcp --dport 3306 -j ACCEPT -m state --state ESTABLISHED,NEW"
    end
end # iptables rules

# TODO: check saving iptables rules after reboot
# save iptables rules
case node[:platform_family]
  when "debian", "ubuntu"
    execute "Save MariaDB iptables rules" do
      command "iptables-save > /etc/iptables/rules.v4"
      #command "/usr/sbin/service iptables-persistent save"
    end
  when "rhel", "centos", "fedora"
    execute "Save MariaDB iptables rules" do
      command "/sbin/service iptables save"
    end
    # service iptables restart
  when "suse"
    execute "Save MariaDB iptables rules" do
      command "iptables-save > /etc/sysconfig/iptables"
    end
end # save iptables rules

# Install packages
case node[:platform_family]
when "suse"
  execute "install" do
    command "zypper -n install --from mariadb MariaDB-server MariaDB-client"
  end
when "debian"
  package %w[mariadb-server mariadb-client] do
    action :upgrade
  end
when "windows"
  windows_package "MariaDB" do
    source "#{Chef::Config[:file_cache_path]}/mariadb.msi"
    installer_type :msi
    action :install
  end
else
  package %w[MariaDB-server MariaDB-client] do
    action :upgrade
  end
end

# Copy server.cnf configuration file to configuration
case node[:platform_family]
when 'debian', 'ubuntu'
  db_config_dir = '/etc/mysql/my.cnf.d/'
  db_base_config = '/etc/mysql/my.cnf'
when 'rhel', 'fedora', 'centos', 'suse', 'opensuse'
  db_config_dir = '/etc/my.cnf.d/'
  db_base_config = '/etc/my.cnf'
end

directory db_config_dir do
  owner 'root'
  group 'root'
  recursive true
  mode '0755'
  action :create
end

unless node['mariadb']['cnf_template'].nil?
  configuration_file = File.join(db_config_dir, node['mariadb']['cnf_template'])
  cookbook_file configuration_file do
    source node['mariadb']['cnf_template']
    action :create
    owner 'root'
    group 'root'
    mode '0644'
  end
end

# add !includedir to my.cnf
if node['mariadb']['version'] == '5.1'
  execute 'Add my.cnf.d directory for old MySQL version' do
    command <<-COMMAND
    echo "\n[client-server]\n!includedir #{db_config_dir}" >> #{db_base_config}
    COMMAND
  end
else
  execute 'Add my.cnf.d directory to the base mysql configuration file' do
    command "echo '\n!includedir #{db_config_dir}' >> #{db_base_config}"
  end
end

# Starts service
if platform?('redhat') && node[:platform_version].to_i == 6
  service "mysql" do
    action :start
  end
else
  service "mariadb" do
    action :start
  end
end
