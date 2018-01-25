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

# Command generates
class GenerateCommand < BaseCommand

  def self.quote(string)
    return '"'+string+'"'
  end

  def self.vagrantFileHeader
    vagrantFileHeader = <<-EOF
# !! Generated content, do not edit !!
# Generated by MariaDB Continuous Integration Tool (http://github.com/OSLL/mdbci)

    EOF
    vagrantFileHeader += "\n####  Created "
    vagrantFileHeader += DateTime.now.to_s
    vagrantFileHeader += " ####\n\n"
  end

  def self.awsProviderConfigImport(aws_config_file)
    <<-EOF
    ### Import AWS Provider access config ###
    require 'yaml'
    aws_config = YAML.load_file('#{File.expand_path(aws_config_file)}')['aws']
    ## End of import AWS Provider access config' ###
    EOF
  end

  def self.awsProviderConfig(pemfile_path, keypair_name)
    <<-EOF
    ###           AWS Provider config block                 ###
    ###########################################################
    config.vm.box = "dummy"

    config.vm.provider :aws do |aws, override|
      aws.keypair_name = "#{keypair_name}"
      aws.region = aws_config["region"]
      aws.security_groups = aws_config["security_groups"]
      aws.user_data = aws_config["user_data"]
      override.ssh.private_key_path = "#{pemfile_path}"
      override.nfs.functional = false
      aws.aws_profile = "mdbci"
    end ## of AWS Provider config block
    EOF
  end

  def self.providerConfig
    config = <<-EOF

### Default (VBox, Libvirt, Docker) Provider config ###
#######################################################
# Network autoconfiguration
config.vm.network "private_network", type: "dhcp"

config.vm.boot_timeout = 60
    EOF
  end

  def self.vagrantConfigHeader

    vagrantConfigHeader = <<-EOF

### Vagrant configuration block  ###
####################################
Vagrant.configure(2) do |config|

config.omnibus.chef_version = '12.9.38'
    EOF
  end

  def self.vagrantConfigFooter
    vagrantConfigFooter = "\nend   ## end of Vagrant configuration block\n"
  end

  def self.roleFileName(path, role)
    return path+'/'+role+'.json'
  end

  def self.vagrantFooter
    return "\nend # End of generated content"
  end

  def self.writeFile(name, content)
    IO.write(name, content)
  end

  def self.sshPtyOption(ssh_pty)
    ssh_pty_option = ''
    if ssh_pty == "true" || ssh_pty == "false";
      ssh_pty_option = "\tconfig.ssh.pty = " + ssh_pty
    end
    return ssh_pty_option
  end

  # Generate chef provision block for the VM
  #
  # @param name [String] name of the virtual machine
  # @param cookbook_path [String] path to the cookbooks to use
  # @param provisioned [Boolean] some bogus boolean variable
  #
  # @return [String] provision block for the VM
  def self.generate_provision_block(name, cookbook_path, provisioned)
    template = ERB.new <<-PROVISION
      ##--- Install chef on this machine with manual setup ---
      #{name}.vm.provision 'shell', inline: 'curl -L https://omnitruck.chef.io/install.sh | sudo bash -s -- -v 12.9.38'

      ##--- Chef configuration ----
      #{name}.vm.provision 'chef_solo' do |chef|
        chef.cookbooks_path = '#{cookbook_path}'
        chef.add_recipe 'mdbci_provision_mark::remove_mark'
        <% if provisioned %>
        chef.roles_path = '.'
        chef.add_role '#{name}'
        <% else %>
        chef.add_recipe 'packages'
        <% end %>
        chef.add_recipe 'mdbci_provision_mark'
        chef.synced_folder_type = 'rsync'
      end
      ##--- Chef configuration complete
PROVISION
    template.result(binding)
  end

  # Vagrantfile for Vbox provider
  def self.getVmDef(cookbook_path, name, host, boxurl, ssh_pty, vm_mem, template_path, provisioned)
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
        <%= generate_provision_block('box', cookbook_path, provisioned) %>
        box.vm.provider :virtualbox do |vbox|
          <% if vm_mem %>
             vbox.memory = <%= vm_mem %>
          <% end %>
          vbox.name = "\#{File.basename(File.dirname(__FILE__))}_<%= name %>"
        end
      end
    VBOX
    return template.result(binding)
  end

  # Vagrantfile for Libvirt provider
  def self.getQemuDef(cookbook_path, path, name, host, boxurl, ssh_pty, vm_mem, template_path, provisioned)
    if template_path
      templatedef = "\t"+name+'.vm.synced_folder '+quote(template_path)+", "+quote('/home/vagrant/cnf_templates') \
                    +", type:"+quote('rsync')
    else
      templatedef = ''
    end

    # ssh.pty option
    ssh_pty_option = sshPtyOption(ssh_pty)

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
    qemudef += generate_provision_block(name, cookbook_path, provisioned)
    qemudef += "\nend #  <-- End of Qemu definition for machine: " + name +"\n\n"
    return qemudef
  end

  # Vagrantfile for Docker provider + Dockerfiles
  def self.getDockerDef(cookbook_path, path, name, ssh_pty, template_path, provisioned, platform, platform_version, box)
    if template_path
      templatedef = "\t"+name+'.vm.synced_folder '+quote(template_path)+", "+quote("/home/vagrant/cnf_templates")
    else
      templatedef = ""
    end
    # ssh.pty option
    ssh_pty_option = sshPtyOption(ssh_pty)


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

    dockerdef += generate_provision_block(name, cookbook_path, provisioned)
    dockerdef += "\nend #  <-- End of Docker definition for machine: " + name +"\n\n"

    return dockerdef
  end

  # generate snapshot versioning
  def self.createDockerSnapshotsVersions(path, name, box)
    File.open("#{path}/#{name}/snapshots", 'w') do |f|
      f.puts({name => {'id' => SecureRandom.uuid.to_s.downcase, 'snapshots' => [box], 'current_snapshot' => box, 'initial_snapshot' => box}}.to_json)
    end
  end

  # generate Dockerfiles
  def self.copyDockerfiles(path, name, platform, platform_version)
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
    `sed -i 's/###PLATFORM###/#{platform}/g' #{node_path}/Dockerfile`
    `sed -i 's/###PLATFORM_VERSION###/#{platform_version}/g' #{node_path}/Dockerfile`
  end

  def self.generateAwsTag(hash)
    hashes_array = Array.new
    hash.each { |key, value| hashes_array.push ("#{quote(key)} => #{quote(value)}") }
    vagrantfile_tags = hashes_array.join(', ')
    return "{ #{vagrantfile_tags} }"
  end

  #  Vagrantfile for AWS provider
  def self.getAWSVmDef(cookbook_path, name, boxurl, user, ssh_pty, instance_type, template_path, provisioned, tags)

    if template_path
      mountdef = "\t" + name + ".vm.synced_folder " + quote(template_path) + ", " + quote("/home/vagrant/cnf_templates") + ", type: " + quote("rsync")
    else
      mountdef = ''
    end
    # ssh.pty option
    ssh_pty_option = sshPtyOption(ssh_pty)

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
    awsdef += generate_provision_block(name, cookbook_path, provisioned)

    awsdef +="\nend #  <-- End AWS definition for machine: " + name +"\n\n"

    return awsdef
  end


  def self.getRoleDef(name, product, box)

    errorMock = "#NONE, due invalid repo name \n"
    role = Hash.new
    productConfig = Hash.new
    product_name = nil
    repoName = nil
    repo = nil

    if !product['repo'].nil?

      repoName = product['repo']

      $out.info "Repo name: "+repoName

      unless $session.repos.knownRepo?(repoName)
        $out.warning 'Unknown key for repo '+repoName+' will be skipped'
        return errorMock
      end

      $out.info 'Repo specified ['+repoName.to_s+'] (CORRECT), other product params will be ignored'
      repo = $session.repos.getRepo(repoName)

      product_name = $session.repos.productName(repoName)
    else
      product_name = product['name']
    end

    # TODO: implement support of multiple recipes in role file
    if product_name != 'packages'
      recipe_name = $session.repos.recipeName(product_name)

      $out.info 'Recipe '+recipe_name.to_s

      if repo.nil?
        repo = $session.repos.findRepo(product_name, product, box)
      end

      if repo.nil?
        return errorMock
      end

      config = Hash.new
      # edit recipe attributes in role
      config['version'] = repo['version']
      config['repo'] = repo['repo']
      config['repo_key'] = repo['repo_key']
      if !product['cnf_template'].nil? && !product['cnf_template_path'].nil?
        config['cnf_template'] = product['cnf_template']
        config['cnf_template_path'] = product['cnf_template_path']
      end
      if !product['node_name'].nil?
        config['node_name'] = product['node_name']
      end
      productConfig[product_name] = config

      role['name'] = name
      role['default_attributes'] = {}
      role['override_attributes'] = productConfig
      role['json_class'] = 'Chef::Role'
      role['description'] = 'MariaDb instance install and run'
      role['chef_type'] = 'role'
      role['run_list'] = ['recipe['+recipe_name+']']
    else
      recipe_name = $session.repos.recipeName(product_name)
      $out.info 'Recipe '+recipe_name.to_s

      role['name'] = name
      role['default_attributes'] = {}
      role['override_attributes'] = {}
      role['json_class'] = 'Chef::Role'
      role['description'] = 'packages recipe for all nodes'
      role['chef_type'] = 'role'
      role['run_list'] = ['recipe['+recipe_name+']']
    end

    roledef = JSON.pretty_generate(role)

    return roledef

    #todo uncomment
    if false

      # TODO: form string for several box recipes for maridb, maxscale, mysql

      roledef = '{ '+"\n"+' "name" :' + quote(name)+",\n"+ \
        <<-EOF
        "default_attributes": { },
      EOF

      roledef += " #{quote('override_attributes')}: { #{quote(package)}: #{mdbversion} },\n"

      roledef += <<-EOF
        "json_class": "Chef::Role",
        "description": "MariaDb instance install and run",
        "chef_type": "role",
      EOF
      roledef += quote('run_list') + ": [ " + quote("recipe[" + recipe_name + "]") + " ]\n"
      roledef += "}"
    end

  end

  def self.checkPath(path, override)
    if Dir.exist?(path) && !override
      $out.error 'Folder already exists: ' + path
      $out.error 'Please specify another name or delete'
      exit -1
    end
    FileUtils.rm_rf(path)
    Dir.mkdir(path)
  end

  def self.boxValid?(box, boxes)
    if !box.empty?
      !boxes.getBox(box).nil?
    end
  end

  def self.nodeDefinition(node, boxes, path, cookbook_path)

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
    if boxValid?(box, boxes)
      case provider
        when 'virtualbox'
          machine = getVmDef(cookbook_path, name, host, boxurl, ssh_pty, vm_mem, template_path, provisioned)
        when 'aws'
          tags = generateAwsTag({
                                    'hostname' => Socket.gethostname,
                                    'username' => Etc.getlogin,
                                    'full_config_path' => File.expand_path(path),
                                    'machinename' => name
                                })
          machine = getAWSVmDef(cookbook_path, name, amiurl, user, ssh_pty, instance, template_path, provisioned, tags)
        when 'libvirt'
          machine = getQemuDef(cookbook_path, path, name, host, boxurl, ssh_pty, vm_mem, template_path, provisioned)
        when 'docker'
          machine = getDockerDef(cookbook_path, path, name, ssh_pty, template_path, provisioned, platform, platform_version, box)
          copyDockerfiles(path, name, platform, platform_version)
          createDockerSnapshotsVersions(path, name, box)
        else
          $out.warning 'Configuration type invalid! It must be vbox, aws, libvirt or docker type. Check it, please!'
      end
    else
      $out.warning 'Box '+box+'is not installed or configured ->SKIPPING'
    end

    # box with mariadb, maxscale provision - create role
    if provisioned
      $out.info 'Machine '+name+' is provisioned by '+product.to_s
      role = getRoleDef(name, product, box)
      IO.write(roleFileName(path, name), role)
    end

    return machine
  end

  def self.generateKeypair(path)
    hostname = Socket.gethostname
    keypair_name = Pathname(File.expand_path(path)).basename
    aws_cmd_output = `aws --profile mdbci ec2 create-key-pair --key-name #{hostname}_#{keypair_name}_#{Time.new.to_i}`
    raise "AWS CLI command exited with non zero exit code: #{$?.exitstatus}" unless $?.success?
    aws_json_credential = JSON.parse(aws_cmd_output)
    keypair_name = aws_json_credential["KeyName"]
    path_to_keyfile = File.join(File.expand_path(path), 'maxscale.pem')
    open(path_to_keyfile, 'w') do |f|
      f.write(aws_json_credential["KeyMaterial"])
    end
    path_to_keypair_file = File.join(File.expand_path(path), Configuration::AWS_KEYPAIR_NAME)
    open(path_to_keypair_file, 'w') do |f|
      f.write(keypair_name)
    end
    return path_to_keyfile, keypair_name
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
    checkPath(path, override)
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
    vagrant.puts vagrantFileHeader

    if (!$session.awsConfigOption.to_s.empty? && provider=='aws')
      # Generate AWS Configuration
      $out.info 'Generating AWS configuration'
      vagrant.puts awsProviderConfigImport($session.awsConfigOption)
      vagrant.puts vagrantConfigHeader
      path_to_keyfile, keypair_name = generateKeypair path
      vagrant.puts awsProviderConfig(path_to_keyfile, keypair_name)
    else
      # Generate VBox/Qemu Configuration
      $out.info 'Generating libvirt/VirtualBox/Docker configuration'
      vagrant.puts vagrantConfigHeader
      vagrant.puts providerConfig
    end
    config.each do |node|
      unless (node[1]['box'].nil?)
        $out.info 'Generating node definition for ['+node[0]+']'
        vagrant.puts nodeDefinition(node, boxes, path, cookbook_path)
      end
    end
    vagrant.puts vagrantConfigFooter
    vagrant.close

    if File.size?(path+'/Vagrantfile').nil? # nil if empty and not exist
      raise 'Generated Vagrantfile is empty! Please check configuration file and regenerate it.'
    end
    return 0
  end
end
