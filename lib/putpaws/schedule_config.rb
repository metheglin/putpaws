require 'putpaws/config_file'
require 'putpaws/launch_config'
require 'putpaws/launch_resolver'

# A schedule (.putpaws/<environment>/schedule.json): a launch of the same
# environment plus when to run it.
#
#   "nightly-seed": {
#     "launch": "seed",
#     "schedule_expression": "cron(0 18 * * ? *)",
#     "schedule_expression_timezone": "Asia/Tokyo"
#   }
#
# Launch fields written here (command / env / cpu ...) override the launch
# for this schedule only. Everything else is passed to EventBridge Scheduler
# (create_schedule / update_schedule) as it is.
class Putpaws::ScheduleConfig
  FILENAME = 'schedule.json'
  OVERRIDE_FIELDS = Putpaws::LaunchConfig::FIELDS - %i[target network]
  # What a schedule held in 0.1.x. They come from the launch / the environment now.
  REMOVED_KEYS = %i[target network region]

  attr_reader :application, :name, :launch, :overrides, :args

  def self.path(application)
    application.dir.join(FILENAME)
  end

  def self.load(application)
    Putpaws::ConfigFile.read(path(application))
  end

  def self.all(application)
    load(application).map{|name, data| new(application: application, name: name, data: data)}
  end

  def self.find(application, name)
    data = load(application)[name.to_sym]
    return nil unless data
    new(application: application, name: name, data: data)
  end

  def self.find!(application, name)
    find(application, name) or raise Putpaws::ConfigError,
      "Schedule not found: #{name} (#{path(application)})\n" +
      "Available: #{load(application).keys.join(', ')}"
  end

  def initialize(application:, name:, data:)
    @application = application
    @name = name.to_s
    context = "schedule `#{@name}` (#{self.class.path(application)})"
    raise Putpaws::ConfigError, "#{context} must be a JSON object" unless data.is_a?(Hash)

    data = data.dup
    removed = data.keys & REMOVED_KEYS
    unless removed.empty?
      raise Putpaws::ConfigError,
        "#{context} has #{removed.map{|k| "`#{k}`"}.join(', ')}, which a schedule no longer holds.\n" +
        "Name a launch of this environment instead: \"launch\": \"<name in launch.json>\""
    end
    @launch = data.delete(:launch)
    if Putpaws::LaunchConfig.blank?(@launch)
      raise Putpaws::ConfigError, "#{context} needs `launch` (a name in launch.json of the same environment)"
    end
    @overrides = Putpaws::LaunchConfig.normalize(
      data.slice(*OVERRIDE_FIELDS), context: context
    )
    @args = data.reject{|k, _| OVERRIDE_FIELDS.include?(k)}
  end

  # Unique within the account and region: <environment>-<schedule>.
  def aws_name
    "#{application.name}-#{name}"
  end

  def launch_config
    Putpaws::LaunchConfig.find!(application, launch)
  end

  def resolve
    Putpaws::LaunchResolver.resolve(
      application: application,
      launch: launch_config,
      overrides: [overrides],
    )
  end
end
