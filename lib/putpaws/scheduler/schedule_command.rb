require 'aws-sdk-scheduler'

module Putpaws::Scheduler
  class ScheduleCommand
    def self.config(config)
      new(**config.log_command_params)
    end

    attr_reader :client
    attr_reader :config, :network, :target
    
    def initialize(schedule_config)
      @config = schedule_config
      @network = config.network
      @target = config.target
      @client = Aws::Scheduler::Client.new({region: config.region})
    end

    def generated_params
      {
        name: config.name,
        flexible_time_window: {mode: "OFF"},
        target: {
          arn: target.cluster,
          role_arn: target.scheduler_role,
          retry_policy: {maximum_retry_attempts: 0},
          input: {
            containerOverrides: [
              {
                name: target.container_name,
                command: config.command,
              }
            ]
          }.to_json,
          ecs_parameters: {
            launch_type: "FARGATE",
            network_configuration: {
              awsvpc_configuration: {
                subnets: network.subnets,
                security_groups: network.security_groups,
                assign_public_ip: network.assign_public_ip,
              }
            },
            task_definition_arn: target.task_definition,
            task_count: 1,          }
        }
      }
    end

    def deploy!
      # TODO: Use deep merge here
      args = generated_params.merge(config.args)

      begin
        res = client.get_schedule(name: config.name)
        client.update_schedule(args)
      rescue Aws::Scheduler::Errors::ResourceNotFoundException => e
        client.create_schedule(args)
      end
    end
  end
end
