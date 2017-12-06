# frozen_string_literal: true

require_relative 'base_command'
require_relative '../docker_manager'

# The command sets up the environment specified in the configuration file.
class UpCommand < BaseCommand
  def self.synopsis
    'Setup environment as specified in the configuration'
  end

  VAGRANT_NO_PARALLEL = '--no-parallel'
  CHEF_NOT_FOUND_ERROR = <<~ERROR_TEXT
    The chef binary (either `chef-solo` or `chef-client`) was not found on
    the VM and is required for chef provisioning. Please verify that chef
    is installed and that the binary is available on the PATH.
    ERROR_TEXT

  OUTPUT_NODE_NAME_REGEX = "==>\s+(.*):{1}"

  # Checks that all required parameters are passed to the command
  # and set them as instance variables.
  #
  # @raise [ArgumentError] if unable to parse arguments.
  def setup_command
    if @args.empty? || @args.first.nil?
      raise ArgumentError, 'You must specify path to the mdbci configuration as a parameter.'
    end
    @configuration = @args.first

    @attempts = if @env.attempts.nil?
                  5
                else
                  @env.attempts.to_i
                end
    self
  end

  # Checks whether provided path is a directory containing configurations.
  #
  # @param path [String] path that should be checked
  #
  # @returns [Boolean]
  def configuration_directory?(path)
    !path.nil? &&
      !path.empty? &&
      Dir.exist?(path) &&
      File.exist?("#{path}/template") &&
      File.exist?("#{path}/provider") &&
      File.exist?("#{path}/Vagrantfile")
  end

  # Method parses up command configuration and extracts path to the
  # configuration and node name if specified.
  #
  # @raise [ArgumentError] if path to the configuration is invalid
  def parse_configuration
    # Separating config_path from node
    paths = @configuration.split('/') # Split path to the configuration
    config_path = paths[0, paths.length - 1].join('/')
    if configuration_directory?(config_path)
      node = paths.last
      @ui.info "Node #{node} is specified in #{config_path}"
    else
      node = ''
      config_path = @configuration
      @ui.info "Node is not specified in #{config_path}"
    end

    # Checking if vagrant instance derictory exists
    unless configuration_directory?(config_path)
      raise ArgumentError, "Specified path #{config_path} does not point to configuration directory"
    end
    [File.absolute_path(config_path), node]
  end

  # Read template from the specified configuration.
  #
  # @param config_path [String] path to the configuration.
  #
  # @returns [Hash] produced by parsing JSON.
  #
  # @raise [ArgumentError] if there is an error during template configuration.
  def read_template(config_path)
    template_file_name_path = "#{config_path}/template"
    unless File.exist?(template_file_name_path)
      raise ArgumentError, "There is no template configuration specified in #{config_path}."
    end
    template_path = File.read(template_file_name_path)
    unless File.exist?(template_path)
      raise ArgumentError, "The template #{template_path} specified in #{template_file_name_path} does not exist."
    end
    JSON.parse(File.read(template_path))
  end

  # Read node provider specified in the configuration.
  #
  # @return [String] name of the provider specified in the file.
  #
  # @raise ArgumentError if there is no file or invalid provider specified.
  def read_provider(config_path)
    provider_file_path = "#{config_path}/provider"
    unless File.exist?(provider_file_path)
      raise ArgumentError, "There is no provider configuration specified in #{config_path}."
    end
    provider = File.read(provider_file_path).strip
    if provider == 'mdbci'
      raise ArgumentError, 'You are using mdbci node template. Please generate valid one before running up command.'
    end
    @ui.info "Using provider: #{provider}"
    provider
  end

  # Generate docker images, so they will not be loaded during production
  #
  # @param config [Hash] configuration read from the template
  # @param nodes_directory [String] path to the directory where they are located
  def generate_docker_images(config, nodes_directory)
    @ui.info 'Generating docker images.'
    config.each do |node|
      unless node[1]['box'].nil?
        DockerManager.build_image("#{nodes_directory}/#{node[0]}", node[1]['box'])
      end
    end
  end

  # Generate flags based upon the configuration
  #
  # @param provider [String] name of the provider to work with
  #
  # @return [String] flags that should be passed to Vagrant commands
  def generate_vagrant_run_flags(provider)
    flags = []
    if (provider == 'aws') || (provider == 'docker')
      flags << VAGRANT_NO_PARALLEL
    end
    flags.join(' ')
  end

  # Try to use `vagrant up` command to setup machines
  def setup_machines_with_vagrant(node, vagrant_flags, nodes_provider)
    @ui.info "Bringing up #{(node.empty? ? 'configuration ' : 'node ')} #{@configuration}"
    cmd_up = "vagrant up #{vagrant_flags} --provider=#{nodes_provider} #{node}"
    @ui.info "Actual command: #{cmd_up}"

    status = nil
    loop do
      chef_not_found_node = false
      status = Open3.popen3(cmd_up) do |_stdin, stdout, stderr, wthr|
        stdout.each_line do |line|
          @ui.info line
          chef_not_found_node = line if nodes_provider == 'aws'
        end
        error = stderr.read
        if (nodes_provider == 'aws') && error.to_s.include?(CHEF_NOT_FOUND_ERROR)
          chef_not_found_node = chef_not_found_node.to_s.match(OUTPUT_NODE_NAME_REGEX).captures[0]
        else
          error.each_line { |line| @ui.error line }
          chef_not_found_node = false
        end
        wthr.value
      end
      if chef_not_found_node
        @ui.warning "Chef not is found on aws node: #{chef_not_found_node}, applying quick fix..."
        cmd_provision = "vagrant provision #{chef_not_found_node}"
        status = Open3.popen3(cmd_provision) do |_stdin, stdout, stderr, wthr|
          stdout.each_line { |line| @ui.info line }
          stderr.each_line { |line| @ui.error line }
          wthr.value
        end
      end
      break unless chef_not_found_node # Possible infinite loop, does not honor @max_attempts
    end
    status
  end

  def execute
    begin
      setup_command
      config_path, node = parse_configuration
      template = read_template(config_path)
      nodes_provider = read_provider(config_path)
    rescue ArgumentError => error
      @ui.warning error.message
      return ARGUMENT_ERROR_RESULT
    end

    # Changing directory to the configuration, so Vagrant commands will work
    pwd = Dir.pwd
    Dir.chdir(config_path)

    generate_docker_images(template, '.') if nodes_provider == 'docker'

    vagrant_flags = generate_vagrant_run_flags(nodes_provider)

    @ui.info 'Destroying existing nodes.'
    exec_cmd_destr = `vagrant destroy --force #{node}`
    @ui.info exec_cmd_destr

    status = setup_machines_with_vagrant(node, vagrant_flags, nodes_provider)

    unless status.success?
      @ui.error 'Bringing up failed'
      exit_code = status.exitstatus
      @ui.error "exit code #{exit_code}"

      dead_machines = []
      machines_with_broken_chef = []

      vagrant_status = `vagrant status`.split("\n\n")[1].split("\n")
      nodes = []
      vagrant_status.each { |stat| nodes.push(stat.split(/\s+/)[0]) }

      @ui.warning 'Checking for dead machines and checking Chef runs on machines'
      nodes.each do |machine_name|
        status = `vagrant status #{machine_name}`.split("\n")[2]
        @ui.info status
        unless status.include? 'running'
          dead_machines.push(machine_name)
          next
        end

        chef_log_cmd = "vagrant ssh #{machine_name} -c \"test -e /var/chef/cache/chef-stacktrace.out && printf 'FOUND' || printf 'NOT_FOUND'\""
        chef_log_out = `#{chef_log_cmd}`
        machines_with_broken_chef.push machine_name if chef_log_out == 'FOUND'
      end

      unless dead_machines.empty?
        @ui.error 'Some machines are dead:'
        dead_machines.each { |machine| @ui.error "\t#{machine}" }
      end

      unless machines_with_broken_chef.empty?
        @ui.error 'Some machines have broken Chef run:'
        machines_with_broken_chef.each { |machine| @ui.error "\t#{machine}" }
      end

      unless dead_machines.empty?
        (1..@attempts).each do |i|
          @ui.info 'Trying to force restart broken machines'
          @ui.info "Attempt: #{i}"
          dead_machines.delete_if do |machine|
            puts `vagrant destroy -f #{machine}`
            cmd_up = "vagrant up #{vagrant_flags} --provider=#{nodes_provider} #{machine}"
            success = Open3.popen3(cmd_up) do |_stdin, stdout, stderr, wthr|
              stdout.each_line { |line| @ui.info line }
              stderr.each_line { |line| @ui.error line }
              wthr.value.success?
            end
            success
          end
          if !dead_machines.empty?
            @ui.error 'Some machines are still dead:'
            dead_machines.each { |machine| @ui.error "\t#{machine}" }
          else
            @ui.info 'All dead machines successfuly resurrected'
            break
          end
        end
        raise 'Bringing up failed (error description is above)' unless dead_machines.empty?
      end

      unless machines_with_broken_chef.empty?
        @ui.info 'Trying to re-provision machines'
        machines_with_broken_chef.delete_if do |machine|
          cmd_up = "vagrant provision #{machine}"
          success = Open3.popen3(cmd_up) do |_stdin, stdout, stderr, wthr|
            stdout.each_line { |line| @ui.info line }
            stderr.each_line { |line| @ui.error line }
            wthr.value.success?
          end
          success
        end
        unless machines_with_broken_chef.empty?
          @ui.error 'Some machines are still have broken Chef run:'
          machines_with_broken_chef.each { |machine| @ui.error "\t#{machine}" }
          (1..@attempts).each do |i|
            @ui.info 'Trying to force restart machines'
            @ui.info "Attempt: #{i}"
            machines_with_broken_chef.delete_if do |machine|
              puts `vagrant destroy -f #{machine}`
              cmd_up = "vagrant up #{vagrant_flags} --provider=#{nodes_provider} #{machine}"
              success = Open3.popen3(cmd_up) do |_stdin, stdout, stderr, wthr|
                stdout.each_line { |line| @ui.info line }
                stderr.each_line { |line| @ui.error line }
                wthr.value.success?
              end
              success
            end
            if !machines_with_broken_chef.empty?
              @ui.error 'Some machines are still have broken Chef run:'
              machines_with_broken_chef.each { |machine| @ui.error "\t#{machine}" }
            else
              @ui.info 'All broken_chef machines successfuly reprovisioned.'
              break
            end
          end
          raise 'Bringing up failed (error description is above)' unless machines_with_broken_chef.empty?
        end
      end
    end

    @ui.info 'All nodes successfully up!'
    @ui.info "DIR_PWD=#{pwd}"
    @ui.info "CONF_PATH=#{config_path}"
    Dir.chdir pwd
    @ui.info "Generating #{config_path}_network_settings file"
    printConfigurationNetworkInfoToFile(config_path, node)
    SUCCESS_RESULT
  end
end
