require 'aws-sdk-ecs'

module Putpaws::Ecs
  # Starts a temporary task from a resolved launch (Putpaws::ResolvedLaunch).
  class RunCommand
    DEFAULT_TTL = '30m'
    SECONDS = {
      's' => 1,
      'm' => 60,
      'h' => 60 * 60,
    }

    # "45" and "45m" mean 45 minutes. "90s" and "2h" are also acceptable.
    def self.parse_ttl(ut)
      ut = DEFAULT_TTL if ut.nil? || ut.strip.empty?
      matched, number, unit = ut.strip.match(/\A(\d+)([smh])?\z/).to_a
      raise "Invalid ttl: #{ut} (Ex) ttl=30m ttl=2h ttl=90s" unless matched
      number.to_i * SECONDS[unit || 'm']
    end

    attr_reader :launch
    def initialize(launch, ecs_client: nil)
      @launch = launch
      @ecs_client = ecs_client
    end

    def ecs_client
      @ecs_client ||= Aws::ECS::Client.new({region: region})
    end

    def region
      launch.region
    end

    def cluster_name
      launch.cluster_name
    end

    def container_name
      launch.container_name
    end

    # Parameters of ECS RunTask. started_by and group are set so that
    # temporary tasks are identifiable.
    def run_task_params(started_by:, group:)
      params = {
        cluster: launch.cluster,
        task_definition: launch.task_definition,
        count: 1,
        enable_execute_command: true,
        started_by: started_by,
        group: group,
        network_configuration: launch.network_configuration,
      }.merge(launch.placement)
      overrides = launch.task_overrides
      params[:overrides] = overrides unless overrides.empty?
      params
    end

    def run_ecs_task(started_by:, group:)
      res = ecs_client.run_task(run_task_params(started_by: started_by, group: group))
      failure = res.failures.first
      raise "Failed to run task: #{failure.reason} #{failure.detail}" if failure
      res.tasks.first
    end

    def wait_until_attachable(task_arn, timeout: 600, interval: 5)
      deadline = Time.now + timeout
      loop do
        res = ecs_client.describe_tasks(cluster: launch.cluster, tasks: [task_arn])
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
        res = ecs_client.describe_tasks(cluster: launch.cluster, tasks: [task_arn])
        task = res.tasks.first
        raise "Task not found: #{task_arn}" unless task
        return task if task.last_status == 'STOPPED'
        raise "Timed out waiting for task to stop: #{task_arn}" if Time.now > deadline
        sleep interval
      end
    end

    def stop_ecs_task(task_arn, reason: 'Stopped by putpaws')
      ecs_client.stop_task(cluster: launch.cluster, task: task_arn, reason: reason)
    end
  end
end
