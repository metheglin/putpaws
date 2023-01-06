require "putpaws/env"
require "forwardable"

module Putpaws::DSL
  extend Forwardable
  
  def_delegators :env,
    :fetch, :set, :delete

  def env
    Putpaws::Env.default
  end
end
extend Putpaws::DSL