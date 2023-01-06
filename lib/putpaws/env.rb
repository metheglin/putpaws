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
    fetch_for(key, default, &block)
  end

  def fetch_for(key, default, &block)
    block ? values.fetch(key, &block) : values.fetch(key, default)
  end

  def delete(key)
    values.delete(key)
  end
end
