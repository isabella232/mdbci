# frozen_string_literal: true

require 'date'
require 'fileutils'
require 'json'
require 'pathname'
require 'securerandom'
require 'socket'
require 'erb'
require 'set'
require_relative 'base_command'
require_relative '../out'
require_relative '../models/configuration.rb'
require_relative '../services/shell_commands'

# Command generates
class GenerateCommand < BaseCommand
  def self.synopsis
    'Generate a configuration based on the template.'
  end

  def self.quote(string)
    "\"#{string}\""
  end

  def self.vagrant_file_header
    <<-HEADER
# !! Generated content, do not edit !!
# Generated by MariaDB Continuous Integration Tool (https://github.com/mariadb-corporation/mdbci)
#### Created #{Time.now} ####
HEADER
  end

  def self.aws_provider_config(aws_config, pemfile_path, keypair_name)
    <<-PROVIDER
    ###           AWS Provider config block                 ###
    ###########################################################
    config.vm.box = "dummy"

    config.vm.provider :aws do |aws, override|
      aws.keypair_name = "#{keypair_name}"
      override.ssh.private_key_path = "#{pemfile_path}"
      aws.region = "#{aws_config['region']}"
      aws.security_groups = #{aws_config['security_groups']}
      aws.access_key_id = "#{aws_config['access_key_id']}"
      aws.secret_access_key = "#{aws_config['secret_access_key']}"
      aws.user_data = "#!/bin/bash\nsed -i -e 's/^Defaults.*requiretty/# Defaults requiretty/g' /etc/sudoers"
      override.nfs.functional = false
    end ## of AWS Provider config block
    PROVIDER
  end

  def self.provider_config
    <<-CONFIG
### Default (VBox, Libvirt, Docker) Provider config ###
#######################################################
# Network autoconfiguration
config.vm.network "private_network", type: "dhcp"
config.vm.boot_timeout = 60
    CONFIG
  end

  def self.vagrant_config_header
    <<-HEADER
### Vagrant configuration block  ###
####################################
Vagrant.configure(2) do |config|
    HEADER
  end

  def self.vagrant_config_footer
    <<-FOOTER
end
### end of Vagrant configuration block
    FOOTER
  end

  def self.role_file_name(path, role)
    "#{path}/#{role}.json"
  end

  def self.node_config_file_name(path, role)
    "#{path}/#{role}-config.json"
  end

  def self.ssh_pty_option(ssh_pty)
    if %w[true false].include?(ssh_pty)
      "config.ssh.pty = #{ssh_pty}"
    else
      ''
    end
  end

  # Vagrantfile for Vbox provider
  def self.get_virtualbox_definition(cookbook_path, name, host, boxurl, ssh_pty, vm_mem, template_path, provisioned)
    template = ERB.new <<-VBOX
      config.vm.define '<%= name %>' do |box|
        box.vm.box = '<%= boxurl %>'
        box.vm.hostname = '<%= host %>'
        <% if ssh_pty %>
           box.ssh.pty = true
        <% end %>
        <% if template_path %>
           box.vm.synced_folder '<%= template_path %>', '/home/vagrant/cnf_templates'
        <% end %>
        box.vm.provider :virtualbox do |vbox|
          <% if vm_mem %>
             vbox.memory = <%= vm_mem %>
          <% end %>
          vbox.name = "\#{File.basename(File.dirname(__FILE__))}_<%= name %>"
        end
      end
    VBOX
    template.result(binding)
  end

  # Vagrantfile for Libvirt provider
  def self.get_libvirt_definition(_cookbook_path, path, name, host, boxurl, ssh_pty, vm_mem, template_path, _provisioned)
    templatedef = if template_path
                    "\t"+name+'.vm.synced_folder '+quote(template_path)+", "+quote('/home/vagrant/cnf_templates') \
                    +", type:"+quote('rsync')
                  else
                    ''
                  end
    # ssh.pty option
    ssh_pty_option = ssh_pty_option(ssh_pty)
    network_conf = ""
    if $session.ipv6
      network_conf = "\t"+name+'.vm.network :public_network, :dev => "virbr0", :mode => "bridge", :type => "bridge"' + "\n"
    end
    qemudef = "\n#  --> Begin definition for machine: " + name +"\n"\
            + "\n"+'config.vm.define ' + quote(name) +' do |'+ name +"|\n" \
            + ssh_pty_option + "\n" \
            + network_conf \
            + "\t"+name+'.vm.box = ' + quote(boxurl) + "\n" \
            + "\t"+name+'.vm.hostname = ' + quote(host) + "\n" \
            + "\t"+name+'.vm.synced_folder '+quote(File.expand_path(path))+", "+quote('/vagrant')+", type: "+quote('rsync')+"\n" \
            + templatedef + "\n"\
            + "\t"+name+'.vm.provider :libvirt do |qemu|' + "\n" \
            + "\t\t"+'qemu.driver = ' + quote('kvm') + "\n" \
            + "\t\t"+'qemu.memory = ' + vm_mem + "\n\tend"
    qemudef += "\nend #  <-- End of Qemu definition for machine: " + name +"\n\n"
    return qemudef
  end

  # Vagrantfile for Docker provider + Dockerfiles
  def self.get_docker_definition(cookbook_path, path, name, ssh_pty, template_path, provisioned, platform, platform_version, box)
    if template_path
      templatedef = "\t"+name+'.vm.synced_folder '+quote(template_path)+", "+quote("/home/vagrant/cnf_templates")
    else
      templatedef = ""
    end
    # ssh.pty option
    ssh_pty_option = ssh_pty_option(ssh_pty)
    dockerdef = "\n#  --> Begin definition for machine: " + name +"\n"\
            + "\n"+'config.vm.define ' + quote(name) +' do |'+ name +"|\n" \
            + ssh_pty_option + "\n" \
            + templatedef + "\n" \
            + "\t"+name+'.vm.provider "docker" do |d|' + "\n" \
            + "\t\t"+'d.image = ' + "JSON.parse(File.read('#{path}/#{name}/snapshots'))['#{name}']['current_snapshot']" + "\n" \
            + "\t\t"+'d.privileged = true' + "\n "\
            + "\t\t"+'d.has_ssh = true' + "\n"
    if platform == "centos" or platform == "redhat"
      dockerdef = dockerdef + "\t\t"+'d.privileged = true' + "\n "\
              + "\t\t"+'d.create_args = ["-v", "/sys/fs/cgroup:/sys/fs/cgroup"]' + "\n"
      if platform_version == "7"
        dockerdef = dockerdef + "\t\t"+'d.cmd = ["/usr/sbin/init"]' + "\n"
      end
    end
    dockerdef = dockerdef+ "\t\t"+'d.env = {"container"=>"docker"}' + "\n\tend"
    dockerdef += "\nend #  <-- End of Docker definition for machine: " + name +"\n\n"
    return dockerdef
  end

  # generate snapshot versioning
  def self.create_docker_snapshot_versions(path, name, box)
    File.open("#{path}/#{name}/snapshots", 'w') do |f|
      f.puts({name => {'id' => SecureRandom.uuid.to_s.downcase, 'snapshots' => [box], 'current_snapshot' => box, 'initial_snapshot' => box}}.to_json)
    end
  end

  # generate Dockerfiles
  def self.generate_dockerfiles(path, name, platform, platform_version)
    # dir for Dockerfile
    node_path = path + "/" + name
    if Dir.exist?(node_path)
      $out.error "Folder already exists: " + node_path
    elsif
      #FileUtils.rm_rf(node_path)
    Dir.mkdir(node_path)
    end
    # TODO: make other solution, avoid multi IF
    # copy Dockerfiles to configuration dir nodes
    dockerfile_path = $session.mdbciDir+"/templates/dockerfiles"
    case platform
      when "ubuntu", "debian"
        dockerfile_path = "#{dockerfile_path}/apt/Dockerfile"
      when "centos", "redhat"
        dockerfile_path = "#{dockerfile_path}/yum/Dockerfile"
      when "suse"
        dockerfile_path = "#{dockerfile_path}/zypper/Dockerfile"
      else
        raise "Uncknown platform"
    end
    FileUtils.cp_r dockerfile_path, node_path
    ShellCommands.run_command($out, "sed -i 's/###PLATFORM###/#{platform}/g' #{node_path}/Dockerfile")
    ShellCommands.run_command($out, "sed -i 's/###PLATFORM_VERSION###/#{platform_version}/g' #{node_path}/Dockerfile")
  end

  def self.generate_aws_tag(hash)
    hashes_array = Array.new
    hash.each { |key, value| hashes_array.push ("#{quote(key)} => #{quote(value)}") }
    vagrantfile_tags = hashes_array.join(', ')
    return "{ #{vagrantfile_tags} }"
  end

  #  Vagrantfile for AWS provider
  def self.get_aws_vms_definition(cookbook_path, name, boxurl, user, ssh_pty, instance_type, template_path, provisioned, tags)
    if template_path
      mountdef = "\t" + name + ".vm.synced_folder " + quote(template_path) + ", " + quote("/home/vagrant/cnf_templates") + ", type: " + quote("rsync")
    else
      mountdef = ''
    end
    # ssh.pty option
    ssh_pty_option = ssh_pty_option(ssh_pty)
    awsdef = "\n#  --> Begin definition for machine: " + name +"\n"\
           + "config.vm.define :"+ name +" do |" + name + "|\n" \
           + ssh_pty_option + "\n" \
           + "\t" + name + ".vm.provider :aws do |aws,override|\n" \
           + "\t\taws.ami = " + quote(boxurl) + "\n"\
           + "\t\taws.tags = #{tags}\n"\
           + "\t\taws.instance_type = " + quote(instance_type) + "\n" \
           + "\t\toverride.ssh.username = " + quote(user) + "\n" \
           + "\tend\n" \
           + mountdef + "\n"
    awsdef +="\nend #  <-- End AWS definition for machine: " + name +"\n\n"
    return awsdef
  end

  # Generate the rode description for the specified node
  # @param name [String] internal name of the machine specified in the template
  # @param product [Hash] parameters of the product to configure
  # @param box information about the box
  # @return [String] pretty formated role description in JSON format
  def self.get_role_description(name, product, box)
    error_text = "#NONE, due invalid repo name \n"
    role = {}
    product_config = {}
    repo = nil
    if !product['repo'].nil?
      repo_name = product['repo']
      $out.info("Repo name: #{repo_name}")
      unless $session.repos.knownRepo?(repo_name)
        $out.warning("Unknown key for repo #{repoName} will be skipped")
        return error_text
      end
      $out.info("Repo specified [#{repo_name}] (CORRECT), other product params will be ignored")
      repo = $session.repos.getRepo(repo_name)
      product_name = $session.repos.productName(repo_name)
    else
      product_name = product['name']
    end
    recipe_name = $session.repos.recipe_name(product_name)
    if product_name != 'packages'
      if repo.nil?
        repo = $session.repos.findRepo(product_name, product, box)
      end
      if repo.nil?
        return error_text
      end
      config = {
        'version' => repo['version'],
        'repo' => repo['repo'],
        'repo_key' => repo['repo_key']
      }
      if !product['cnf_template'].nil? && !product['cnf_template_path'].nil?
        config['cnf_template'] = product['cnf_template']
        config['cnf_template_path'] = product['cnf_template_path']
      end
      if !product['node_name'].nil?
        config['node_name'] = product['node_name']
      end
      attribute_name = $session.repos.attribute_name(product_name)
      product_config[attribute_name] = config
    end
    $out.info("Recipe #{recipe_name}")
    role['name'] = name
    role['default_attributes'] = {}
    role['override_attributes'] = product_config
    role['json_class'] = 'Chef::Role'
    role['description'] = ''
    role['chef_type'] = 'role'
    role['run_list'] = ['recipe[mdbci_provision_mark::remove_mark]',
                        "recipe[#{recipe_name}]",
                        'recipe[mdbci_provision_mark::default]']
    JSON.pretty_generate(role)
  end

  def self.check_path(path, override)
    if Dir.exist?(path) && !override
      $out.error 'Folder already exists: ' + path
      $out.error 'Please specify another name or delete'
      exit(-1)
    end
    FileUtils.rm_rf(path)
    Dir.mkdir(path)
  end

  def self.box_valid?(box, boxes)
    if !box.empty?
      !boxes.getBox(box).nil?
    end
  end

  def self.node_definition(node, boxes, path, cookbook_path)
    vm_mem = node[1]['memory_size'].nil? ? '1024' : node[1]['memory_size'].to_s
    # cookbook path dir
    if node[0]['cookbook_path']
      cookbook_path = node[1].to_s
    end
    # configuration parameters
    name = node[0].to_s
    host = node[1]['hostname'].to_s
    $out.info 'Requested memory ' + vm_mem
    box = node[1]['box'].to_s
    if !box.empty?
      box_params = boxes.getBox(box)
      provider = box_params['provider'].to_s
      case provider
        when 'aws'
          amiurl = box_params['ami'].to_s
          user = box_params['user'].to_s
          instance = box_params['default_instance_type'].to_s
          $out.info 'AWS definition for host:'+host+', ami:'+amiurl+', user:'+user+', instance:'+instance
        when 'mdbci'
          box_params.each do |key, value|
            $session.nodes[key] = value
          end
          $out.info 'MDBCI definition for host:'+host+', with parameters: ' + $session.nodes.to_s
        else
          boxurl = box_params['box'].to_s
          platform = box_params['platform'].to_s
          platform_version = box_params['platform_version'].to_s
      end
      # ssh_pty option
      if !box_params['ssh_pty'].nil?
        ssh_pty = box_params['ssh_pty'] == 'true'
        $out.info 'config.ssh.pty option is ' + ssh_pty.to_s + ' for a box ' + box.to_s
      end
    end
    provisioned = !node[1]['product'].nil?
    if (provisioned)
      product = node[1]['product']
      if !product['cnf_template_path'].nil?
        template_path = product['cnf_template_path']
      end
    end
    # generate node definition and role
    machine = ''
    if box_valid?(box, boxes)
      case provider
        when 'virtualbox'
          machine = get_virtualbox_definition(cookbook_path, name, host, boxurl, ssh_pty, vm_mem, template_path, provisioned)
        when 'aws'
          tags = generate_aws_tag({
                                    'hostname' => Socket.gethostname,
                                    'username' => Etc.getlogin,
                                    'full_config_path' => File.expand_path(path),
                                    'machinename' => name
                                })
          machine = get_aws_vms_definition(cookbook_path, name, amiurl, user, ssh_pty, instance, template_path, provisioned, tags)
        when 'libvirt'
          machine = get_libvirt_definition(cookbook_path, path, name, host, boxurl, ssh_pty, vm_mem, template_path, provisioned)
        when 'docker'
          machine = get_docker_definition(cookbook_path, path, name, ssh_pty, template_path, provisioned, platform, platform_version, box)
          generate_dockerfiles(path, name, platform, platform_version)
          create_docker_snapshot_versions(path, name, box)
        else
          $out.warning 'Configuration type invalid! It must be vbox, aws, libvirt or docker type. Check it, please!'
      end
    else
      $out.warning 'Box '+box+'is not installed or configured ->SKIPPING'
    end
    # box with mariadb, maxscale provision - create role
    if !provisioned
      product = { 'name' => 'packages' }
    end
    $out.info 'Machine '+name+' is provisioned by '+product.to_s
    role = get_role_description(name, product, box)
    IO.write(role_file_name(path, name), role)
    IO.write(node_config_file_name(path, name),
             JSON.pretty_generate({
                                    'run_list' => ["role[#{name}]"]
                                  }))
    return machine
  end

  def self.generate_key_pair(path)
    full_path = File.expand_path(path)
    key_pair = $session.aws_service.generate_key_pair(full_path)
    path_to_keyfile = File.join(full_path, 'maxscale.pem')
    File.write(path_to_keyfile, key_pair.key_material)
    path_to_keypair_file = File.join(full_path, Configuration::AWS_KEYPAIR_NAME)
    File.write(path_to_keypair_file, key_pair.key_name)
    return path_to_keyfile, key_pair.key_name
  end

  # Check that all boxes specified in the the template are identical.
  #
  # @param nodes [Array] list of nodes specified in template
  # @param boxes a list of boxes known to the configuration
  # @raise RuntimeError if there is the error in the configuration.
  def self.check_provider_equality(nodes, boxes)
    $out.info 'Checking node provider equality'
    providers = nodes.map do |node|
      node[1]['box'].to_s
    end.reject do |box|
      box.empty?
    end.map do |box|
      boxes.getBox(box)['provider'].to_s
    end
    if providers.empty?
      raise 'Unable to detect the provider for all boxes. Please fix the template.'
    end
    unique_providers = Set.new(providers)
    if unique_providers.size != 1
      raise "There are several node providers defined in the template: #{unique_providers.to_a.join(', ')}.\n"\
            "You can specify only nodes from one provider in the template."
    end
  end

  def self.generate(path, config, boxes, override, provider)
    #TODO MariaDb Version Validator
    check_path(path, override)
    check_provider_equality(config, boxes)
    cookbook_path = $mdbci_exec_dir + '/recipes/cookbooks/' # default cookbook path
    $out.info  cookbook_path
    unless (config['cookbook_path'].nil?)
      cookbook_path = config['cookbook_path']
    end
    $out.info 'Global cookbook_path = ' + cookbook_path
    $out.info 'Nodes provider = ' + provider
    vagrant = File.open(path+'/Vagrantfile', 'w')
    if provider == 'docker'
      vagrant.puts 'require \'json\''
    end
    vagrant.puts vagrant_file_header
    if (provider=='aws')
      # Generate AWS Configuration
      $out.info 'Generating AWS configuration'
      vagrant.puts vagrant_config_header
      path_to_keyfile, keypair_name = generate_key_pair path
      vagrant.puts aws_provider_config($session.tool_config['aws'], path_to_keyfile, keypair_name)
    else
      # Generate VBox/Qemu Configuration
      $out.info 'Generating libvirt/VirtualBox/Docker configuration'
      vagrant.puts vagrant_config_header
      vagrant.puts provider_config
    end
    config.each do |node|
      unless (node[1]['box'].nil?)
        $out.info 'Generating node definition for ['+node[0]+']'
        vagrant.puts node_definition(node, boxes, path, cookbook_path)
      end
    end
    vagrant.puts vagrant_config_footer
    vagrant.close
    if File.size?(path+'/Vagrantfile').nil? # nil if empty and not exist
      raise 'Generated Vagrantfile is empty! Please check configuration file and regenerate it.'
    end
    SUCCESS_RESULT
  end
end
