require "putpaws/prompt"
require "putpaws/ecs/task_command"
require "putpaws/ecs/run_command"

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
    puts cmd
    system(cmd)
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
    puts cmd
    system(cmd)
  end

  desc "Run a command on a temporary ECS task. The task terminates itself when the command finishes. (Ex) cmd='bundle exec rake db:migrate' wait=true"
  task :run do
    runner = Putpaws::Ecs::RunCommand.config(fetch(:app))
    command = ENV['cmd']
    if command.nil? || command.strip.empty?
      raise "Please specify a command like: cmd='bundle exec rake db:migrate'"
    end

    ecs_task = runner.run_ecs_task(
      command: command,
      started_by: 'putpaws-run',
      group: 'putpaws-run',
      container: ENV['container']
    )
    task_id = ecs_task.task_arn.split('/').last
    puts "Task started: #{task_id} [putpaws-run]"

    if ENV['wait']
      puts "Waiting for the task to stop..."
      ecs_task = runner.wait_until_stopped(ecs_task.task_arn)
      ctn_name = ENV['container'] || runner.container_name
      ctn = ecs_task.containers.detect{|c| c.name == ctn_name}
      exit_code = ctn && ctn.exit_code
      puts "Task stopped: #{ecs_task.stopped_reason}"
      raise "Command failed with exit code: #{exit_code.inspect}" unless exit_code == 0
      puts "Command succeeded."
    else
      puts "The task terminates itself when the command finishes."
    end
  end

  desc "Launch a temporary ECS task for operation and attach to it. The task terminates itself when ttl passes (default 30m). (Ex) ttl=45m keep=true"
  task :shell do
    runner = Putpaws::Ecs::RunCommand.config(fetch(:app))
    ttl = Putpaws::Ecs::RunCommand.parse_ttl(ENV['ttl'])

    puts "Launching a temporary task which terminates itself after #{ttl} seconds"
    ecs_task = runner.run_ecs_task(
      command: "sleep #{ttl}",
      started_by: 'putpaws-shell',
      group: 'putpaws-shell'
    )
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
      cmd = aws.get_attach_command(container: ENV['container'] || runner.container_name)
      puts cmd
      system(cmd)
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
