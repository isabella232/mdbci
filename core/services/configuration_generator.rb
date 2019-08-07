# frozen_string_literal: true

# The class provides methods for generating the role of the file.
module ConfigurationGenerator
  # Generate a list of role parameters in JSON format
  # @param name [String] node name
  # @param product_config [Hash] list of the product parameters
  # @param recipe_name [String] name of the recipe
  # @oaram sub_manager [Hash] information for subscription manager: box, rhel_credentials, box_definitions
  def self.generate_json_format(name, recipes_names, sub_manager = nil, product_configs = {})
    run_list = ['recipe[mdbci_provision_mark::remove_mark]',
                *recipes_names.map { |recipe_name| "recipe[#{recipe_name}]" },
                'recipe[mdbci_provision_mark::default]']
    unless sub_manager.nil?
      if check_subscription_manager(sub_manager['box_definitions'], sub_manager['box'])
        raise 'RHEL credentials for Red Hat Subscription-Manager are not configured' if sub_manager['rhel_credentials'].nil?

        run_list.insert(1, 'recipe[subscription-manager]')
        product_configs = product_configs.merge('subscription-manager': sub_manager['rhel_credentials'])
      end
    end
    role = { name: name,
             default_attributes: {},
             override_attributes: product_configs,
             json_class: 'Chef::Role',
             description: '',
             chef_type: 'role',
             run_list: run_list }
    JSON.pretty_generate(role)
  end

  # Check whether box needs to be subscribed or not
  # @param box_definitions [BoxDefinitions] the list of BoxDefinitions that are configured in the application
  # @param box [String] name of the box
  def self.generate_subscription_manager(box_definitions, box, rhel_credentials, product_configs, run_list)
    if box_definitions.get_box(box)['configure_subscription_manager'] == 'true'
      raise 'RHEL credentials for Red Hat Subscription-Manager are not configured' if rhel_credentials.nil?

      run_list.insert(1, 'recipe[subscription-manager]')
      product_configs = product_configs.merge('subscription-manager': rhel_credentials)
    end
    { 'run_list' => run_list, 'product_configs' => product_configs }
  end

  # Make list of not-null product attributes
  # @param repo [Hash] repository info
  def self.make_product_attributes_hash(repo)
    %w[version repo repo_key].map { |key| [key, repo[key]] unless repo[key].nil? }.compact.to_h
  end

  # Generate the list of the product parameters
  # @param repos [RepoManager] for products
  # @param product_name [String] name of the product for install
  # @param product [Hash] parameters of the product to configure from configuration file
  # @param box [String] name of the box
  # @param repo [String] repo for product
  def self.generate_product_config(repos, product_name, product, box, repo)
    repo = repos.find_repository(product_name, product, box) if repo.nil?
    raise "Repo for product #{product['name']} #{product['version']} for #{box} not found" if repo.nil?

    config = make_product_attributes_hash(repo)
    if check_product_availability(product)
      config['cnf_template'] = product['cnf_template']
      config['cnf_template_path'] = product['cnf_template_path']
    end
    repo_file_name = repos.repo_file_name(product_name)
    config['repo_file_name'] = repo_file_name unless repo_file_name.nil?
    config['node_name'] = product['node_name'] unless product['node_name'].nil?
    attribute_name = repos.attribute_name(product_name)
    { "#{attribute_name}": config }
  end

  # Checks the availability of product information.
  # @param product [Hash] parameters of the product to configure from configuration file
  def self.check_product_availability(product)
    !product['cnf_template'].nil? && !product['cnf_template_path'].nil?
  end
end
