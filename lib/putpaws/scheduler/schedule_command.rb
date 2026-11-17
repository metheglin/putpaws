require 'aws-sdk-scheduler'

module Putpaws::Scheduler
  # Deploys a schedule (Putpaws::ScheduleConfig) to EventBridge Scheduler.
  # What gets started comes from the same resolved launch that `ecs:run` uses.
  class ScheduleCommand
    attr_reader :config, :launch

    def initialize(schedule_config, client: nil)
      @config = schedule_config
      @launch = schedule_config.resolve
      @client = client
    end

    def client
      @client ||= Aws::Scheduler::Client.new({region: launch.region})
    end

    def generated_params
      target = launch.target
      unless target.cluster_arn?
        raise Putpaws::ConfigError,
          "target `#{target.name}` needs the cluster ARN as `cluster` to be scheduled (.putpaws/infra.json)"
      end
      if target.scheduler_role.to_s.strip.empty?
        raise Putpaws::ConfigError,
          "target `#{target.name}` needs `scheduler_role` to be scheduled (.putpaws/infra.json)"
      end

      params = {
        name: config.aws_name,
        flexible_time_window: {mode: "OFF"},
        target: {
          arn: target.cluster,
          role_arn: target.scheduler_role,
          retry_policy: {maximum_retry_attempts: 0},
          ecs_parameters: {
            network_configuration: launch.network_configuration,
            task_definition_arn: target.task_definition,
            task_count: 1,
          }.merge(launch.placement),
        }
      }
      # EventBridge Scheduler hands `input` to RunTask as its `overrides`.
      overrides = launch.task_overrides_json
      params[:target][:input] = overrides.to_json unless overrides.empty?
      params
    end

    # Whatever else is written in schedule.json (schedule_expression, state ...)
    # is passed to create_schedule / update_schedule as it is.
    def params
      deep_merge(generated_params, config.args)
    end

    def deploy!
      args = params
      lookup = {name: args[:name]}
      lookup[:group_name] = args[:group_name] if args[:group_name]
      begin
        client.get_schedule(lookup)
        client.update_schedule(args)
        :updated
      rescue Aws::Scheduler::Errors::ResourceNotFoundException
        client.create_schedule(args)
        :created
      end
    end

    private

    def deep_merge(base, other)
      base.merge(other) do |_, a, b|
        a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b
      end
    end
  end
end
