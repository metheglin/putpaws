module Putpaws
  class Application < Rake::Application
    def initialize
      super
      @rakefiles = %w{putpawsfile Putpawsfile putpawsfile.rb Putpawsfile.rb}
    end

    def name
      "putpaws"
    end

    def run(argv = ARGV)
      Rake.application = self
      super
    end

    def find_rakefile_location
      putpawsfile = File.expand_path(File.join(File.dirname(__FILE__), "..", "Putpawsfile"))
      if (location = super).nil?
        [putpawsfile, Dir.pwd]
      else
        location
      end
    end
  end
end
