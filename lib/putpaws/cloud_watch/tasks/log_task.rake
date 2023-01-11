require "tty-prompt"
require "putpaws/cloud_watch/log_command"
require "putpaws/cloud_watch/default_log_formatter"

namespace :log do
  desc "Set Log Group."
  task :set_log_group do
    aws = Putpaws::CloudWatch::LogCommand.config(fetch(:app))
    log_groups = aws.list_log_groups.map{|a| 
      [a.log_group_name, a]
    }.to_h
    raise "Log group not found on your permission" if log_groups.empty?

    log_group = if log_groups.length == 1
      log_groups.first
    else
      prompt = TTY::Prompt.new
      selected = prompt.select("Choose a log_group you're going to operate", log_groups.keys)
       log_groups[selected]
    end

    set :log_group, log_group
  end

  desc "Tail log with follow."
  task tailf: :set_log_group do
    ENV['follow'] = '1'
    Rake::Task['log:tail'].invoke
  end

  # Check: https://github.com/aws/aws-cli/blob/v2/awscli/customizations/logs/tail.py
  desc "Tail log with follow."
  task tail: :set_log_group do
    log_group = fetch(:log_group)
    log_formatter = fetch(:log_formatter) {Putpaws::CloudWatch::DefaultLogFormatter.new}
    aws = Putpaws::CloudWatch::LogCommand.config(fetch(:app))
    aws.log_group = log_group.log_group_name
    
    log_event_args = Putpaws::CloudWatch::LogCommand.filter_args(since: ENV['since'], since_for: ENV['for'])

    loop do
      events, next_args = aws.tail_log_events(**log_event_args)
      events.each {|a| puts log_formatter.call(a)}
      log_event_args = next_args
      unless log_event_args[:next_token]
        ENV['follow'] ? sleep(5) : break
      end
    rescue Interrupt
      exit
    end
  end
end
