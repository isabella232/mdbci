require 'json'
require_relative '../models/return_codes'
require_relative '../models/tool_configuration'

class RepoManager
  include ReturnCodes

  attr_accessor :repos
  attr_accessor :recipes  # product => recipe

  PRODUCT_ATTRIBUTES = {
    'mariadb' => {
      recipe: 'mariadb::install_community',
      name: 'mariadb',
      repository: 'mariadb'
    },
    'mdbe' => {
      recipe: 'mariadb::install_enterprise',
      name: 'mariadb',
      repository: 'mdbe'
    },
    'maxscale' => {
      recipe: 'mariadb-maxscale::install_maxscale',
      name: 'maxscale',
      repository: 'maxscale'
    },
    'maxscale_remove' => {
      recipe: 'mariadb-maxscale::purge_maxscale',
      name: 'maxscale',
      repository: 'maxscale'
    },
    'maxscale_ci' => {
      recipe: 'mariadb-maxscale::install_maxscale',
      name: 'maxscale',
      repository: 'maxscale_ci',
      repo_file_name: 'maxscale_ci'
    },
    'mysql' => {
      recipe: 'mysql::install_community',
      name: 'mysql',
      repository: 'mysql'
    },
    'packages' => {
      recipe: 'packages',
      name: 'packages'
    },
    'columnstore' => {
      recipe: 'mariadb_columnstore',
      name: 'columnstore',
      repository: 'columnstore'
    },
    'galera' => {
      recipe: 'galera',
      name: 'galera',
      repository: 'mariadb'
    },
    'docker' => {
      recipe: 'docker',
      name: 'docker'
    },
    'clustrix' => {
      recipe: 'clustrix',
      name: 'clustrix',
      repository: 'clustrix',
      license_file_name: 'clustrix_license'
    }
  }

  # The list of the directories to search data in. The last directory takes presence over the first one
  BOX_DIRECTORIES = [
    File.expand_path('../../config/repo.d/', __dir__),
    File.join(XDG['CONFIG_HOME'].to_s, 'mdbci', 'repo.d')
  ].freeze

  def initialize(logger, extra_path = nil)
    @ui = logger
    if !extra_path.nil? && !File.exist?(extra_path)
      raise ArgumentError, "The specified repository definition path is absent: '#{extra_path}'"
    end

    @repos = Hash.new
    paths = Array.new(BOX_DIRECTORIES).push(extra_path).compact
    paths.each do |path|
      lookup(path)
    end
    raise 'Repositories was not found' if @repos.empty?
    @ui.info("Loaded repos: #{@repos.size.to_s}")
  end

  # Get the recipe name for the product
  def recipe_name(product)
    PRODUCT_ATTRIBUTES[product][:recipe]
  end

  # Get the repo file name for the product
  def repo_file_name(product)
    PRODUCT_ATTRIBUTES[product][:repo_file_name]
  end

  # Get the attribute name for the product
  def attribute_name(product)
    PRODUCT_ATTRIBUTES[product][:name]
  end

  def need_product_license?(product)
    !PRODUCT_ATTRIBUTES[product][:license_file_name].nil?
  end

  # Get the product license
  # @param product [String] product name
  # @return [Result] product license value
  def product_license(product)
    file_name = PRODUCT_ATTRIBUTES[product][:license_file_name]
    ToolConfiguration.load_license_file(file_name)
  end

  def find_repository(product_name, product, box)
    @ui.info('Looking for repo')
    if PRODUCT_ATTRIBUTES[product_name][:repository].nil?
      @ui.warning('MDBCI cannot determine the existence/correctness of the specified version of the product!')
      return { 'version' => product['version'] }
    end
    version = product['version'].nil? ? 'default' : product['version']
    repository_key = $session.box_definitions.platform_key(box)
    repository_name = PRODUCT_ATTRIBUTES[product_name][:repository]
    if product['version'].nil?
      repo = find_last_repository_version(product, repository_key)
    else
      repo_key = "#{repository_name}@#{version}+#{repository_key}"
      repo = @repos[repo_key]
    end
    @ui.info("Repo key is '#{repo_key}': #{repo.nil? ? 'Not found' : 'Found'}")
    repo
  end

  def show
    @repos.keys.each do |key|
      $out.out key + ' => [' +@repos[key]['repo'] +']'
    end
    0
  end

  def getRepo(key)
    repo = @repos[key]
    raise "Repository for key #{key} was not found" if repo.nil?
    return repo
  end

  def lookup(path)
    @ui.info("Looking up for repos in '#{path}'")
    Dir.glob(path+'/**/*.json', File::FNM_DOTMATCH) do |f|
      addRepo(f)
    end
  end

  def knownRepo?(repo)
    @repos.key?(repo)
  end

  def productName(repo)
    repo.to_s.split('@')[0]
  end

  def makeKey(product,version,platform,platform_version)
    if version.nil?
      version = '?'
    end

    product.to_s+'@'+version.to_s+'+'+platform.to_s+'^'+platform_version.to_s
  end

  def addRepo(file)
    begin
      repo = JSON.parse(IO.read(file))

      if repo.kind_of?(Array)
        # in repo file arrays are allowed
        repo.each do |r|
          @repos[makeKey(r['product'],r['version'],r['platform'],r['platform_version'])] = r
        end
      else
        @repos[makeKey(repo['product'],repo['version'],repo['platform'],repo['platform_version'])] = repo
      end

      #TODO #6374 check keys
      #@repos << repo
    rescue
      $out.warning 'Invalid file format: '+file.to_s + ' SKIPPED!'
    end
  end

  private

  # Find the latest available repository version
  # @param product [Hash] hash array with information about product
  # @param repository_key [String] key of repository
  def find_last_repository_version(product, repository_key)
    all_available_repo = @repos.find_all do |elem|
      elem[1]['product'] == product['name'] &&
        elem[1]['platform'] + '^' + elem[1]['platform_version'] == repository_key
    end
    repo = all_available_repo.last[1]
    all_available_repo.delete_if { |elem| elem[1]['version'].include?('debug') }
    repo = all_available_repo.last[1] unless all_available_repo.nil?
    repo
  end
end
