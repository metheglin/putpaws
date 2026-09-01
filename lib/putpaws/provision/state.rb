require 'json'
require 'putpaws/provision/util'

module Putpaws
  module Provision
    class State
      def self.load(config)
        path = config.dir.join('state.json')
        data = path.exist? ? JSON.parse(File.read(path), symbolize_names: true) : {}
        new(path: path.to_s, data: data)
      end

      attr_reader :path, :data
      def initialize(path:, data:)
        @path = path
        @data = data
        @data[:resources] ||= {}
        @data[:steps] ||= {}
      end

      def resources
        data[:resources]
      end

      def steps
        data[:steps]
      end

      def merge_resources!(outputs)
        resources.merge!(outputs.map{|k, v| [k.to_sym, v]}.to_h)
        save!
      end

      def mark_step!(name, status)
        steps[name.to_sym] = status
        save!
      end

      def save!
        data[:updated_at] = Time.now.to_s
        Util.write_json(path, data)
      end
    end
  end
end
