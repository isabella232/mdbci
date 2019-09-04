# frozen_string_literal: true

require 'date'
require 'socket'
require 'erb'

# The class generates the Terraform configuration file content for MDBCI configuration
class AwsTerraformGenerator
  CONFIGURATION_FILE_NAME = 'infrastructure.tf'

  # Initializer
  # @param aws_service [AwsService] service for execute commands in accordance to the AWS EC2
  # @param aws_config [Hash] AWS params (credentials etc.)
  # @param logger [Out] logger.
  def initialize(aws_service, aws_config, logger)
    @aws_service = aws_service
    @aws_config = aws_config
    @ui = logger
  end

  def configuration_file_name
    CONFIGURATION_FILE_NAME
  end

  # Header of generated configuration file
  def file_header
    <<-HEADER
    # !! Generated content, do not edit !!
    # Generated by MariaDB Continuous Integration Tool (https://github.com/mariadb-corporation/mdbci)
    #### Created #{Time.now} ####
    HEADER
  end

  # Header of configuration content
  def config_header
    ''
  end

  # Footer of configuration content
  def config_footer
    ''
  end

  # Generate and return provider configuration content for configuration file
  # @param path [String] path of the generated configuration
  # @return [String] provider configuration content for configuration file
  def generate_provider_config(path)
    @ui.info('Generating AWS configuration')
    @path_to_keyfile, @keypair_name = generate_key_pair(path)
    provider_config
  end

  # Generate the key pair for the AWS.
  def handle_invalid_configuration_case
    @aws_service.delete_key_pair(@keypair_name)
  end

  # Print node info specific for current nodes provider
  def print_node_specific_info(node_params)
    @ui.info("AWS definition for host:#{node_params[:host]}, ami:#{node_params[:amiurl]}, "\
             "user:#{node_params[:user]}, instance:#{node_params[:instance]}")
  end

  # Generate a node definition for the configuration file.
  # @param node_params [Hash] list of the node parameters
  # @param path [String] path of the configuration file
  # @return [String] node definition for the configuration file.
  def generate_node_defenition(node_params, path)
    tags = { hostname: Socket.gethostname, username: Etc.getlogin,
             full_config_path: File.expand_path(path), machinename: node_params[:name] }
    node_params[:device_name] = @aws_service.device_name_for_ami(node_params[:ami])
    get_vms_definition(tags, node_params)
  end

  private

  def provider_config
    <<-PROVIDER
    provider "aws" {
      profile    = "default"
      region     = "#{@aws_config['region']}"
      access_key = "#{@aws_config['access_key_id']}"
      secret_key = "#{@aws_config['secret_access_key']}"
    }
    locals {
      key_name            = "#{@keypair_name}"
      security_groups     = ["default", "#{@aws_config['security_group']}"]
    }
    PROVIDER
  end

  def connection_partial(user, name)
    <<-PARTIAL
    connection {
      type        = "ssh"
      private_key = file("#{@path_to_keyfile}")
      timeout     = "2m"
      agent       = false
      user        = "#{user}"
      host        = aws_instance.#{name}.public_ip
    }
    PARTIAL
  end

  # Generate the key pair for the AWS.
  # @param path [String] path of the configuration file
  # @return [Array[String, String]] path to .pem-file and key pair name.
  def generate_key_pair(path)
    full_path = File.expand_path(path)
    key_pair = @aws_service.generate_key_pair(full_path)
    path_to_keyfile = File.join(full_path, 'maxscale.pem')
    File.write(path_to_keyfile, key_pair.key_material)
    path_to_keypair_file = File.join(full_path, Configuration::AWS_KEYPAIR_NAME)
    File.write(path_to_keypair_file, key_pair.key_name)
    [path_to_keyfile, key_pair.key_name]
  end

  # Generate Terraform configuration of AWS instance
  # @param tags [Hash] tags of AWS instance
  # @param node_params [Hash] list of the node parameters
  # @return [String] configuration content of AWS instance
  # rubocop:disable Metrics/MethodLength
  def get_vms_definition(tags, node_params)
    node_params = node_params.merge(tags: tags)
    connection_block = connection_partial(node_params[:user], node_params[:name])
    template = ERB.new <<-AWS
    resource "aws_instance" "<%= name %>" {
      ami             = "<%= ami %>"
      instance_type   = "<%= default_instance_type %>"
      security_groups = local.security_groups
      key_name = local.key_name
      tags = {
        <% tags.each do |tag_key, tag_value| %>
          <%= tag_key %> = "<%= tag_value %>"
        <% end %>
      }
      <% if device_name %>
        ebs_block_device {
          device_name = "<%= device_name %>"
          volume_size = "500"
        }
      <% end %>
      user_data = <<-EOT
      #!/bin/bash
      sed -i -e 's/^Defaults.*requiretty/# Defaults requiretty/g' /etc/sudoers
      EOT
      provisioner "local-exec" {
        command = "echo ${aws_instance.<%= name %>.public_ip} > ip_address_<%= name %>.txt"
      }
      <% if template_path %>
        provisioner "file" {
          source      = "<%=template_path %>"
          destination = "/home/<%= user %>/cnf_templates"
          <%= connection_block %>
        }
        provisioner "remote-exec" {
          inline = [
            "sudo mkdir /home/vagrant",
            "sudo mv /home/<%= user %>/cnf_templates /home/vagrant/cnf_templates"
          ]
          <%= connection_block %>
        }
      <% end %>
    }
    AWS
    template.result(OpenStruct.new(node_params).instance_eval { binding })
  end
  # rubocop:enable Metrics/MethodLength
end
