require 'socket'
require 'aws-sdk-ecs'
require 'aws-sdk-ssm'

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
      return [] if res.task_arns.empty?
      res = ecs_client.describe_tasks(tasks: res.task_arns, cluster: cluster)
      return res.tasks unless task_name_prefix
      res.tasks.select{|t| 
        _, name = t.task_definition_arn.split('task-definition/')
        name.start_with?(task_name_prefix)
      }
    end

    def get_session_target(container: 'app')
      raise "ECS Task Not Set" unless ecs_task
      ctn = ecs_task.containers.detect{|c| c.name == container}
      task_id = ecs_task.task_arn.split('/').last
      raise "Container: #{container} not found" unless ctn
      "ecs:#{cluster}_#{task_id}_#{ctn.runtime_id}"
    end

    def local_port_available?(port)
      TCPServer.new('127.0.0.1', port.to_i).close
      true
    rescue Errno::EADDRINUSE, Errno::EACCES
      false
    end

    def resolve_local_port(local_port)
      if local_port
        unless local_port_available?(local_port)
          raise "Local port #{local_port} is already in use"
        end
        local_port.to_s
      else
        port = (1050..1079).to_a.shuffle.detect{|p| local_port_available?(p)}
        raise "No available local port between 1050 and 1079. Please specify one like: local=:8080" unless port
        port.to_s
      end
    end

    def get_port_forwarding_command(container: nil, remote_port:, remote_host:, local_port: nil)
      container ||= 'app'
      target = get_session_target(container: container)
      ssm_client = Aws::SSM::Client.new({region: region})
      local_port = resolve_local_port(local_port)
      puts "Starting to use local port: #{local_port}"
      res = ssm_client.start_session({
        target: target,
        document_name: "AWS-StartPortForwardingSessionToRemoteHost",
        parameters: {
          portNumber: [remote_port],
          localPortNumber: [local_port],
          host: [remote_host]
        }
      })
      build_session_manager_plugin_command(session: res, target: target)
    end

    def get_attach_command(container: nil)
      container ||= 'app'
      target = get_session_target(container: container)
      res = ecs_client.execute_command({
        cluster: cluster,
        container: container,
        command: '/bin/bash',
        interactive: true,
        task: ecs_task.task_arn,
      })
      build_session_manager_plugin_command(session: res.session, target: target)
    end

    # Returns an argument array so that callers can spawn session-manager-plugin
    # without a shell like `system(*cmd)`.
    # https://github.com/aws/aws-cli/blob/2a6136010d8656a605d41d1e7b5fdab3c2930cad/awscli/customizations/ecs/executecommand.py#L105
    def build_session_manager_plugin_command(session:, target:)
      ssm_region = ENV['AWS_REGION_SSM'] || @region

      session_json = if session.respond_to?(:session_id)
        {
          "SessionId" => session.session_id,
          "StreamUrl" => session.stream_url,
          "TokenValue" => session.token_value,
        }.to_json
      elsif session.is_a?(Hash)
        session.to_json
      else
        session
      end
      target_json = {
        "Target" => target
      }.to_json
      [
        "session-manager-plugin",
        session_json,
        @region,
        "StartSession",
        ENV['AWS_PROFILE'].to_s,
        target_json,
        "https://ssm.#{ssm_region}.amazonaws.com"
      ]
    end
  end
end
