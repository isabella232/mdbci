require_relative '../models/network_config_file'
require_relative '../services/machine_configurator'
require_relative '../network'
require 'net/ssh'

# rubocop:disable Metrics/MethodLength
class ConfigureNetworkCommand
  
  def initialize(args, keyFile, labels, out)
    @args = args
    @keyFile = keyFile
    @labels = labels
    @out = out
  end
  
  # copy ssh keys to config/node
  def execute
    raise 'Configuration name is required' if @args.nil?
    args = @args.split('/')
    unless Dir.exists? args[0]
      raise "Directory with nodes does not exists: #{args[0]}"
    end
    public_keys(args)
  end
  
  private
  
  # copy ssh keys to config/node
  def public_keys(args)
    exit_code = 0
    mc = MachineConfigurator.new(@out)
    
    configurationDir = Dir.new(args[0])

    if args[1].nil? # No node argument, copy keys to all nodes
      network = load_nodes_from_dir(configurationDir)
      if network.nodes.empty?
        raise "No aws, vbox, libvirt, docker nodes found in #{args[0]}"
      end
      if @labels.nil? # No label, copy keys to all nodes
        network.nodes.each do |node|
          machine = parse_node(node, configurationDir.path)
          exit_code = upload_ssh_file(machine, keyFile, mc)
        end
      else # Copy keys to nodes with select label
        network.nodes.each do |node|
          unless node.config.template[node.name]["labels"].nil?
            if node.config.template[node.name]["labels"].include? @labels
              machine = parse_node(node, configurationDir.path)
              exit_code = upload_ssh_file(machine, @keyFile, mc)
            end
          end
        end
      end
    else # Copy keys to select node
      pathNode = configurationDir.entries.find { |elem| elem == args[1] }
      unless pathNode.nil?
        network = Network.new
        network.loadNodes configurationDir.path + '/' + pathNode
        machine = parse_node(network.nodes[0], configurationDir.path)
        exit_code = upload_ssh_file(machine, @keyFile, mc)
      else
        raise "No such node with name #{args[1]} in #{args[0]}"
      end
    end   
    exit_code
  end

  # Connect to the specified machine and upload ssh keyfile
  # @param machine [Hash] information about machine to connect
  # @param keyFile [String] path to the keyfile on the local machine
  # @param mc [MachineConfigurator] object
  def upload_ssh_file(machine, keyFile, mc)
    exit_code = 0
    options = Net::SSH.configuration_for(machine['network'], true)
    options[:auth_methods] = %w[publickey none]
    options[:verify_host_key] = false
    options[:keys] = [machine['keyfile']]
    begin
      Net::SSH.start(machine['network'], machine['whoami'], options) do |ssh|  
        mc.upload_file(ssh, keyFile, ".ssh/authorized_keys", false)
      end
    rescue
      print "Could not connaction to machine #{machine['network']}\n"
      exit_code = 1
    end
    exit_code
  end

  # Parse information about machine
  # @param node [Node] node object
  # @param pathConfiguration [String] path directory with configuration
  def parse_node(node, pathConfiguration)
    if node.nil?
      raise "No such node with name #{args[1]} in #{args[0]}"
    end
    config = NetworkConfigFile.new(pathConfiguration + '/' + node.name + '_network_config')
    machine = {"whoami" => config.configs[node.name]["whoami"], "network" => config.configs[node.name]["network"],
               "keyfile" => config.configs[node.name]["keyfile"] }
  end

  #load all nodes from directory with configuration
  # @param configurationDir [Dir] directory with configuration
  def load_nodes_from_dir(configurationDir)
    network = Network.new
    configurationDir.entries.each  do |node|
      next if (node == '.' || node == '..')
      pathNode =  configurationDir.path + '/' + node
      if File.directory? (pathNode)
        network.loadNodes pathNode
        config = Configuration.new(config_path)
        #  config.node_names.each do |node|
        #    getNodeInfo(config, node)
        #  end
      end
    end
    network
  end
end
