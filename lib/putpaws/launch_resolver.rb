require 'putpaws/config_file'
require 'putpaws/launch_config'
require 'putpaws/resolved_launch'
require 'putpaws/infra_network_config'
require 'putpaws/infra_target_config'

# Builds the launch that actually gets started. Later layers win, field by field:
#
#   1. defaults of the task definition (putpaws passes nothing)
#   2. the named launch of the environment (launch.json)
#   3. for a schedule: the overrides written in schedule.json
#   4. for a manual run: the command-line parameters
#
# `env` is merged name by name; every other field is replaced as a whole.
# `ecs:run`, `ecs:shell` and the scheduler all go through here.
class Putpaws::LaunchResolver
  def self.resolve(application:, launch: nil, overrides: [])
    new(application: application, launch: launch, overrides: overrides).resolve
  end

  attr_reader :application, :launch, :overrides

  # launch:    Putpaws::LaunchConfig or nil (assemble on the spot)
  # overrides: a Hash, or an Array of Hashes applied in order
  def initialize(application:, launch: nil, overrides: [])
    @application = application
    @launch = launch
    @overrides = overrides.is_a?(Hash) ? [overrides] : overrides.compact
  end

  def path_prefix
    application.path_prefix || Putpaws::ConfigFile.root
  end

  def resolve
    attributes = merged_attributes
    missing = Putpaws::LaunchConfig::REQUIRED - attributes.keys
    unless missing.empty?
      raise Putpaws::ConfigError,
        "The launch has no #{missing.map{|k| "`#{k}`"}.join(' and ')}. " +
        "Pass launch=<name> (see `launch:list`), or both target=<name> and network=<name>."
    end

    target = Putpaws::InfraTargetConfig.find(attributes[:target], path_prefix: path_prefix)
    unless target
      raise Putpaws::ConfigError, "target `#{attributes[:target]}` is not defined in #{infra_path}\n" +
        "Available: #{Putpaws::InfraTargetConfig.all(path_prefix: path_prefix).map(&:name).join(', ')}"
    end
    network = Putpaws::InfraNetworkConfig.find(attributes[:network], path_prefix: path_prefix)
    unless network
      raise Putpaws::ConfigError, "network `#{attributes[:network]}` is not defined in #{infra_path}\n" +
        "Available: #{Putpaws::InfraNetworkConfig.all(path_prefix: path_prefix).map(&:name).join(', ')}"
    end
    check_environment!(target)

    Putpaws::ResolvedLaunch.new(
      application: application,
      attributes: attributes,
      target: target,
      network: network,
    )
  end

  def merged_attributes
    layers = []
    layers << launch.attributes if launch
    overrides.each do |layer|
      layers << Putpaws::LaunchConfig.normalize(layer, context: "the overrides")
    end
    merged = layers.reduce({}) do |result, layer|
      env = (result[:env] || {}).merge(layer[:env] || {})
      result = result.merge(layer)
      result[:env] = env unless env.empty?
      result
    end
    # Keep a stable field order whatever the layers looked like.
    Putpaws::LaunchConfig::FIELDS.select{|f| merged.key?(f)}.map{|f| [f, merged[f]]}.to_h
  end

  private

  def infra_path
    File.join(path_prefix.to_s, 'infra.json')
  end

  # Parts do not know environments, so a launch could point at the parts of
  # another environment by mistake. Stop here when the cluster of the target
  # is not the cluster of this environment.
  def check_environment!(target)
    if target.cluster.to_s.strip.empty?
      raise Putpaws::ConfigError, "target `#{target.name}` has no `cluster` (#{infra_path})"
    end
    env_region = application.ecs_region || application.region
    env_cluster = application.cluster.to_s.split('/').last
    region = target.cluster_region
    return if (region.nil? || region == env_region) && target.cluster_name == env_cluster

    raise Putpaws::ConfigError,
      "target `#{target.name}` does not belong to environment `#{application.name}`.\n" +
      "  target cluster:      #{target.cluster}\n" +
      "  environment cluster: #{env_cluster} (region: #{env_region})\n" +
      "Check `target` of the launch, or `region` / `cluster` in #{application.dir.join('application.json')}"
  end
end
