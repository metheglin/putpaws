require 'aws-sdk-ecs'

module Putpaws::Ecs
  class RunCommand
    DEFAULT_TTL = '30m'
    SECONDS = {
      's' => 1,
      'm' => 60,
      'h' => 60 * 60,
    }

    def self.config(config)
      unless config.network && config.target
        raise "Please set `network` and `target` at .putpaws/application.json\n" +
          "They refer to `network` and `target` sections at .putpaws/infra.json\n" +
          "(Ex) \"network\": \"awesome-private-staging\", \"target\": \"awesome-staging\""
      end
      new(
        region: config.ecs_region || config.region,
        network: config.network,
        target: config.target,
      )
    end

    # "45" and "45m" mean 45 minutes. "90s" and "2h" are also acceptable.
    def self.parse_ttl(ut)
      ut = DEFAULT_TTL if ut.nil? || ut.strip.empty?
      matched, number, unit = ut.strip.match(/\A(\d+)([smh])?\z/).to_a
      raise "Invalid ttl: #{ut} (Ex) ttl=30m ttl=2h ttl=90s" unless matched
      number.to_i * SECONDS[unit || 'm']
    end

    attr_reader :ecs_client
    attr_reader :region, :network, :target
    def initialize(region:, network:, target:)
      @ecs_client = Aws::ECS::Client.new({region: region})
      @region = region
      @network = network
      @target = target
    end

    def cluster_name
      target.cluster.split('/').last
    end

    def container_name
      target.container_name || 'app'
    end

    # Launch a temporary task whose main process is overridden with the given
    # command, so that the task terminates itself when the command finishes.
    # started_by and group are set so that temporary tasks are identifiable.
    # cpu/memory override the task-level size for this launch only
    # (must be a valid Fargate combination).
    def run_ecs_task(command:, started_by:, group:, container: nil, cpu: nil, memory: nil)
      overrides = {
        container_overrides: [
          {
            name: container || container_name,
            command: ['/bin/sh', '-c', command],
          }
        ]
      }
      overrides[:cpu] = cpu.to_s unless cpu.to_s.strip.empty?
      overrides[:memory] = memory.to_s unless memory.to_s.strip.empty?

      res = ecs_client.run_task({
        cluster: target.cluster,
        task_definition: target.task_definition,
        count: 1,
        launch_type: 'FARGATE',
        enable_execute_command: true,
        started_by: started_by,
        group: group,
        network_configuration: {
          awsvpc_configuration: {
            subnets: network.subnets,
            security_groups: network.security_groups,
            assign_public_ip: network.assign_public_ip,
          }
        },
        overrides: overrides,
      })
      failure = res.failures.first
      raise "Failed to run task: #{failure.reason} #{failure.detail}" if failure
      res.tasks.first
    end

    def wait_until_attachable(task_arn, timeout: 600, interval: 5)
      deadline = Time.now + timeout
      loop do
        res = ecs_client.describe_tasks(cluster: target.cluster, tasks: [task_arn])
        task = res.tasks.first
        if task.nil? || task.last_status == 'STOPPED'
          raise "Task was stopped: #{task && task.stopped_reason}"
        end
        ctn = task.containers.detect{|c| c.name == container_name}
        agent = ctn && (ctn.managed_agents || []).detect{|a| a.name == 'ExecuteCommandAgent'}
        return task if task.last_status == 'RUNNING' && agent && agent.last_status == 'RUNNING'
        raise "Timed out waiting for task to be attachable: #{task_arn}" if Time.now > deadline
        sleep interval
      end
    end

    def wait_until_stopped(task_arn, timeout: 3600, interval: 10)
      deadline = Time.now + timeout
      loop do
        res = ecs_client.describe_tasks(cluster: target.cluster, tasks: [task_arn])
        task = res.tasks.first
        raise "Task not found: #{task_arn}" unless task
        return task if task.last_status == 'STOPPED'
        raise "Timed out waiting for task to stop: #{task_arn}" if Time.now > deadline
        sleep interval
      end
    end

    def stop_ecs_task(task_arn, reason: 'Stopped by putpaws')
      ecs_client.stop_task(cluster: target.cluster, task: task_arn, reason: reason)
    end
  end
end
