require 'json'
require 'pathname'
require 'fileutils'

module Putpaws
  module Provision
    class Preset
      BUILTIN_DIR = File.expand_path('presets', __dir__)

      def self.local_dir(path_prefix: '.putpaws')
        Pathname.new(path_prefix).join('provisioning', 'presets')
      end

      # Search order: project local -> user global (PUTPAWS_PRESETS_PATH dirs,
      # then ~/.putpaws/presets) -> builtin (bundled in the gem).
      def self.search_paths(path_prefix: '.putpaws')
        paths = [[local_dir(path_prefix: path_prefix).to_s, 'local']]
        ENV['PUTPAWS_PRESETS_PATH'].to_s.split(File::PATH_SEPARATOR).reject(&:empty?).each do |dir|
          paths << [dir, 'global']
        end
        home = ENV['HOME'].to_s
        paths << [File.join(home, '.putpaws', 'presets'), 'global'] unless home.empty?
        paths << [BUILTIN_DIR, 'builtin']
        paths
      end

      # [{name:, dir:, source:}] with name collisions resolved by search order.
      def self.catalog(path_prefix: '.putpaws')
        seen = {}
        search_paths(path_prefix: path_prefix).each do |dir, source|
          Dir.glob(File.join(dir, '*/preset.json')).sort.each do |p|
            name = File.basename(File.dirname(p))
            seen[name] ||= {name: name, dir: File.dirname(p), source: source}
          end
        end
        seen.values.sort_by{|e| e[:name]}
      end

      def self.available(path_prefix: '.putpaws')
        catalog(path_prefix: path_prefix).map{|e| e[:name]}
      end

      def self.find(name, path_prefix: '.putpaws')
        entry = catalog(path_prefix: path_prefix).detect{|e| e[:name] == name}
        entry && new(name: entry[:name], dir: entry[:dir])
      end

      # Copy a preset into .putpaws so that the project owns its snapshot and
      # users can edit it. Does nothing when the local preset already exists.
      def self.install(name, path_prefix: '.putpaws')
        entry = catalog(path_prefix: path_prefix).detect{|e| e[:name] == name}
        raise "Unknown preset: #{name}" unless entry
        return new(name: entry[:name], dir: entry[:dir]) if entry[:source] == 'local'
        local = local_dir(path_prefix: path_prefix).join(name)
        FileUtils.mkdir_p(local.dirname)
        FileUtils.cp_r(entry[:dir], local)
        find(name, path_prefix: path_prefix)
      end

      attr_reader :name, :dir
      def initialize(name:, dir:)
        @name = name
        @dir = dir
      end

      def data
        @data ||= JSON.parse(File.read(File.join(dir, 'preset.json')), symbolize_names: true)
      end

      def defaults
        data[:defaults] || {}
      end

      def task_definitions
        data[:task_definitions] || []
      end

      def service_task_definition
        data[:service_task_definition]
      end

      def devops_defaults
        data[:devops_defaults] || {}
      end

      def template_path(file)
        File.join(dir, 'templates', file)
      end
    end
  end
end
