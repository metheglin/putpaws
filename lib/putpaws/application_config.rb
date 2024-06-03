require 'json'
require 'pathname'
require "putpaws/schedule_config"

class Putpaws::ApplicationConfig < Struct.new(
  :name, :region, 
  :cluster, :service, :task_name_prefix, :ecs_region,
  :log_group_prefix, :log_region,
  :build_project_name_prefix, :build_log_group_prefix, :build_region,
  :schedules,
  keyword_init: true)
  def self.load(path_prefix: '.putpaws')
    @application_data ||= begin
      path = Pathname.new(path_prefix).join("application.json").to_s
      data = File.exist?(path) ?
        JSON.parse(File.read(path), symbolize_names: true).to_h :
        {}
    end
  end

  def self.all
    load.map{|k,v|
      data = v.slice(*self.members)
      new(data.merge(name: k.to_s))
    }
  end

  def self.find(name)
    application_data = load
    data = application_data[name.to_sym]
    return nil unless data
    data = data.slice(*self.members)
    new(data.merge({name: name.to_s}))
  end

  def ecs_command_params
    {
      region: ecs_region || region,
      cluster: cluster,
      # service: service,
      task_name_prefix: task_name_prefix,
    }
  end

  def log_command_params
    {
      region: log_region || region,
      log_group_prefix: log_group_prefix,
    }
  end

  def build_log_command_params
    {
      region: build_region || region,
      log_group_prefix: build_log_group_prefix,
    }
  end

  def schedules
    @schedules ||= (self[:schedules] || []).map{|x| Putpaws::ScheduleConfig.find(x)}.compact
  end

  def codebuild_command_params
    {
      region: build_region || region,
      project_name_prefix: build_project_name_prefix,
    }
  end
end
