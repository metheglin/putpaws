# require 'delegate'

class Putpaws::Env
  def self.default
    @env ||= new({})
  end

  attr_reader :values

  def initialize(values)
    @values = values
  end

  def set(key, value=nil, &block)
    values[key] = block || value
  end

  def fetch(key, default=nil, &block)
    require_environment! if key == :app && default.nil? && block.nil?
    fetch_for(key, default, &block)
  end

  def fetch_for(key, default, &block)
    block ? values.fetch(key, &block) : values.fetch(key, default)
  end

  def delete(key)
    values.delete(key)
  end

  private

  # The first argument of a command is always the environment.
  def require_environment!
    return if values.key?(:app)
    names = Putpaws::ApplicationConfig.names
    raise Putpaws::Error,
      "Please specify the environment first: putpaws <environment> <task>\n" +
      "Environments: #{names.empty? ? '(none yet. `putpaws up` generates .putpaws/<environment>/application.json)' : names.join(', ')}"
  end
end
