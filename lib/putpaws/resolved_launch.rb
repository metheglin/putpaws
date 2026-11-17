require 'json'
require 'putpaws/launch_config'

# A launch after resolution (see Putpaws::LaunchResolver): `target` and
# `network` are looked up in infra.json and every override is applied.
# This is the single place that knows how a launch maps onto the ECS RunTask
# API, so that a manual run and a schedule start exactly the same thing.
class Putpaws::ResolvedLaunch
  SHELL = ['/bin/sh', '-c']
  # snake_case (aws-sdk params) -> camelCase (TaskOverride JSON for EventBridge Scheduler)
  JSON_KEYS = {
    container_overrides: 'containerOverrides',
    task_role_arn: 'taskRoleArn',
    ephemeral_storage: 'ephemeralStorage',
    size_in_gi_b: 'sizeInGiB',
  }

  attr_reader :application, :attributes, :target, :network

  def initialize(application:, attributes:, target:, network:)
    @application = application
    @attributes = attributes
    @target = target
    @network = network
  end

  Putpaws::LaunchConfig::FIELDS.each do |field|
    next if %i[target network].include?(field)
    define_method(field){ attributes[field] }
  end

  # The launch as it can be written to launch.json.
  def to_h
    attributes.dup
  end

  # Another launch based on this one with further overrides applied.
  def with(overrides)
    Putpaws::LaunchResolver.resolve(application: application, overrides: [attributes, overrides])
  end

  def region
    application.ecs_region || application.region
  end

  def cluster
    target.cluster
  end

  def cluster_name
    target.cluster_name
  end

  def task_definition
    target.task_definition
  end

  def container_name
    container || target.container_name || 'app'
  end

  # A string is run through the shell; an array is passed as it is.
  def command_array
    return nil if command.nil?
    command.is_a?(Array) ? command : SHELL + [command]
  end

  def network_configuration
    {
      awsvpc_configuration: {
        subnets: network.subnets,
        security_groups: network.security_groups,
        assign_public_ip: network.assign_public_ip,
      }
    }
  end

  # launch_type and capacity_provider_strategy are mutually exclusive on RunTask.
  def placement
    if capacity_provider && capacity_provider != 'FARGATE'
      {capacity_provider_strategy: [{capacity_provider: capacity_provider, weight: 1}]}
    else
      {launch_type: 'FARGATE'}
    end
  end

  # `overrides` of ECS RunTask. Empty when the task definition runs as it is.
  def task_overrides
    overrides = {}
    container_override = {name: container_name}
    container_override[:command] = command_array if command
    if env && !env.empty?
      container_override[:environment] = env.map{|name, value| {name: name, value: value}}
    end
    overrides[:container_overrides] = [container_override] if container_override.size > 1
    overrides[:cpu] = cpu.to_s if cpu
    overrides[:memory] = memory.to_s if memory
    overrides[:task_role_arn] = task_role if task_role
    overrides[:ephemeral_storage] = {size_in_gi_b: ephemeral_storage} if ephemeral_storage
    overrides
  end

  # The same overrides in the JSON shape of the ECS API (TaskOverride),
  # which EventBridge Scheduler takes as the `input` of an ECS target.
  def task_overrides_json
    camelize(task_overrides)
  end

  # Everything that decides what gets started, for `dry=true` and `info`.
  def describe
    {
      environment: application.name,
      region: region,
      launch: to_h,
      target: {
        name: target.name,
        cluster: target.cluster,
        task_definition: target.task_definition,
        container_name: container_name,
      },
      network: {
        name: network.name,
        subnets: network.subnets,
        security_groups: network.security_groups,
        assign_public_ip: network.assign_public_ip,
      },
    }
  end

  private

  def camelize(obj)
    case obj
    when Hash
      obj.map{|k, v| [JSON_KEYS[k] || k.to_s, camelize(v)]}.to_h
    when Array
      obj.map{|x| camelize(x)}
    else
      obj
    end
  end
end
