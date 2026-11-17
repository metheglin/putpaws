require "shellwords"
require "putpaws/prompt"
require "putpaws/ecs/task_command"
require "json"
require "putpaws/ecs/run_command"
require "putpaws/ecs/launch_request"

namespace :ecs do
  desc "Set ECS task."
  task :set_task do
    aws = Putpaws::Ecs::TaskCommand.config(fetch(:app))
    ecs_tasks = aws.list_ecs_tasks.map{|t|
      task_id = t.task_arn.split('/').last
      task_def = t.task_definition_arn.split('/').last
      label = "#{task_id} (#{task_def}) #{t.last_status}"
      label += " [#{t.group}]" unless t.group.to_s.start_with?('family:')
      [label, t]
    }.to_h
    if ecs_tasks.empty?
      raise "No running ECS tasks found on cluster: #{aws.cluster}" +
        (aws.task_name_prefix ? " (task_name_prefix: #{aws.task_name_prefix})" : "")
    end
    prompt = Putpaws::Prompt.safe
    selected = prompt.select("Choose a task you're going to operate", ecs_tasks.keys)
    ecs_task = ecs_tasks[selected]

    set :ecs_task, ecs_task
  end

  desc "Attach on ECS task. You need to enable ECS Exec on a specified task and also install session-manager-plugin."
  task attach: :set_task do
    ecs_task = fetch(:ecs_task)
    aws = Putpaws::Ecs::TaskCommand.config(fetch(:app))
    aws.ecs_task = ecs_task
    cmd = aws.get_attach_command(container: ENV['container'])
    puts Shellwords.join(cmd)
    system(*cmd)
  end

  desc "Run port forwarding session. You need to enable ECS Exec on a specified task and also install session-manager-plugin."
  task forward: :set_task do
    ecs_task = fetch(:ecs_task)
    aws = Putpaws::Ecs::TaskCommand.config(fetch(:app))
    aws.ecs_task = ecs_task

    remote_host, remote_port = (ENV['remote'] || '').split(':').map(&:strip)
    _, local_port = (ENV['local'] || '').split(':').map(&:strip)
    if remote_host.nil? or remote_port.nil?
      raise "Remote Host, Port is required: (Ex) remote=192.168.1.1:80"
    end
    cmd = aws.get_port_forwarding_command(
      container: ENV['container'],
      remote_host: remote_host,
      remote_port: remote_port,
      local_port: local_port
    )
    puts Shellwords.join(cmd)
    system(*cmd)
  end

  desc "Run a command on a temporary ECS task started from a launch. The task terminates itself when the command finishes. (Ex) launch=app cmd='bundle exec rake db:migrate' wait=true cpu=1024 memory=2048 save=name dry=true"
  task :run do
    request = Putpaws::Ecs::LaunchRequest.new(application: fetch(:app), prompt: Putpaws::Prompt.safe)
    launch = request.resolve
    if launch.command.nil? && !request.dry?
      raise Putpaws::Error, "Please specify a command like: cmd='bundle exec rake db:migrate' (or save `command` in the launch)"
    end
    next unless request.save!(launch)
    if request.dry?
      puts JSON.pretty_generate(launch.describe)
      next
    end

    runner = Putpaws::Ecs::RunCommand.new(launch)
    ecs_task = runner.run_ecs_task(started_by: 'putpaws-run', group: 'putpaws-run')
    task_id = ecs_task.task_arn.split('/').last
    puts "Task started: #{task_id} [putpaws-run]"

    if ENV['wait']
      puts "Waiting for the task to stop..."
      ecs_task = runner.wait_until_stopped(ecs_task.task_arn)
      ctn = ecs_task.containers.detect{|c| c.name == runner.container_name}
      exit_code = ctn && ctn.exit_code
      puts "Task stopped: #{ecs_task.stopped_reason}"
      raise "Command failed with exit code: #{exit_code.inspect}" unless exit_code == 0
      puts "Command succeeded."
    else
      puts "The task terminates itself when the command finishes."
    end
  end

  desc "Update ECS service with force new deployment (redeploy). (Ex) desired=2 taskdef=my-family wait=true"
  task :deploy do
    aws = Putpaws::Ecs::TaskCommand.config(fetch(:app))
    service_name = aws.service
    if service_name.nil?
      services = aws.list_ecs_services
      raise "No ECS services found on cluster: #{aws.cluster}" if services.empty?
      service_name = if services.one?
        services.first.service_name
      else
        prompt = Putpaws::Prompt.safe
        prompt.select("Choose a service to update", services.map(&:service_name))
      end
    end

    svc = aws.update_ecs_service(
      service: service_name,
      desired_count: ENV['desired'],
      task_definition: ENV['taskdef']
    )
    task_def = svc.task_definition.to_s.split('/').last
    puts "Deployment started: service=#{svc.service_name} task_definition=#{task_def} desired_count=#{svc.desired_count}"

    if ENV['wait']
      puts "Waiting for the service to be stable..."
      aws.wait_ecs_service_stable(service: service_name)
      puts "Service is stable."
    else
      puts "Check progress with: bundle exec putpaws #{fetch(:app).name} log:tailf"
    end
  end

  desc "Start a temporary ECS task from a launch and attach to it. The command is replaced by sleep, so the task terminates itself when ttl passes (default 30m). (Ex) launch=app ttl=45m keep=true cpu=256 memory=512 dry=true"
  task :shell do
    request = Putpaws::Ecs::LaunchRequest.new(application: fetch(:app), prompt: Putpaws::Prompt.safe)
    ttl = Putpaws::Ecs::RunCommand.parse_ttl(ENV['ttl'])
    resolved = request.resolve
    next unless request.save!(resolved)
    # Everything follows the launch except the command.
    launch = resolved.with(command: "sleep #{ttl}")
    if request.dry?
      puts JSON.pretty_generate(launch.describe)
      next
    end

    runner = Putpaws::Ecs::RunCommand.new(launch)
    puts "Launching a temporary task which terminates itself after #{ttl} seconds"
    ecs_task = runner.run_ecs_task(started_by: 'putpaws-shell', group: 'putpaws-shell')
    task_id = ecs_task.task_arn.split('/').last
    puts "Task started: #{task_id} [putpaws-shell]"

    begin
      puts "Waiting for the task to be attachable..."
      ecs_task = runner.wait_until_attachable(ecs_task.task_arn)

      aws = Putpaws::Ecs::TaskCommand.new(
        region: runner.region,
        cluster: runner.cluster_name
      )
      aws.ecs_task = ecs_task
      cmd = aws.get_attach_command(container: runner.container_name)
      puts Shellwords.join(cmd)
      system(*cmd)
    ensure
      if ENV['keep']
        puts "Task #{task_id} keeps running and terminates itself within #{ttl} seconds."
      else
        runner.stop_ecs_task(ecs_task.task_arn, reason: 'Stopped by putpaws ecs:shell')
        puts "Task #{task_id} stopped."
      end
    end
  end
end

namespace :launch do
  desc "List the launches of the environment (.putpaws/<environment>/launch.json). No AWS access."
  task :list do
    app = fetch(:app)
    launches = app.launches
    if launches.empty?
      puts "No launch is defined in #{Putpaws::LaunchConfig.path(app)}"
      next
    end
    launches.each do |launch|
      puts launch.name
      launch.to_h.each do |field, value|
        value = value.map{|k, v| "#{k}=#{v}"}.join(' ') if value.is_a?(Hash)
        value = value.to_json if value.is_a?(Array)
        puts format("  %-18s %s", "#{field}:", value)
      end
    end
  end
end
