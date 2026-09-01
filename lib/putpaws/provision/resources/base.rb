module Putpaws
  module Provision
    module Resources
      MANAGED_TAG = {key: 'managed-by', value: 'putpaws'}

      class Base
        attr_reader :config, :state, :clients
        def initialize(config:, state:, clients:)
          @config = config
          @state = state
          @clients = clients
        end

        def kind
          self.class.name.split('::').last
        end

        # Subclasses implement: name, current, create!, outputs(current)
        # and optionally: changed?(current), update!(current)

        def changed?(_current)
          false
        end

        def plan
          c = current
          action = c.nil? ? :create : (changed?(c) ? :update : :skip)
          {action: action, kind: kind, name: name}
        end

        # Idempotent apply. Always returns the outputs hash.
        def ensure!
          c = current
          if c.nil?
            create!
          elsif changed?(c)
            update!(c)
          else
            outputs(c)
          end
        end

        def update!(_current)
          raise NotImplementedError, "#{kind} does not support update"
        end
      end
    end
  end
end
