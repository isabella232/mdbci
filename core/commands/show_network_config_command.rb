require_relative 'base_command'
require_relative '../models/configuration'
require_relative '../models/network_settings'
require_relative '../services/vagrant_service'

# Command recreates the network configuration file
class ShowNetworkConfigCommand < BaseCommand

  def show_help
    @ui.info <<-HELP
The command regenerates the network information file for the given configuration. If the command
was unable to get the current data from the VMs, then the network configuration file will not be updated.

Update the network configuration for the whole configuration:

mdbci show network_config ten_machines

Update the network configuration for a single node:

mdbci show network_config ten_machines/node_000

Update the network configuration for nodes specified by labels:

mdbci show network_config --labels first,last ten_machines

The last command currently will place only the configuration for the specified nodes into the network_configuration file.
    HELP
  end

  def execute
    if @env.show_help
      show_help
      return SUCCESS_RESULT
    end
    if parse_configuration != SUCCESS_RESULT
      return ARGUMENT_ERROR_RESULT
    end
    write_network_configuration
  end

  def parse_configuration
    if @args.size == 0
      @ui.error("Please specify configuration to recreate the network configuration.")
      return ARGUMENT_ERROR_RESULT
    end
    @configuration = Configuration.new(@args.first, @env.labels)
    SUCCESS_RESULT
  rescue ArgumentError => error
    @ui.error(error.message)
    return ARGUMENT_ERROR_RESULT
  end

  def write_network_configuration
    network_settings = NetworkSettings.new
    @configuration.node_configurations.keys.each do |node|
      if VagrantService.node_running?(node, @ui, @configuration.path)
        settings = VagrantService.generate_ssh_settings(node, @ui, @configuration)
        network_settings.add_network_configuration(node, settings)
      end
    end
    network_settings.store_network_configuration(@configuration)
    @ui.info("Wrote network configuration file to #{@configuration.network_settings_file}")
    SUCCESS_RESULT
  rescue RuntimeError => error
    @ui.error('Unable to create new network configuration file')
    @ui.error(error.message)
    ERROR_RESULT
  end
end
