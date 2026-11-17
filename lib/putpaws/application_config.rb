require 'pathname'
require 'putpaws/config_file'

# An environment (= application). One folder per environment:
# .putpaws/<environment>/application.json. The folder name is the name, and it
# is the first argument of every command.
#
# The settings are what is needed to operate things that are already running:
# region / cluster plus prefixes that find tasks, logs and builds.
# How to start tasks lives in launch.json (Putpaws::LaunchConfig) and when to
# start them in schedule.json (Putpaws::ScheduleConfig); neither is known here.
class Putpaws::ApplicationConfig < Struct.new(
  :name, :region,
  :cluster, :service, :task_name_prefix, :ecs_region,
  :log_group_prefix, :log_region,
  :build_project_name_prefix, :build_log_group_prefix, :build_region,
  keyword_init: true)
  FILENAME = 'application.json'
  # Folders right under .putpaws/ that are never environments.
  RESERVED_DIRS = %w[provisioning]
  # Keys of the 0.1.x entries which moved to launch.json / schedule.json.
  REMOVED_KEYS = %i[network target schedules]

  attr_accessor :path_prefix

  def self.dir_for(name, path_prefix: Putpaws::ConfigFile.root)
    Pathname.new(path_prefix).join(name.to_s)
  end

  # Environments are the folders right under .putpaws/ that hold application.json.
  def self.names(path_prefix: Putpaws::ConfigFile.root)
    root = Pathname.new(path_prefix)
    return [] unless root.directory?
    root.children.select(&:directory?)
      .reject{|d| RESERVED_DIRS.include?(d.basename.to_s)}
      .select{|d| d.join(FILENAME).file?}
      .map{|d| d.basename.to_s}
      .sort
  end

  def self.all(path_prefix: Putpaws::ConfigFile.root)
    Putpaws::ConfigFile.ensure_no_legacy!(path_prefix: path_prefix)
    names(path_prefix: path_prefix).map{|name| build(name, path_prefix)}
  end

  def self.find(name, path_prefix: Putpaws::ConfigFile.root)
    Putpaws::ConfigFile.ensure_no_legacy!(path_prefix: path_prefix)
    return nil unless names(path_prefix: path_prefix).include?(name.to_s)
    build(name, path_prefix)
  end

  def self.build(name, path_prefix)
    file = dir_for(name, path_prefix: path_prefix).join(FILENAME)
    data = Putpaws::ConfigFile.read(file)
    removed = data.keys & REMOVED_KEYS
    unless removed.empty?
      raise Putpaws::ConfigError,
        "#{file} has #{removed.map{|k| "`#{k}`"}.join(', ')}, which application.json no longer holds.\n" +
        "Launches go to launch.json and schedules to schedule.json in the same folder."
    end
    app = new(data.slice(*(members - [:name])).merge(name: name.to_s))
    app.path_prefix = path_prefix
    app
  end

  def dir
    self.class.dir_for(name, path_prefix: path_prefix || Putpaws::ConfigFile.root)
  end

  # Named launches of this environment (launch.json).
  def launches
    require 'putpaws/launch_config'
    Putpaws::LaunchConfig.all(self)
  end

  # Schedules of this environment (schedule.json).
  def schedules
    require 'putpaws/schedule_config'
    Putpaws::ScheduleConfig.all(self)
  end

  def ecs_command_params
    {
      region: ecs_region || region,
      cluster: cluster,
      service: service,
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

  def codebuild_command_params
    {
      region: build_region || region,
      project_name_prefix: build_project_name_prefix,
    }
  end
end
