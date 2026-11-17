require 'putpaws/config_file'

# A named launch (.putpaws/<environment>/launch.json): which task definition
# to start on which network, with which overrides. `ecs:run`, `ecs:shell` and
# the scheduler all refer to the same launches by name.
#
# Only what ECS lets you decide when starting a task can be written here.
# Image, sidecars and log destination belong to the task definition.
class Putpaws::LaunchConfig
  FILENAME = 'launch.json'
  FIELDS = %i[
    target network
    command container env
    cpu memory ephemeral_storage
    task_role capacity_provider
  ]
  REQUIRED = %i[target network]
  INTEGER_FIELDS = %i[cpu memory ephemeral_storage]
  STRING_FIELDS = %i[target network container task_role]
  CAPACITY_PROVIDERS = %w[FARGATE FARGATE_SPOT]
  NAME_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_\-]*\z/

  attr_reader :name, :attributes

  def self.path(application)
    application.dir.join(FILENAME)
  end

  def self.load(application)
    Putpaws::ConfigFile.read(path(application))
  end

  def self.all(application)
    file = path(application)
    load(application).map{|name, attrs|
      new(name: name, attributes: attrs, context: "launch `#{name}` (#{file})")
    }
  end

  def self.find(application, name)
    attrs = load(application)[name.to_sym]
    return nil unless attrs
    new(name: name, attributes: attrs, context: "launch `#{name}` (#{path(application)})")
  end

  def self.find!(application, name)
    find(application, name) or raise Putpaws::ConfigError,
      "Launch not found: #{name} (#{path(application)})\n" +
      "Available: #{names(application).join(', ')}"
  end

  def self.names(application)
    load(application).keys.map(&:to_s)
  end

  # Save one launch under the given name. Other launches are kept as they are.
  # Overwrites silently: ask the user first when the name already exists.
  def self.save!(application, name, attributes)
    unless name.to_s.match?(NAME_PATTERN)
      raise Putpaws::ConfigError, "Invalid launch name: #{name} (letters, numbers, `-` and `_` only)"
    end
    attrs = normalize(attributes, context: "launch `#{name}`", required: true)
    file = path(application)
    data = load(application)
    data[name.to_sym] = attrs
    Putpaws::ConfigFile.write(file, data)
    file
  end

  # Validate and normalize launch fields. Returns a Hash in FIELDS order
  # without blank values. Unknown fields are an error: a setting that is
  # silently ignored would look like it works.
  def self.normalize(attributes, context:, required: false)
    unless attributes.is_a?(Hash)
      raise Putpaws::ConfigError, "#{context} must be a JSON object"
    end
    attrs = attributes.map{|k, v| [k.to_sym, v]}.to_h
    unknown = attrs.keys - FIELDS
    unless unknown.empty?
      raise Putpaws::ConfigError,
        "Unknown field #{unknown.map{|k| "`#{k}`"}.join(', ')} in #{context}. Available: #{FIELDS.join(', ')}"
    end

    normalized = {}
    FIELDS.each do |field|
      value = attrs[field]
      next if blank?(value)
      normalized[field] = normalize_field(field, value, context)
    end
    if required
      missing = REQUIRED - normalized.keys
      unless missing.empty?
        raise Putpaws::ConfigError, "#{context} needs #{missing.map{|k| "`#{k}`"}.join(' and ')}"
      end
    end
    normalized
  end

  def self.normalize_field(field, value, context)
    if STRING_FIELDS.include?(field)
      raise Putpaws::ConfigError, "`#{field}` must be a string in #{context}" unless value.is_a?(String)
      value.strip
    elsif INTEGER_FIELDS.include?(field)
      unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
        raise Putpaws::ConfigError, "`#{field}` must be an integer in #{context}: #{value.inspect}"
      end
      value.to_i
    elsif field == :command
      valid = value.is_a?(String) || (value.is_a?(Array) && !value.empty? && value.all?{|x| x.is_a?(String)})
      raise Putpaws::ConfigError, "`command` must be a string or an array of strings in #{context}" unless valid
      value
    elsif field == :env
      raise Putpaws::ConfigError, "`env` must be an object like {\"NAME\": \"value\"} in #{context}" unless value.is_a?(Hash)
      value.map{|k, v| [k.to_s, v.to_s]}.to_h
    elsif field == :capacity_provider
      provider = value.to_s.upcase
      unless CAPACITY_PROVIDERS.include?(provider)
        raise Putpaws::ConfigError,
          "`capacity_provider` must be one of #{CAPACITY_PROVIDERS.join(' / ')} in #{context}: #{value.inspect}"
      end
      provider
    end
  end

  def self.blank?(value)
    value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?)
  end

  def initialize(name:, attributes:, context: nil)
    @name = name.to_s
    @attributes = self.class.normalize(attributes, context: context || "launch `#{name}`", required: true)
  end

  FIELDS.each do |field|
    define_method(field){ attributes[field] }
  end

  def to_h
    attributes.dup
  end
end
