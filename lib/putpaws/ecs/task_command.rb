require 'aws-sdk-ecs'

module Putpaws::Ecs
  class TaskCommand
    def self.config(config)
      new(**config.ecs_command_params)
    end

    attr_reader :ecs_client
    attr_reader :region, :cluster, :task_name_prefix
    attr_accessor :ecs_task
    def initialize(region:, cluster:, task_name_prefix: nil)
      @ecs_client = Aws::ECS::Client.new({region: region})
      @region = region
      @cluster = cluster
      @task_name_prefix = task_name_prefix
      @ecs_task = nil
    end

    def list_ecs_tasks
      res = ecs_client.list_tasks(cluster: cluster)
      res = ecs_client.describe_tasks(tasks: res.task_arns, cluster: cluster)
      return res.tasks unless task_name_prefix
      res.tasks.select{|t| 
        _, name = t.task_definition_arn.split('task-definition/')
        name.start_with?(task_name_prefix)
      }
    end

    def get_attach_command(container: 'app')
      raise "ECS Task Not Set" unless ecs_task
      ctn = ecs_task.containers.detect{|c| c.name == container}
      task_id = ecs_task.task_arn.split('/').last
      raise "Container: #{container} not found" unless ctn
      res = ecs_client.execute_command({
        cluster: cluster,
        container: container,
        command: '/bin/bash',
        interactive: true,
        task: ecs_task.task_arn,
      })

      ssm_region = ENV['AWS_REGION_SSM'] || @region
      
      # https://github.com/aws/aws-cli/blob/2a6136010d8656a605d41d1e7b5fdab3c2930cad/awscli/customizations/ecs/executecommand.py#L105
      session_json = {
        "SessionId" => res.session.session_id,
        "StreamUrl" => res.session.stream_url,
        "TokenValue" => res.session.token_value,
      }.to_json
      target_json = {
        "Target" => "ecs:#{cluster}_#{task_id}_#{ctn.runtime_id}"
      }.to_json
      cmd = [
        "session-manager-plugin",
        session_json.dump,
        @region,
        "StartSession",
        'test',
        target_json.dump,
        "https://ssm.#{ssm_region}.amazonaws.com"
      ]
      cmd.join(' ')
    end
  end
end
