require "tty-prompt"
require "putpaws/ecs/task_command"

namespace :ecs do
  desc "Set ECS task."
  task :set_task do
    aws = Putpaws::Ecs::TaskCommand.config(fetch(:app))
    ecs_tasks = aws.list_ecs_tasks.map{|t| 
      task_id = t.task_arn.split('/').last
      task_def = t.task_definition_arn.split('/').last
      ["#{task_id} (#{task_def}) #{t.last_status}", t]
    }.to_h
    prompt = TTY::Prompt.new
    selected = prompt.select("Choose a task you're going to operate", ecs_tasks.keys)
    ecs_task = ecs_tasks[selected]

    set :ecs_task, ecs_task
  end

  desc "Attach on ECS task. You need to enable ECS Exec on a specified task and also install session-manager-plugin."
  task attach: :set_task do
    ecs_task = fetch(:ecs_task)
    aws = Putpaws::Ecs::TaskCommand.config(fetch(:app))
    aws.ecs_task = ecs_task
    cmd = aws.get_attach_command
    puts cmd
    system(cmd)
  end
end
